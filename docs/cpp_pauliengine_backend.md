# C++ / PauliEngine backend (`cpp_pauliengine`)

Issue [#17](https://github.com/lkslkslks111/pps-benchmark/issues/17) adds the
fourth backend in `pps-benchmark`: a Python subprocess runner that uses the
[`pauliengine`](https://github.com/tequilahub/pauliengine) C++ library via its
Python bindings.

## Architecture

```
Julia orchestration                         Python subprocess runner
───────────────────                         ────────────────────────
benchmarks/run_backend.jl
  --backend cpp_pauliengine --config X.toml
    └ _make_backend → CppPauliEngineBackend
        └ run_backend(spec):
            1. export_circuit(spec)
            2. write_circuit_description → mktemp() → /tmp/.../circuit.json
            3. run(`python3                ┌─ read --circuit JSON
                    pauliengine_runner.py  │  import pauliengine
                    --circuit X.json       │  Heisenberg propagation loop
                    --samples 1`)────────→ │  compute expectation / reference
            4. parse stdout JSON     ←──── │  measure time / memory
               → BenchmarkResult           └─ stdout: BenchmarkResult JSON
            5. delete tmp file
```

The circuit is generated exactly once on the Julia side and shipped via the
`pps-circuit-v1` format (see [`circuit_exchange_schema.md`](circuit_exchange_schema.md)).
The Python runner consumes the explicit `gates` list — it never rebuilds a
circuit from `family` / `nqubits` / `nlayers`.

## Subprocess contract

**Input.** `python3 pauliengine_runner.py --circuit <path> [--samples <n>]`,
where `<path>` is a `pps-circuit-v1` JSON file and `--samples` (default: 1)
controls how many propagation runs are taken for the median runtime.

**Success.** One JSON line on stdout with exactly the fields of the
`BenchmarkResult` schema (`src/io/schema.jl::benchmark_result_dict`):

| Field | Value |
|---|---|
| `backend` | `"cpp_pauliengine"` |
| `task_id` | from circuit JSON |
| `success` | `true` |
| `runtime_sec` | median propagation time across samples |
| `memory_bytes` | process peak RSS in bytes |
| `final_terms` | number of Pauli terms after truncation |
| `expectation` | `<0…0\|O_propagated\|0…0>` |
| `reference` | same with threshold=0.0 |
| `absolute_error` | `|expectation - reference|` |
| `metadata` | see below |

**Metadata fields:**

| Key | Description |
|---|---|
| `engine` | `"pauliengine"` |
| `pauliengine_version` | version string or `"unknown"` |
| `truncation_threshold` | threshold read from circuit JSON |
| `circuit_schema_version` | `"pps-circuit-v1"` |
| `nqubits` | number of qubits |
| `circuit_size` | number of gates |
| `observable` | observable string |
| `family` | circuit family |
| `median_time_sec` | median propagation time across samples |
| `memory_measure` | `"process_peak_rss"` |
| `thread_limits` | dict of thread env vars set at startup |
| `circuit_source` | injected by Julia wrapper (`"exported_from_spec"` or `"circuit_json"`) |

**Failure.** Diagnostic on stderr, exit code non-zero. The Julia wrapper raises
an `ErrorException` carrying the captured stderr.

## Algorithm

Heisenberg-picture Pauli propagation with coefficient-threshold truncation.

### Notation

A Pauli term is `(P, c)` where `P` is a Pauli dictionary `{qubit: "X"|"Y"|"Z"}`
(identity qubits are omitted) and `c ∈ ℂ` is the coefficient.

The observable `O` starts as a list of such terms (parsed from `circuit['observable']`).

### Propagation loop

For each gate in `reversed(circuit['gates'])`:

```
K_dict = {gate['qubits'][i]: gate['paulis'][i] for i in range(len(gate['paulis']))
          if gate['paulis'][i] != 'I'}
theta = gate['theta']

for (P, c) in current_terms:
  if commutes(K_dict, P):
    new_terms += [(P, c)]
  else:
    new_terms += [(P,          c * cos(theta))]
    new_terms += [(K_dict * P, c * 1j * sin(theta))]

current_terms = merge_and_truncate(new_terms, threshold)
```

### Commutativity check

Two Pauli dicts `a` and `b` commute iff the number of qubits where both are
non-identity and different is even:

```python
def commutes(a, b):
    count = sum(1 for q in a
                if a[q] != 'I' and b.get(q,'I') != 'I' and a[q] != b.get(q,'I'))
    return count % 2 == 0
```

### Pauli multiplication table

```
X*X = I    Y*Y = I    Z*Z = I
I*P = P    P*I = P
X*Y = iZ   Y*X = -iZ
Y*Z = iX   Z*Y = -iX
X*Z = -iY  Z*X = iY
```

Phase factors accumulate qubit by qubit.

### Expectation

After propagation:

```
<0…0|O_propagated|0…0> = Re( sum of c for all (P, c) where every Pauli in P is I or Z )
```

This matches `real(overlapwithzero(...))` in the Julia backend.

### Reference

The reference value is computed by re-running propagation with `threshold=0.0`.
If `threshold` is already `0.0`, `reference = expectation` and
`absolute_error = 0.0`.

## Observable parsing

| Observable string | Interpretation |
|---|---|
| `"Z0"`, `"X5"`, `"Y3"` | single-qubit Pauli on qubit `int(obs[1:])`, coeff=1.0 |
| `"Mz"` or `"magnetization"` | sum of `Z_i / nqubits` for each qubit `i` |

## Truncation

Terms with `|coeff| < threshold` are dropped after each gate.  The threshold is
read from `circuit['truncation']['threshold']`; default is `1e-8`.

## Single-core enforcement

The runner sets the following environment variables to `"1"` at startup (before
any library import) if they are not already set by the caller:

`OMP_NUM_THREADS`, `OPENBLAS_NUM_THREADS`, `MKL_NUM_THREADS`,
`VECLIB_MAXIMUM_THREADS`, `NUMEXPR_NUM_THREADS`

Resolved values are recorded in `metadata.thread_limits` for every run.

## Memory accounting

`memory_bytes` is measured via
`resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024` (Linux: `ru_maxrss`
is in kB).  This is the whole-process peak RSS including interpreter startup.
The measure is recorded in `metadata.memory_measure = "process_peak_rss"`.

## Python environment

`make build-cpp` creates `wrappers/cpp/.venv`, upgrades pip, and installs
`wrappers/cpp/requirements.txt` (`pauliengine`).  If `pauliengine` is not
available on PyPI the venv creation will fail — the runner exits with code 1 on
`import pauliengine` failure.

The Julia wrapper uses the system `python3` by default; override with
`CppPauliEngineBackend(python_cmd="wrappers/cpp/.venv/bin/python")` to force
the venv interpreter.

## Reproducibility

- The venv is reproducible via `wrappers/cpp/requirements.txt`.
- `pauliengine_version` is recorded in every result's metadata.
- The numerical contract is checked by `make test-cpp`, which asserts
  `cpp_pauliengine` matches `julia_pauliprop` on `bench_small` (`atol = 1e-6`).

## Scope (Phase 1)

In scope: `bench_small` (`clifford_pauli_rotation`, n=4).
Out of scope: 127-qubit Eagle / Rudolph / LOWESA tasks and sweep runs.
