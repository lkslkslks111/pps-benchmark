#!/usr/bin/env python3
"""Python / cuQuantum Python backend runner for PPS benchmark.

Subprocess contract
-------------------
Input  : --circuit <path.json> [--samples <n>]
Success: exit 0, one JSON line on stdout with all 10 required fields
Failure: diagnostic on stderr, exit 1
"""

import sys
import json
import argparse
import time
import os
import statistics

os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")

try:
    from cuquantum.pauliprop.experimental import (
        PauliExpansion,
        PauliRotationGate,
        LibraryHandle,
        Truncation,
    )
    import cuquantum
except ImportError as e:
    print(f"ERROR: cuquantum not available: {e}", file=sys.stderr)
    sys.exit(1)

import resource


def parse_args():
    parser = argparse.ArgumentParser(description="cuQuantum Python PPS benchmark runner")
    parser.add_argument("--circuit", required=True, help="Path to circuit JSON file")
    parser.add_argument(
        "--samples", type=int, default=1, help="Number of propagation runs for median timing"
    )
    args = parser.parse_args()
    if args.samples < 1:
        print("ERROR: --samples must be >= 1", file=sys.stderr)
        sys.exit(1)
    return args


def load_circuit(path):
    with open(path) as f:
        data = json.load(f)
    schema = data.get("schema_version", "")
    if schema != "pps-circuit-v1":
        print(
            f"ERROR: unsupported circuit schema version: {schema!r}",
            file=sys.stderr,
        )
        sys.exit(1)
    return data


def gate_to_pauli_string(gate, nqubits):
    """Convert a circuit gate dict to a cuQuantum Pauli string of length nqubits.

    The Pauli string format is a plain Python str of length nqubits where
    position i corresponds to qubit i (0-indexed).  Qubits not touched by
    this gate carry 'I'.
    """
    arr = ["I"] * nqubits
    for qubit, op in zip(gate["qubits"], gate["paulis"]):
        arr[qubit] = op
    return "".join(arr)


def parse_observable(nqubits, obs_str):
    """Parse an observable string into a list of (coefficient, pauli_str) tuples.

    Supported formats:
      "Z0", "X5", "Z62"   → single-qubit Pauli on qubit index
      "Mz", "magnetization" → uniform Z magnetisation (1/N) * sum_i Z_i
    """
    obs = obs_str.strip()
    terms = []

    if obs.lower() in ("mz", "magnetization"):
        coeff = 1.0 / nqubits
        for i in range(nqubits):
            arr = ["I"] * nqubits
            arr[i] = "Z"
            terms.append((coeff, "".join(arr)))
        return terms

    # Single-qubit observable: letter + integer index
    if len(obs) >= 2 and obs[0].upper() in ("X", "Y", "Z", "I"):
        pauli_char = obs[0].upper()
        try:
            qubit_idx = int(obs[1:])
        except ValueError:
            print(
                f"ERROR: cannot parse observable {obs!r}; expected format like 'Z0' or 'X62'",
                file=sys.stderr,
            )
            sys.exit(1)
        if not (0 <= qubit_idx < nqubits):
            print(
                f"ERROR: observable qubit index {qubit_idx} out of range [0, {nqubits - 1}]",
                file=sys.stderr,
            )
            sys.exit(1)
        arr = ["I"] * nqubits
        arr[qubit_idx] = pauli_char
        terms.append((1.0, "".join(arr)))
        return terms

    print(f"ERROR: unrecognised observable format: {obs!r}", file=sys.stderr)
    sys.exit(1)


