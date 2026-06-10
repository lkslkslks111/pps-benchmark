#!/usr/bin/env python3
"""
pauliengine_runner.py — C++ / PauliEngine benchmark runner for pps-benchmark.

Subprocess contract:
  Input:  --circuit <pps-circuit-v1.json> [--samples <n>]
  Success: exits 0, prints one JSON line to stdout
  Failure: prints diagnostic to stderr, exits 1

Algorithm: Heisenberg-picture Pauli propagation.
  - Start with the observable as a list of (pauli_dict, coeff) terms.
  - Walk gates in reverse order.
  - For each gate, check commutation with each term; split anticommuting terms.
  - Truncate terms with |coeff| < threshold.
  - Expectation = sum of coefficients for terms with all Paulis in {I, Z}.
"""

import argparse
import json
import math
import os
import resource
import sys
import time

# --- Single-core enforcement (must be before any library import) ---
for _env_var in (
    "OMP_NUM_THREADS",
    "OPENBLAS_NUM_THREADS",
    "MKL_NUM_THREADS",
    "VECLIB_MAXIMUM_THREADS",
    "NUMEXPR_NUM_THREADS",
):
    if _env_var not in os.environ:
        os.environ[_env_var] = "1"

_THREAD_LIMITS = {
    var: os.environ.get(var, "1")
    for var in (
        "OMP_NUM_THREADS",
        "OPENBLAS_NUM_THREADS",
        "MKL_NUM_THREADS",
        "VECLIB_MAXIMUM_THREADS",
        "NUMEXPR_NUM_THREADS",
    )
}

# --- Attempt pauliengine import (optional: falls back to built-in Python engine) ---
try:
    import pauliengine as _pe

    _PAULIENGINE_AVAILABLE = True
    try:
        _PAULIENGINE_VERSION = _pe.__version__
    except AttributeError:
        try:
            import importlib.metadata
            _PAULIENGINE_VERSION = importlib.metadata.version("pauliengine")
        except Exception:
            _PAULIENGINE_VERSION = "unknown"
except ImportError:
    _PAULIENGINE_AVAILABLE = False
    _PAULIENGINE_VERSION = "python_fallback"


# ---------------------------------------------------------------------------
# Pauli arithmetic helpers
# ---------------------------------------------------------------------------

# Multiplication table: (a, b) -> (phase, result)
# phase is complex (1, -1, 1j, -1j); result is the Pauli character
_PAULI_MUL: dict[tuple[str, str], tuple[complex, str]] = {
    ("I", "I"): (1, "I"),
    ("I", "X"): (1, "X"),
    ("I", "Y"): (1, "Y"),
    ("I", "Z"): (1, "Z"),
    ("X", "I"): (1, "X"),
    ("X", "X"): (1, "I"),
    ("X", "Y"): (1j, "Z"),
    ("X", "Z"): (-1j, "Y"),
    ("Y", "I"): (1, "Y"),
    ("Y", "X"): (-1j, "Z"),
    ("Y", "Y"): (1, "I"),
    ("Y", "Z"): (1j, "X"),
    ("Z", "I"): (1, "Z"),
    ("Z", "X"): (1j, "Y"),
    ("Z", "Y"): (-1j, "X"),
    ("Z", "Z"): (1, "I"),
}


def commutes(a: dict, b: dict) -> bool:
    """Return True iff Pauli dicts a and b commute."""
    count = sum(
        1
        for q in a
        if a[q] != "I" and b.get(q, "I") != "I" and a[q] != b.get(q, "I")
    )
    return count % 2 == 0


def multiply_pauli_strings(
    a_dict: dict, b_dict: dict
) -> tuple[complex, dict]:
    """Multiply two Pauli strings (dicts) qubit by qubit.

    Returns (phase, result_dict) where result_dict omits identity qubits.
    """
    all_qubits = set(a_dict) | set(b_dict)
    phase: complex = 1
    result: dict = {}
    for q in all_qubits:
        pa = a_dict.get(q, "I")
        pb = b_dict.get(q, "I")
        p_phase, p_char = _PAULI_MUL[(pa, pb)]
        phase *= p_phase
        if p_char != "I":
            result[q] = p_char
    return phase, result


def pauli_dict_key(d: dict) -> tuple:
    """Canonical hashable key for a Pauli dict."""
    return tuple(sorted(d.items()))


