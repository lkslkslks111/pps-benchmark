# `cpp_pauliengine` — C++ / PauliEngine benchmark backend

A Python subprocess runner that uses the
[`pauliengine`](https://github.com/tequilahub/pauliengine) C++ library
(pip-installable) to benchmark Heisenberg-picture Pauli propagation with
coefficient-threshold truncation.  It is the fourth backend in the
`pps-benchmark` lineup.

The Julia orchestration wrapper lives at
[`../../src/backends/cpp_pauliengine.jl`](../../src/backends/cpp_pauliengine.jl).
The architecture and protocol are documented in
[`../../docs/cpp_pauliengine_backend.md`](../../docs/cpp_pauliengine_backend.md).

## Layout

```
wrappers/cpp/
├── pauliengine_runner.py   # Python subprocess entry point
├── requirements.txt        # pip dependencies (pauliengine)
└── README.md               # this file
```

## Installation

`pauliengine` is a pip package backed by a C++ core:

```bash
# Preferred: using the Makefile venv (from repo root)
make build-cpp

# Manual installation
pip install pauliengine

# From source (if pip package is not yet published)
# https://github.com/tequilahub/pauliengine
```

`make build-cpp` creates `wrappers/cpp/.venv`, upgrades pip, and installs
`requirements.txt`.  If the package is not published on PyPI the venv creation
will fail — `make smoke-cpp` and `make test-cpp` will skip gracefully.

## Usage

```bash
python3 wrappers/cpp/pauliengine_runner.py \
    --circuit <pps-circuit-v1.json> [--samples <n>]
```

`--samples` (default: 1) controls how many propagation runs are taken to
compute the median runtime.  For expensive circuits set `samples=1`; the Julia
wrapper default matches this.

## Subprocess contract

**Input**

```
python3 pauliengine_runner.py --circuit <path> [--samples <n>]
```

where `<path>` is a `pps-circuit-v1` JSON file.

**Success** — exits 0, prints one JSON line to stdout:

```json
{
  "backend": "cpp_pauliengine",
  "task_id": "...",
  "success": true,
  "runtime_sec": 0.0,
  "memory_bytes": 0,
  "final_terms": 0,
  "expectation": 0.0,
  "reference": 0.0,
  "absolute_error": 0.0,
  "metadata": {
    "engine": "pauliengine",
    "pauliengine_version": "...",
    "truncation_threshold": 1e-8,
    "circuit_schema_version": "pps-circuit-v1",
    "nqubits": 4,
    "circuit_size": 16,
    "observable": "Z0",
    "family": "clifford_pauli_rotation",
    "median_time_sec": 0.0,
    "memory_measure": "process_peak_rss",
    "thread_limits": {"OMP_NUM_THREADS": "1", ...}
  }
}
```

**Failure** — prints diagnostic to stderr, exits non-zero.

If `import pauliengine` fails the runner exits immediately with code 1.

## Algorithm

Heisenberg-picture Pauli propagation:

1. Parse observable `circuit['observable']` into a list of `(pauli_dict, coeff)` terms.
2. Walk gates in **reverse** order.
3. For each gate, build `K_dict` from `gate['paulis']` and `gate['qubits']`.
4. For each `(pauli_dict, coeff)` term:
   - if `commutes(K_dict, pauli_dict)`: keep term unchanged.
   - else (anticommutes):
     - add `(pauli_dict, coeff * cos(theta))`
     - add `(K_dict * pauli_dict, coeff * 1j * sin(theta))`
5. Merge duplicate Pauli strings, truncate `|coeff| < threshold`.
6. Expectation `<0…0|O|0…0>` = sum of real parts of coefficients for terms
   where every qubit Pauli is `I` or `Z`.

The reference value is computed by re-running propagation with `threshold=0.0`.

## Single-core enforcement

The runner sets `OMP_NUM_THREADS`, `OPENBLAS_NUM_THREADS`, `MKL_NUM_THREADS`,
`VECLIB_MAXIMUM_THREADS`, and `NUMEXPR_NUM_THREADS` to `"1"` at startup
(before any library import) if they are not already set.  Resolved values are
recorded in `metadata.thread_limits`.

## Memory accounting

`memory_bytes` is the process peak RSS (whole-process, including interpreter
startup) measured via `resource.getrusage(RUSAGE_SELF).ru_maxrss * 1024` on
Linux.  This matches the Rust backend's `process_peak_rss` measure and is
recorded in `metadata.memory_measure`.
