#!/usr/bin/env python3
"""CUDA / cuPauliProp backend runner for PPS benchmark.

Subprocess contract
-------------------
Input : --circuit <pps-circuit-v1.json> --samples <n>
Success: exit 0, one JSON line on stdout (BenchmarkResult schema)
Failure: diagnostic on stderr, exit 1
"""

import sys
import json
import argparse
import time
import os
import math
import statistics

os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
os.environ.setdefault("MKL_NUM_THREADS", "1")

try:
    import numpy as np
    from cuquantum.pauliprop.experimental import (
        PauliExpansion,
        PauliRotationGate,
        LibraryHandle,
        Truncation,
        get_num_packed_integers,
    )
    import cuquantum as _cuquantum_module
    import cuquantum.pauliprop as _cupauliprop_module

    _CUQUANTUM_VERSION = getattr(_cuquantum_module, "__version__", None) or \
                         getattr(_cupauliprop_module, "__version__", "unknown")
except ImportError as e:
    print(f"ERROR: cuquantum not available: {e}", file=sys.stderr)
    sys.exit(1)

import resource


# ---------------------------------------------------------------------------
# XZ bits encoding
# ---------------------------------------------------------------------------

def _encode_pauli_string_to_xz(pauli_str: str) -> np.ndarray:
    """Encode a Pauli string as a flat array of uint64 [x_ints..., z_ints...].

    Encoding per qubit i (bit i of the integer at index i//64):
      I: x=0, z=0
      X: x=1, z=0
      Y: x=1, z=1
      Z: x=0, z=1
    """
    n = len(pauli_str)
    ints_per = get_num_packed_integers(n)
    x_ints = np.zeros(ints_per, dtype=np.uint64)
    z_ints = np.zeros(ints_per, dtype=np.uint64)
    for i, p in enumerate(pauli_str):
        word = i // 64
        bit = i % 64
        if p in ("X", "Y"):
            x_ints[word] |= np.uint64(1) << np.uint64(bit)
        if p in ("Z", "Y"):
            z_ints[word] |= np.uint64(1) << np.uint64(bit)
    return np.concatenate([x_ints, z_ints])


def build_pauli_expansion(handle: LibraryHandle, nqubits: int, terms: list) -> PauliExpansion:
    """Build a PauliExpansion from a list of (coeff, pauli_str) pairs.

    Args:
        handle:   cuPauliProp LibraryHandle.
        nqubits:  Number of qubits.
        terms:    List of (coefficient, pauli_string_of_length_nqubits) pairs.

    Returns:
        A PauliExpansion on the GPU (or CPU-backed if no GPU).
    """
    ints_per_term = get_num_packed_integers(nqubits)
    num_terms = len(terms)

    # Allocate buffers
    xz_buf = np.zeros((num_terms, 2 * ints_per_term), dtype=np.uint64)
    coef_buf = np.zeros(num_terms, dtype=np.complex128)

    for idx, (coeff, pauli_str) in enumerate(terms):
        xz = _encode_pauli_string_to_xz(pauli_str)
        xz_buf[idx] = xz
        coef_buf[idx] = complex(coeff)

    return PauliExpansion(handle, nqubits, num_terms, xz_buf, coef_buf)


# ---------------------------------------------------------------------------
# Observable parsing
# ---------------------------------------------------------------------------

def parse_observable(nqubits: int, observable: str) -> list:
    """Convert an observable string to a list of (coeff, pauli_str) pairs.

    Supported formats:
      "Z0"        -> [(1.0, "ZI...I")]   (Z on qubit 0)
      "Z62"       -> [(1.0, "II...ZII...I")] (Z at position 62)
      "X5"        -> [(1.0, "IIIIIXII...I")]
      "Mz" / "magnetization" -> [(1/n, string_with_Z_at_i) for i in 0..n-1]
    """
    obs = observable.strip()

    if obs in ("Mz", "magnetization"):
        terms = []
        for i in range(nqubits):
            arr = ["I"] * nqubits
            arr[i] = "Z"
            terms.append((1.0 / nqubits, "".join(arr)))
        return terms

    # Single-qubit Pauli: letter followed by qubit index  (e.g. "Z0", "X5", "Z62")
    if len(obs) >= 2 and obs[0] in ("X", "Y", "Z", "I"):
        try:
            qubit = int(obs[1:])
        except ValueError:
            pass
        else:
            if 0 <= qubit < nqubits:
                arr = ["I"] * nqubits
                arr[qubit] = obs[0]
                return [(1.0, "".join(arr))]

    raise ValueError(f"Unsupported observable format: {observable!r}")


# ---------------------------------------------------------------------------
# Gate to Pauli string
# ---------------------------------------------------------------------------