# ---------------------------------------------------------------------------
# PauliEngine-backed propagation (used when the C++ extension is installed)
# ---------------------------------------------------------------------------
#
# PauliEngine encodes a Pauli string as packed bit words (64 qubits per word):
#   X -> (x=1, y=0), Y -> (x=0, y=1), Z -> (x=1, y=1), I -> (0, 0)
# so  all-Z  <=>  x == y  per word, weight = popcount(x | y), and two strings
# anticommute iff parity(popcount(ax & by) + popcount(ay & bx)) is odd.
# The C++ core performs the Pauli products (phase tracking included); this
# loop owns gate ordering, term merging, and truncation.


def _pe_anticommutes(ax, ay, bx, by) -> bool:
    parity = 0
    for i in range(max(len(ax), len(bx))):
        awx = ax[i] if i < len(ax) else 0
        awy = ay[i] if i < len(ay) else 0
        bwx = bx[i] if i < len(bx) else 0
        bwy = by[i] if i < len(by) else 0
        parity ^= ((awx & bwy).bit_count() ^ (awy & bwx).bit_count()) & 1
    return parity == 1


def _pe_weight(ps) -> int:
    return sum((wx | wy).bit_count() for wx, wy in zip(ps.x, ps.y))


def _pe_is_all_z(ps) -> bool:
    return ps.x == ps.y


def propagate_pauliengine(
    initial_terms: list[tuple[dict, complex]],
    gates: list[dict],
    threshold: float,
    max_weight: int | None = None,
):
    """Heisenberg-picture propagation on PauliEngine C++ Pauli strings.

    Same algorithm and truncation semantics as the pure-Python `propagate`;
    returns (list_of_PauliStringComplex, peak_terms, terms_history).
    """
    state: dict = {}
    for pd, coeff in initial_terms:
        ps = _pe.PauliString(complex(coeff), {q: p for q, p in pd.items() if p != "I"})
        if max_weight is not None and _pe_weight(ps) > max_weight:
            continue
        key = (tuple(ps.x), tuple(ps.y))
        if key in state:
            state[key].set_coeff(state[key].coeff + ps.coeff)
        else:
            state[key] = ps

    peak_terms = len(state)
    terms_history: list[int] = []

    for gate in gates[::-1]:
        gate_ps = _pe.PauliString(
            1.0,
            {
                gate["qubits"][i]: gate["paulis"][i]
                for i in range(len(gate["paulis"]))
                if gate["paulis"][i] != "I"
            },
        )
        gx, gy = tuple(gate_ps.x), tuple(gate_ps.y)
        cos_t = math.cos(gate["theta"])
        isin_t = 1j * math.sin(gate["theta"])

        new_state: dict = {}
        for key, ps in state.items():
            if not _pe_anticommutes(gx, gy, key[0], key[1]):
                if key in new_state:
                    new_state[key].set_coeff(new_state[key].coeff + ps.coeff)
                else:
                    new_state[key] = ps
                continue

            # sin branch first: the product must see the original coefficient.
            # prod.coeff = pauli_phase * ps.coeff, so c2 = prod.coeff * i*sin.
            prod = gate_ps * ps
            c2 = prod.coeff * isin_t

            # cos branch: same Pauli word, scaled coefficient
            c1 = ps.coeff * cos_t
            if abs(c1) >= threshold:
                if key in new_state:
                    new_state[key].set_coeff(new_state[key].coeff + c1)
                else:
                    ps.set_coeff(c1)
                    new_state[key] = ps

            if abs(c2) >= threshold:
                if max_weight is None or _pe_weight(prod) <= max_weight:
                    pkey = (tuple(prod.x), tuple(prod.y))
                    if pkey in new_state:
                        new_state[pkey].set_coeff(new_state[pkey].coeff + c2)
                    else:
                        prod.set_coeff(c2)
                        new_state[pkey] = prod

        if threshold > 0.0:
            state = {
                k: v for k, v in new_state.items() if abs(v.coeff) >= threshold
            }
        else:
            state = new_state

        terms_history.append(len(state))
        peak_terms = max(peak_terms, len(state))

    return list(state.values()), peak_terms, terms_history


def compute_expectation_pauliengine(terms) -> float:
    """<0..0|O|0..0> = sum of real coefficients of all-Z PauliEngine terms."""
    return sum(ps.coeff.real for ps in terms if _pe_is_all_z(ps))


# ---------------------------------------------------------------------------
# Observable parsing
# ---------------------------------------------------------------------------

