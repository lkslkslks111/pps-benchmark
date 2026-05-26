#!/usr/bin/env python3
"""Python / BlueQubit backend runner for PPS benchmark.

Usage:
    python3 bluequbit_runner.py --circuit <path> [--samples <n>]

Reads a pps-circuit-v1 JSON, builds a Qiskit QuantumCircuit, calls the
BlueQubit pauli-path device, and prints a BenchmarkResult JSON on stdout.

Requires BLUEQUBIT_API_TOKEN environment variable.
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
    import bluequbit
except ImportError as e:
    print(f"ERROR: bluequbit not available: {e}", file=sys.stderr)
    sys.exit(1)

try:
    from qiskit import QuantumCircuit
    from qiskit.circuit.library import PauliEvolutionGate
    from qiskit.quantum_info import SparsePauliOp
except ImportError as e:
    print(f"ERROR: qiskit not available: {e}", file=sys.stderr)
    sys.exit(1)

import resource


def parse_args():
    parser = argparse.ArgumentParser(
        description="BlueQubit backend runner for PPS benchmark"
    )
    parser.add_argument("--circuit", required=True, help="Path to pps-circuit-v1 JSON file")
    parser.add_argument(
        "--samples",
        type=int,
        default=1,
        help="Number of timing samples (default: 1)",
    )
    return parser.parse_args()


def load_circuit(path):
    with open(path, "r") as f:
        data = json.load(f)
    schema = data.get("schema_version", "")
    if schema != "pps-circuit-v1":
        print(
            f"ERROR: unsupported circuit schema version: {schema!r}", file=sys.stderr
        )
        sys.exit(1)
    return data


def _to_qiskit_pauli_str(qubit, op, nqubits):
    """Return a Qiskit Pauli string with `op` at `qubit`.

    Qiskit Pauli string convention: qubit 0 is the RIGHTMOST character.
    So qubit q maps to index (nqubits - 1 - q) in the string.
    """
    arr = ["I"] * nqubits
    arr[nqubits - 1 - qubit] = op
    return "".join(arr)


def build_qiskit_circuit(circuit_desc):
    nqubits = circuit_desc["nqubits"]
    qc = QuantumCircuit(nqubits)

    for gate in circuit_desc["gates"]:
        if gate["type"] != "pauli_rotation":
            print(
                f"ERROR: unsupported gate type: {gate['type']!r}", file=sys.stderr
            )
            sys.exit(1)

        paulis = gate["paulis"]
        qubits = gate["qubits"]
        theta = gate["theta"]

        if len(paulis) == 1:
            p = paulis[0]
            q = qubits[0]
            if p == "X":
                qc.rx(theta, q)
            elif p == "Y":
                qc.ry(theta, q)
            elif p == "Z":
                qc.rz(theta, q)
            elif p == "I":
                # Global phase only — identity rotation; skip or apply as RZ(theta, q)
                # exp(-i theta/2 I) = global phase, no observable effect
                pass
            else:
                print(f"ERROR: unsupported Pauli symbol: {p!r}", file=sys.stderr)
                sys.exit(1)
        elif len(paulis) == 2:
            p0, p1 = paulis[0], paulis[1]
            q0, q1 = qubits[0], qubits[1]
            if p0 == "Z" and p1 == "Z":
                qc.rzz(theta, q0, q1)
            elif p0 == "X" and p1 == "X":
                qc.rxx(theta, q0, q1)
            elif p0 == "Y" and p1 == "Y":
                qc.ryy(theta, q0, q1)
            else:
                # General two-qubit Pauli rotation via PauliEvolutionGate.
                # Qiskit Pauli string uses reversed qubit order, so we must
                # build the string carefully.
                pauli_str = _build_pauli_str_for_gate(paulis, qubits, nqubits)
                pauli_op = SparsePauliOp(pauli_str)
                gate_obj = PauliEvolutionGate(pauli_op, time=theta / 2)
                qc.append(gate_obj, qubits)
        else:
            # General multi-qubit Pauli rotation
            pauli_str = _build_pauli_str_for_gate(paulis, qubits, nqubits)
            pauli_op = SparsePauliOp(pauli_str)
            gate_obj = PauliEvolutionGate(pauli_op, time=theta / 2)
            qc.append(gate_obj, qubits)

    return qc


def _build_pauli_str_for_gate(paulis, qubits, nqubits):
    """Build a full-width Qiskit Pauli string for a multi-qubit gate.

    Maps each (qubit, pauli) pair into a length-nqubits string using
    Qiskit's reversed qubit ordering (qubit 0 = rightmost character).
    """
    arr = ["I"] * nqubits
    for q, p in zip(qubits, paulis):
        arr[nqubits - 1 - q] = p
    return "".join(arr)


def build_pauli_sum(circuit_desc):
    """Convert the circuit observable string to a BlueQubit pauli_sum list.

    Supported observable formats:
    - "Z0"   — Z on qubit 0
    - "Z62"  — Z on qubit 62
    - "Mz"   — magnetisation: (1/nqubits) * sum_i Z_i

    Returns a list of (pauli_string, coefficient) tuples.
    The pauli_string has length nqubits; qubit 0 is the rightmost character
    (Qiskit convention, which BlueQubit follows when accepting pauli_sum).
    """
    nqubits = circuit_desc["nqubits"]
    observable = circuit_desc["observable"]

    if observable.startswith("Z") and observable[1:].isdigit():
        qubit_idx = int(observable[1:])
        pauli_str = _to_qiskit_pauli_str(qubit_idx, "Z", nqubits)
        return [(pauli_str, 1.0)]

    if observable == "Mz":
        coeff = 1.0 / nqubits
        return [
            (_to_qiskit_pauli_str(q, "Z", nqubits), coeff) for q in range(nqubits)
        ]

    print(
        f"ERROR: unsupported observable: {observable!r}", file=sys.stderr
    )
    sys.exit(1)


def _peak_rss_bytes():
    """Return peak RSS in bytes (Linux: KB units from getrusage)."""
    usage = resource.getrusage(resource.RUSAGE_SELF)
    return usage.ru_maxrss * 1024  # Linux reports in KB


def _run_single(bq_client, qc, pauli_sum, task_id, truncation_threshold):
    """Run one BlueQubit call and return (expectation, elapsed_sec)."""
    t0 = time.perf_counter()
    result = bq_client.run(
        qc,
        device="pauli-path",
        pauli_sum=pauli_sum,
        pauli_path_truncation_threshold=truncation_threshold,
        job_name=f"bench_{task_id}",
        asynchronous=False,
    )
    elapsed = time.perf_counter() - t0
    return float(result.expectation_value), elapsed


def run_benchmark(circuit_desc, samples):
    api_token = os.environ.get("BLUEQUBIT_API_TOKEN", "")
    if not api_token:
        print(
            "ERROR: BLUEQUBIT_API_TOKEN environment variable is not set",
            file=sys.stderr,
        )
        sys.exit(1)

    bq_client = bluequbit.init()

    qc = build_qiskit_circuit(circuit_desc)
    pauli_sum = build_pauli_sum(circuit_desc)

    task_id = circuit_desc["task_id"]
    truncation_threshold = float(
        circuit_desc.get("truncation", {}).get("threshold", 1e-8)
    )

    # Collect timing samples.
    times = []
    expectation = None
    for _ in range(max(1, samples)):
        try:
            val, elapsed = _run_single(
                bq_client, qc, pauli_sum, task_id, truncation_threshold
            )
        except Exception as e:
            print(f"ERROR: BlueQubit API call failed: {e}", file=sys.stderr)
            sys.exit(1)
        times.append(elapsed)
        expectation = val

    median_time = statistics.median(times)
    total_time = sum(times)
    peak_rss = _peak_rss_bytes()

    # Reference: run with truncation_threshold=0.0 (exact).
    # If truncation_threshold is already 0.0, reference == expectation.
    if truncation_threshold == 0.0:
        reference = expectation
    else:
        try:
            reference, _ = _run_single(
                bq_client, qc, pauli_sum, task_id + "_ref", 0.0
            )
        except Exception as e:
            print(
                f"ERROR: BlueQubit reference API call failed: {e}", file=sys.stderr
            )
            sys.exit(1)

    absolute_error = abs(expectation - reference)

    # Retrieve bluequbit package version safely.
    try:
        import importlib.metadata
        bq_version = importlib.metadata.version("bluequbit")
    except Exception:
        bq_version = "unknown"

    return {
        "backend": "python_bluequbit",
        "task_id": task_id,
        "success": True,
        "runtime_sec": total_time,
        "memory_bytes": peak_rss,
        "final_terms": -1,
        "expectation": expectation,
        "reference": reference,
        "absolute_error": absolute_error,
        "metadata": {
            "engine": "bluequbit",
            "bluequbit_version": bq_version,
            "device": "pauli-path",
            "truncation_threshold": truncation_threshold,
            "circuit_schema_version": "pps-circuit-v1",
            "nqubits": circuit_desc["nqubits"],
            "circuit_size": len(circuit_desc["gates"]),
            "observable": circuit_desc["observable"],
            "family": circuit_desc.get("family", ""),
            "median_time_sec": median_time,
            "memory_measure": "process_peak_rss",
        },
    }


def main():
    args = parse_args()
    circuit_desc = load_circuit(args.circuit)
    result = run_benchmark(circuit_desc, args.samples)
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