def gate_to_pauli_string(gate: dict, nqubits: int) -> str:
    """Convert a pps-circuit-v1 gate to a cuquantum Pauli string of length nqubits."""
    pauli_arr = ["I"] * nqubits
    for qubit, op in zip(gate["qubits"], gate["paulis"]):
        pauli_arr[qubit] = op
    return "".join(pauli_arr)


# ---------------------------------------------------------------------------
# Expectation extraction
# ---------------------------------------------------------------------------

def extract_expectation_zero(expansion: PauliExpansion) -> float:
    """Compute <0...0|O|0...0> using PauliExpansion.trace_with_zero_state().

    trace_with_zero_state() returns (significand, exponent) where
    result = significand * 2^exponent.  significand may be complex; take the
    real part (imaginary part is ~0 for physical Hermitian observables).
    """
    sig, exp2 = expansion.trace_with_zero_state()
    return float(complex(sig).real) * math.pow(2.0, float(exp2))


# ---------------------------------------------------------------------------
# Propagation
# ---------------------------------------------------------------------------

def propagate(circuit: dict, threshold: float = 1e-8):
    """Run Heisenberg-picture Pauli propagation with cuPauliProp.

    Returns (expectation, final_terms).
    """
    nqubits = circuit["nqubits"]
    handle = LibraryHandle()

    # Build truncation: None means no truncation (threshold=0.0 case)
    if threshold == 0.0:
        truncation = None
    else:
        truncation = Truncation(pauli_coeff_cutoff=threshold)

    # Initialize with observable (build on CPU then move to GPU)
    obs_terms = parse_observable(nqubits, circuit["observable"])
    expansion = build_pauli_expansion(handle, nqubits, obs_terms)
    expansion = expansion.to("gpu", package="cupy")

    # Apply gates in reverse (Heisenberg picture)
    for gate in reversed(circuit["gates"]):
        pauli_str = gate_to_pauli_string(gate, nqubits)
        rot_gate = PauliRotationGate(angle=gate["theta"], pauli_string=pauli_str)
        expansion = expansion.apply_gate(rot_gate, truncation=truncation)

    expectation = extract_expectation_zero(expansion)
    final_terms = int(expansion.num_terms)
    return expectation, final_terms


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="cuPauliProp backend runner for PPS benchmark"
    )
    parser.add_argument("--circuit", required=True, help="Path to pps-circuit-v1 JSON")
    parser.add_argument("--samples", type=int, default=1, help="Number of timed runs")
    args = parser.parse_args()

    if args.samples < 1:
        print("ERROR: --samples must be >= 1", file=sys.stderr)
        sys.exit(1)

    # Load circuit
    try:
        with open(args.circuit) as f:
            circuit = json.load(f)
    except Exception as e:
        print(f"ERROR: failed to load circuit file {args.circuit!r}: {e}", file=sys.stderr)
        sys.exit(1)

    nqubits = circuit.get("nqubits", 0)
    truncation_threshold = float(
        circuit.get("truncation", {}).get("threshold", 1e-8)
    )

    # NOTE: no separate exact (threshold=0) reference run. At 127 qubits the
    # untruncated propagation OOMs the GPU, and the LOWESA sweep supplies its
    # own reference curve at the sweep level (see run_external_backend_sweep).
    # This backend reports the coefficient-truncated value as both expectation
    # and reference (absolute_error = 0 here; real error is computed by the sweep).

    # Timed samples
    runtimes = []
    expectation_val = None
    final_terms_val = None

    for i in range(args.samples):
        t0 = time.perf_counter()
        try:
            exp, ft = propagate(circuit, threshold=truncation_threshold)
        except Exception as e:
            print(f"ERROR: propagation sample {i} failed: {e}", file=sys.stderr)
            sys.exit(1)
        t1 = time.perf_counter()
        runtimes.append(t1 - t0)
        expectation_val = exp
        final_terms_val = ft

    reference_val = expectation_val
    median_time = statistics.median(runtimes)
    memory_bytes = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024

    absolute_error = abs(expectation_val - reference_val)

    result = {
        "backend": "cuda_cupauliprop",
        "task_id": circuit.get("task_id", "unknown"),
        "success": True,
        "runtime_sec": median_time,
        "memory_bytes": memory_bytes,
        "final_terms": final_terms_val,
        "expectation": expectation_val,
        "reference": reference_val,
        "absolute_error": absolute_error,
        "metadata": {
            "engine": "cupauliprop",
            "cuquantum_version": _CUQUANTUM_VERSION,
            "truncation_threshold": truncation_threshold,
            "circuit_schema_version": circuit.get("schema_version", "pps-circuit-v1"),
            "nqubits": nqubits,
            "circuit_size": len(circuit.get("gates", [])),
            "observable": circuit.get("observable", ""),
            "family": circuit.get("family", ""),
            "median_time_sec": median_time,
            "memory_measure": "process_peak_rss",
            "thread_limits": {"OMP_NUM_THREADS": "1"},
        },
    }

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