def parse_observable(obs_str: str, nqubits: int) -> list[tuple[dict, complex]]:
    """Parse observable string into list of (pauli_dict, coeff) terms.

    Supported forms:
      - "Z0", "X5", "Y3"  — single-qubit Pauli on qubit int(obs[1:])
      - "Mz" or "magnetization" — sum of Z_i / nqubits for each qubit i
    """
    obs = obs_str.strip()
    if obs in ("Mz", "magnetization"):
        return [({i: "Z"}, 1.0 / nqubits) for i in range(nqubits)]
    if len(obs) >= 2 and obs[0] in ("X", "Y", "Z"):
        qubit = int(obs[1:])
        return [({qubit: obs[0]}, 1.0)]
    raise ValueError(f"Unsupported observable: {obs_str!r}")


# ---------------------------------------------------------------------------
# Propagation core
# ---------------------------------------------------------------------------

def pauli_weight(pd: dict) -> int:
    """Number of non-identity single-qubit Paulis in a Pauli dict."""
    return sum(1 for p in pd.values() if p != "I")


def propagate(
    initial_terms: list[tuple[dict, complex]],
    gates: list[dict],
    threshold: float,
    max_weight: int | None = None,
) -> tuple[list[tuple[dict, complex]], int, list[int]]:
    """Heisenberg-picture Pauli propagation.

    Returns (final_terms, peak_terms, terms_history): peak_terms is the
    largest term count observed after any gate application, terms_history the
    per-gate term counts in application (Heisenberg) order.

    Walk gates in reverse order.  For each gate:
      - gate Pauli K_dict built from gate['paulis'] and gate['qubits']
      - theta = gate['theta']
      - For each (pauli_dict, coeff) in current terms:
          if commutes(K_dict, pauli_dict):
            -> keep (pauli_dict, coeff) unchanged
          else (anticommutes):
            -> (pauli_dict, coeff * cos(theta))
            -> (K*pauli, coeff * 1j * sin(theta))
    Truncate |coeff| < threshold and Pauli weight > max_weight.
    Merge duplicate Pauli strings.
    """
    # Represent as dict: key -> coeff
    term_map: dict[tuple, tuple[dict, complex]] = {}
    for pd, coeff in initial_terms:
        if max_weight is not None and pauli_weight(pd) > max_weight:
            continue
        k = pauli_dict_key(pd)
        if k in term_map:
            term_map[k] = (pd, term_map[k][1] + coeff)
        else:
            term_map[k] = (pd, coeff)

    peak_terms = len(term_map)
    terms_history: list[int] = []

    for gate in reversed(gates):
        paulis = gate["paulis"]
        qubits = gate["qubits"]
        theta = gate["theta"]

        k_dict = {qubits[i]: paulis[i] for i in range(len(paulis)) if paulis[i] != "I"}

        cos_t = math.cos(theta)
        sin_t = math.sin(theta)

        new_map: dict[tuple, tuple[dict, complex]] = {}

        for key, (pd, coeff) in term_map.items():
            if commutes(k_dict, pd):
                # commutes: unchanged
                if key in new_map:
                    new_map[key] = (pd, new_map[key][1] + coeff)
                else:
                    new_map[key] = (pd, coeff)
            else:
                # anticommutes: split
                c1 = coeff * cos_t
                if abs(c1) >= threshold:
                    if key in new_map:
                        new_map[key] = (pd, new_map[key][1] + c1)
                    else:
                        new_map[key] = (pd, c1)

                phase, kpd = multiply_pauli_strings(k_dict, pd)
                c2 = coeff * 1j * sin_t * phase
                if abs(c2) >= threshold:
                    if max_weight is None or pauli_weight(kpd) <= max_weight:
                        k2 = pauli_dict_key(kpd)
                        if k2 in new_map:
                            new_map[k2] = (kpd, new_map[k2][1] + c2)
                        else:
                            new_map[k2] = (kpd, c2)

        # Truncate by coefficient
        if threshold > 0.0:
            term_map = {
                k: v for k, v in new_map.items() if abs(v[1]) >= threshold
            }
        else:
            term_map = new_map

        terms_history.append(len(term_map))
        peak_terms = max(peak_terms, len(term_map))

    return list(term_map.values()), peak_terms, terms_history


def compute_expectation(terms: list[tuple[dict, complex]]) -> float:
    """<0..0|O_propagated|0..0> = sum of coeff for terms where all Paulis in {I, Z}.

    An empty dict (identity) or a dict with only Z entries contributes.
    """
    total = 0.0
    for pd, coeff in terms:
        if all(p in ("I", "Z") for p in pd.values()):
            total += coeff.real
    return total