def extract_expectation_zero(expansion):
    """Compute <0|expansion|0> in the all-zeros computational basis state.

    For a Pauli string P = P_0 ⊗ P_1 ⊗ ... ⊗ P_{n-1}:
      <0|P|0> = 1  if every P_i ∈ {I, Z}
      <0|P|0> = 0  if any P_i ∈ {X, Y}

    We iterate over all terms (coeff, pauli_str) in the expansion and
    accumulate contributions from purely I/Z terms.
    """
    total = 0.0

    # PauliExpansion supports iteration; each item is a (pauli_string, coefficient) pair.
    # We try multiple known attribute names defensively.
    try:
        items = list(expansion)
    except TypeError:
        items = None

    if items is None:
        # Fallback: try .terms or .to_dict()
        if hasattr(expansion, "to_dict"):
            d = expansion.to_dict()
            items = list(d.items())
        elif hasattr(expansion, "terms"):
            items = list(expansion.terms)
        else:
            raise RuntimeError(
                "Cannot iterate over PauliExpansion: unknown API. "
                "Please check the cuquantum version."
            )

    for item in items:
        # Handle (pauli_str, coeff) or (coeff, pauli_str) orderings
        if isinstance(item, (tuple, list)) and len(item) == 2:
            a, b = item
            if isinstance(a, str):
                pauli_str, coeff = a, b
            else:
                coeff, pauli_str = a, b
        else:
            # Some APIs return objects with .pauli_string and .coefficient attributes
            pauli_str = item.pauli_string
            coeff = item.coefficient

        # <0|P|0> = 1 only when all characters are I or Z
        if all(c in ("I", "Z") for c in pauli_str):
            total += float(coeff.real if hasattr(coeff, "real") else coeff)

    return total


def propagate(circuit, threshold):
    """Run Heisenberg-picture Pauli propagation using cuQuantum.

    Returns (expectation, final_terms, runtime_sec).
    """
    nqubits = circuit["nqubits"]
    obs_str = circuit["observable"]
    gates = circuit["gates"]
    obs_terms = parse_observable(nqubits, obs_str)

    handle = LibraryHandle()
    truncation = Truncation(threshold=threshold) if threshold > 0.0 else None

    # Initialise expansion from observable
    expansion = PauliExpansion(handle, nqubits, terms=obs_terms)

    t0 = time.perf_counter()

    # Apply gates in reverse (Heisenberg picture)
    for gate in reversed(gates):
        pauli_str = gate_to_pauli_string(gate, nqubits)
        rot_gate = PauliRotationGate(pauli_str, gate["theta"])
        if truncation is not None:
            expansion = rot_gate.apply(expansion, truncation=truncation)
        else:
            expansion = rot_gate.apply(expansion)

    expectation = extract_expectation_zero(expansion)
    runtime_sec = time.perf_counter() - t0

    # Count terms: try various attribute names
    if hasattr(expansion, "num_terms"):
        final_terms = int(expansion.num_terms)
    elif hasattr(expansion, "__len__"):
        final_terms = len(expansion)
    else:
        final_terms = len(list(expansion))

    return expectation, final_terms, runtime_sec


def main():
    args = parse_args()
    circuit = load_circuit(args.circuit)

    nqubits = circuit["nqubits"]
    threshold = float(circuit.get("truncation", {}).get("threshold", 1e-8))
    task_id = circuit.get("task_id", "unknown")
    family = circuit.get("family", "unknown")
    observable = circuit.get("observable", "unknown")
    circuit_size = len(circuit.get("gates", []))

    # Run propagation --samples times and take median runtime
    runtimes = []
    expectation = None
    final_terms = None
    for _ in range(args.samples):
        exp, terms, rt = propagate(circuit, threshold)
        runtimes.append(rt)
        expectation = exp
        final_terms = terms

    median_time = statistics.median(runtimes)

    # Reference: run with threshold=0.0 for exact (untruncated) value.
    # If already exact, skip the second pass.
    if threshold == 0.0:
        reference = expectation
    else:
        reference, _, _ = propagate(circuit, 0.0)

    absolute_error = abs(expectation - reference)

    # Memory: peak RSS in bytes (Linux reports in kB)
    memory_bytes = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024

    result = {
        "backend": "python_cuquantum",
        "task_id": task_id,
        "success": True,
        "runtime_sec": median_time,
        "memory_bytes": memory_bytes,
        "final_terms": final_terms,
        "expectation": expectation,
        "reference": reference,
        "absolute_error": absolute_error,
        "metadata": {
            "engine": "cuquantum_pauliprop",
            "cuquantum_version": cuquantum.__version__,
            "api_level": "experimental_python",
            "truncation_threshold": threshold,
            "circuit_schema_version": "pps-circuit-v1",
            "nqubits": nqubits,
            "circuit_size": circuit_size,
            "observable": observable,
            "family": family,
            "median_time_sec": median_time,
            "memory_measure": "process_peak_rss",
            "thread_limits": {"OMP_NUM_THREADS": "1"},
        },
    }

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
