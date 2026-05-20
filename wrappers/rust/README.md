# `rust_pauliprop` — Rust / Qiskit pauli-prop benchmark backend

A Rust binary that drives [`Qiskit/pauli-prop`](https://github.com/Qiskit/pauli-prop)
via PyO3 to benchmark Heisenberg-picture Pauli propagation with coefficient-threshold
truncation. It is the third backend in the `pps-benchmark` lineup.

The protocol, gate mapping, and reproducibility notes live in
[`../../docs/rust_pauliprop_backend.md`](../../docs/rust_pauliprop_backend.md).

## Layout

```
wrappers/rust/
├── Cargo.toml              # cargo package
├── Cargo.lock              # committed for reproducibility
├── requirements.txt        # pinned Python deps (pauli-prop pulls in qiskit)
├── README.md               # this file
└── src/
    ├── lib.rs              # pure-logic core (no Python)
    ├── circuit.rs          # pps-circuit-v1 parsing + validation + observable parsing
    ├── gatemap.rs          # gate classification (single / double / general Pauli rotation)
    ├── result.rs           # BenchmarkResult schema (matches Julia)
    ├── main.rs             # binary entry point (`rust_pauliprop_runner`)
    └── propagate.rs        # PyO3 layer: SparsePauliOp, QuantumCircuit, propagate_through_circuit
```

## Build

PyO3 embeds CPython and needs an interpreter with `pauli-prop` available at both
build and run time. Use the bundled venv:

```bash
# From the repo root:
make build-rust
```

That target creates `wrappers/rust/.venv`, `pip install -r requirements.txt`,
and runs `cargo build --release` with `PYO3_PYTHON` pointed at the venv.

## Run

```bash
./wrappers/rust/target/release/rust_pauliprop_runner \
    --circuit <pps-circuit-v1.json> [--samples 5]
```

On success it prints one JSON line matching the `BenchmarkResult` schema. On
failure it writes a message to stderr and exits with code 1.

The binary locates the bundled venv automatically by walking up from
`std::env::current_exe()` to `wrappers/rust/.venv/lib/python*/site-packages`.
Override with `RUST_PAULIPROP_SITE_PACKAGES=<absolute path>`.

## Tests

Pure-logic unit tests (no Python required):

```bash
cargo test --manifest-path wrappers/rust/Cargo.toml --no-default-features --lib
```

Full numerical comparison against `julia_pauliprop` on `bench_small`:

```bash
make test-rust
```