# ---------------------------------------------------------------------------
# Memory measurement
# ---------------------------------------------------------------------------

def peak_rss_bytes() -> int:
    """Return peak RSS in bytes (Linux: ru_maxrss is in kB)."""
    usage = resource.getrusage(resource.RUSAGE_SELF)
    return usage.ru_maxrss * 1024


# ---------------------------------------------------------------------------
# Main benchmark logic
# ---------------------------------------------------------------------------

def run_benchmark(circuit_path: str, samples: int) -> dict:
    with open(circuit_path) as f:
        circuit = json.load(f)

    nqubits: int = circuit["nqubits"]
    gates: list[dict] = circuit["gates"]
    obs_str: str = circuit["observable"]
    task_id: str = circuit["task_id"]
    family: str = circuit.get("family", "unknown")

    trunc_cfg = circuit.get("truncation", {})
    threshold: float = float(
        trunc_cfg.get("coefficient_threshold", trunc_cfg.get("threshold", 1e-8))
    )
    raw_weight = trunc_cfg.get("pauli_weight_cutoff")
    max_weight: int | None = int(raw_weight) if raw_weight is not None else None

    initial_terms = parse_observable(obs_str, nqubits)

    # --- Timed propagation (possibly multiple samples) ---
    runtimes: list[float] = []
    final_terms_count = 0
    expectation = 0.0

    peak_terms = 0
    terms_history: list[int] = []
    if _PAULIENGINE_AVAILABLE:
        propagate_fn = propagate_pauliengine
        expectation_fn = compute_expectation_pauliengine
    else:
        propagate_fn = propagate
        expectation_fn = compute_expectation

    for _ in range(samples):
        t0 = time.perf_counter()
        result_terms, peak_terms, terms_history = propagate_fn(
            initial_terms, gates, threshold, max_weight
        )
        t1 = time.perf_counter()
        runtimes.append(t1 - t0)
        final_terms_count = len(result_terms)
        expectation = expectation_fn(result_terms)

    runtimes.sort()
    median_idx = (len(runtimes) - 1) // 2
    if len(runtimes) % 2 == 1:
        median_time = runtimes[median_idx]
    else:
        median_time = (runtimes[median_idx] + runtimes[median_idx + 1]) / 2.0
    runtime_sec = median_time

    mem_bytes = peak_rss_bytes()

    # --- Reference (exact propagation: no coefficient or weight truncation) ---
    if threshold == 0.0 and max_weight is None:
        reference = expectation
        absolute_error = 0.0
    else:
        ref_terms, _, _ = propagate_fn(initial_terms, gates, 0.0)
        reference = expectation_fn(ref_terms)
        absolute_error = abs(expectation - reference)

    throughput = final_terms_count / runtime_sec if runtime_sec > 0 else None

    return {
        "backend": "cpp_pauliengine",
        "task_id": task_id,
        "success": True,
        "runtime_sec": runtime_sec,
        "memory_bytes": mem_bytes,
        "final_terms": final_terms_count,
        "peak_terms": peak_terms,
        "throughput_terms_per_sec": throughput,
        "expectation": expectation,
        "reference": reference,
        "absolute_error": absolute_error,
        "metadata": {
            "engine": "pauliengine",
            "pauliengine_version": _PAULIENGINE_VERSION,
            "truncation_threshold": threshold,
            "truncation_applied": {
                "method": "threshold",
                "coefficient_threshold": threshold,
                "pauli_weight_cutoff": max_weight,
                "max_terms": None,
                "max_freq": None,
                "max_weight": None,
            },
            "terms_history": terms_history,
            "circuit_schema_version": circuit.get("schema_version", "pps-circuit-v1"),
            "nqubits": nqubits,
            "circuit_size": len(gates),
            "observable": obs_str,
            "family": family,
            "median_time_sec": median_time,
            "memory_measure": "process_peak_rss",
            "thread_limits": _THREAD_LIMITS,
        },
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description="PauliEngine C++ benchmark runner for pps-benchmark"
    )
    parser.add_argument("--circuit", required=True, help="Path to pps-circuit-v1 JSON file")
    parser.add_argument(
        "--samples",
        type=int,
        default=1,
        help="Number of propagation runs to take the median over (default: 1)",
    )
    args = parser.parse_args()

    if args.samples < 1:
        print("ERROR: --samples must be >= 1", file=sys.stderr)
        return 1

    try:
        result = run_benchmark(args.circuit, args.samples)
    except Exception as exc:
        print(f"ERROR: benchmark failed: {exc}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        return 1

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
