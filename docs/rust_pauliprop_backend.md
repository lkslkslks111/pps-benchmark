# Rust / Qiskit pauli-prop backend (`rust_pauliprop`)

Issue [#13](https://github.com/lkslkslks111/pps-benchmark/issues/13) adds the
third backend in `pps-benchmark`: a Rust binary that drives
[`Qiskit/pauli-prop`](https://github.com/Qiskit/pauli-prop) via PyO3.

`pauli-prop` is a pip package (v0.2.0, Apache-2.0) with a Python API backed by a
Rust core, and it natively implements the algorithm this benchmark needs:
Heisenberg-picture operator propagation with coefficient-threshold truncation.

## Architecture

```
Julia orchestration                             Rust runner (subprocess)
───────────────────                            ────────────────────────
benchmarks/run_backend.jl
  --backend rust_pauliprop --config X.toml
    └ _make_backend → RustPauliPropBackend
        └ run_backend(spec):
            1. export_circuit(spec)
            2. write_circuit_description → mktemp() → /tmp/.../circuit.json
            3. run(`rust_pauliprop_runner            ┌─ read --circuit JSON (serde_json)
                    --circuit X.json --samples 5`)─→ │  embed CPython (PyO3 auto-initialize)
            4. parse stdout JSON                ←─── │  pauli_prop.propagate_through_circuit
               → BenchmarkResult                     │  expectation / reference / time / memory
            5. delete tmp file                       └─ stdout: BenchmarkResult JSON
```

The circuit is generated exactly once on the Julia side and shipped through
`pps-circuit-v1` (see [`circuit_exchange_schema.md`](circuit_exchange_schema.md)).
The Rust runner consumes the explicit `gates` list — it never rebuilds a
circuit from `family` / `nqubits` / `nlayers`.

## Subprocess contract

**Input.** `rust_pauliprop_runner --circuit <path> [--samples <n>]`, where
`<path>` is a `pps-circuit-v1` JSON file. `--samples` defaults to 5 and must be
positive.

**Success.** One JSON line on stdout with exactly the fields of the
`BenchmarkResult` schema (`src/io/schema.jl::benchmark_result_dict`):

- `backend` = `"rust_pauliprop"`
- `task_id`, `success`, `runtime_sec` (median across samples), `memory_bytes`
  (peak resident set in bytes), `final_terms`, `expectation`, `reference`,
  `absolute_error`
- `metadata` (additive):
  - `engine = "qiskit_pauli_prop"`
  - `pauli_prop_version`, `qiskit_version`
  - `benchmark_samples`, `minimum_time_sec`, `median_time_sec`
  - `truncated_one_norm` (the one-norm of dropped coefficients returned by
    `propagate_through_circuit`)
  - `circuit_size`, `truncation_threshold`, `observable`
  - `circuit_source`, `family`, `nqubits`, `circuit_schema_version`
  - `thread_limits` — `{OMP,OPENBLAS,MKL,VECLIB_MAXIMUM,NUMEXPR,RAYON}_NUM_THREADS`
    as resolved at runner startup; see [Single-core enforcement](#single-core-enforcement).
  - `memory_measure = "process_peak_rss"` — see [Memory accounting](#memory-accounting).
  - The Julia subprocess backend overrides `circuit_source` to
    `"exported_from_spec"` when called with a `BenchmarkSpec`.

**Failure.** Diagnostic on stderr, exit code 1. The Julia subprocess backend
raises an `ErrorException` carrying the captured stderr.

## `pps-circuit-v1` → Qiskit gate mapping

Each gate is a Pauli rotation `exp(-i*theta/2 * P)`. Qiskit's `rx`/`ry`/`rz`
and `rxx`/`ryy`/`rzz` use the same convention, so single- and uniform two-qubit
Pauli rotations map directly. Mixed or >2 qubit rotations fall back to a
`PauliEvolutionGate` with `time = theta / 2` (since
`PauliEvolutionGate(P, time=t) = exp(-i*t*P)`).

| `pps-circuit-v1` gate                | Qiskit gate                                          |
|--------------------------------------|------------------------------------------------------|
| `paulis = ["X" / "Y" / "Z"]`         | `qc.rx / ry / rz(theta, qubit)`                      |
| `paulis = ["Z","Z"] / ["X","X"] / ["Y","Y"]` | `qc.rzz / rxx / ryy(theta, q0, q1)`          |
| anything else (mixed / 3+ qubit)     | `PauliEvolutionGate(SparsePauliOp(label), time=theta/2)` |

`bench_small` (`clifford_pauli_rotation`, n=4) only exercises the first two
rows. The third row is exercised by `make test-rust`, which adds a synthetic
4-qubit circuit with a mixed two-qubit `["X","Z"]` rotation and a 3-qubit
`["Y","Z","X"]` rotation, and asserts `rust_pauliprop` matches
`julia_pauliprop` (`atol = 1e-6`) on both `expectation` and `reference`.

## Single-core enforcement

Single-core is the project benchmark policy. The runner sets these
environment variables to `"1"` at startup, before the embedded interpreter
imports `numpy`/`qiskit`/`pauli-prop` (BLAS pools and Rayon latch the value
at first use):

`OMP_NUM_THREADS`, `OPENBLAS_NUM_THREADS`, `MKL_NUM_THREADS`,
`VECLIB_MAXIMUM_THREADS`, `NUMEXPR_NUM_THREADS`, `RAYON_NUM_THREADS`

Callers can override any variable by exporting it explicitly; the runner only
sets variables that are unset. The resolved values are recorded in
`metadata.thread_limits` for every run.

## Memory accounting

The `memory_bytes` field uses different definitions across backends, so cross-
backend comparison is meaningful only at order-of-magnitude resolution. Use
`metadata.memory_measure` to disambiguate:

| Backend            | `metadata.memory_measure` | Meaning                                                              |
|--------------------|---------------------------|----------------------------------------------------------------------|
| `rust_pauliprop`   | `process_peak_rss`        | `/proc/self/status:VmHWM` — whole-process peak RSS in bytes, includes CPython, numpy, qiskit, pauli-prop initialisation. |
| `julia_pauliprop`  | (absent — `allocation_bytes` implicitly) | BenchmarkTools `median.memory` — allocation bytes attributed to the `propagate` call only. |

Future backends should set `metadata.memory_measure` explicitly so downstream
tooling can group like-for-like measurements.

## Expectation reduction

After Heisenberg propagation, `<0|O|0>` equals the sum of coefficients of
fully diagonal Pauli terms. A small embedded helper performs the numpy
reduction:

```python
def summarize(op):
    mask = ~op.paulis.x.any(axis=1)
    overlap = float(np.real(np.asarray(op.coeffs)[mask].sum()))
    return (overlap, int(op.size))
```

This matches `real(overlapwithzero(...))` in the Julia backend.

## Python environment

PyO3 with `auto-initialize` embeds CPython and links against `libpython` at
build time; the embedded interpreter looks up `pauli-prop` and `qiskit` at run
time. The bundled venv at `wrappers/rust/.venv` carries both:

```
pauli-prop==0.2.0       # pulls in qiskit, qiskit-aer, numpy, scipy, rustworkx
```

`make build-rust` creates the venv, installs the dependencies, sets
`PYO3_PYTHON` to the venv interpreter, and runs `cargo build --release`. The
binary auto-discovers the venv at run time (`wrappers/rust/.venv/lib/python*/
site-packages`); override with the env var `RUST_PAULIPROP_SITE_PACKAGES`.

System requirements:

- Python ≥ 3.10 with `libpython` (Debian/Ubuntu: `apt install python3-dev`).
- A Rust toolchain (1.74+).

## Reproducibility

- `Cargo.lock` is committed; `requirements.txt` pins `pauli-prop==0.2.0`.
- Versions actually used are recorded in every result's metadata
  (`pauli_prop_version`, `qiskit_version`).
- The numerical contract is fixed by `make test-rust`, which asserts
  `rust_pauliprop` matches `julia_pauliprop` on `bench_small` for both the
  truncated `expectation` and the exact `reference` (`atol = 1e-6`).

## Scope (Phase 1)

In scope: `bench_small` (`clifford_pauli_rotation`, n=4).
Out of scope: the 127-qubit Eagle / Rudolph tasks and `run_sweep`. The runner
parses any `pps-circuit-v1` circuit; cross-checking those workloads against
`julia_pauliprop` is left for follow-up issues.
