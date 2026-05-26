# Python Backend Wrappers

This directory contains Python subprocess runners for the PPS benchmark. Each runner reads
a circuit JSON file (schema `pps-circuit-v1`), performs Pauli propagation in the Heisenberg
picture, and writes a 10-field result JSON to stdout.

## Subprocess contract

**Input**
```
python3 <runner>.py --circuit <path/to/circuit.json> [--samples <n>]
```

| Argument    | Description                                                  | Default |
|-------------|--------------------------------------------------------------|---------|
| `--circuit` | Path to the circuit JSON (required)                          | —       |
| `--samples` | Number of propagation runs; median runtime is reported       | 1       |

**Success** — exit 0, exactly one JSON line on stdout with the 10 required fields:
`backend`, `task_id`, `success`, `runtime_sec`, `memory_bytes`, `final_terms`,
`expectation`, `reference`, `absolute_error`, `metadata`.

**Failure** — diagnostic printed to stderr, exit 1.

---

## bluequbit_runner.py

Calls the [BlueQubit](https://bluequbit.io) cloud pauli-path simulator.

### Requirements

```
pip install -r requirements_bluequbit.txt
```

An API token is required and must be supplied as an environment variable:

```bash
export BLUEQUBIT_API_TOKEN="<your-token>"
```

Install into the managed venv:
```bash
make build-bluequbit
```

### Usage

```bash
python3 wrappers/python/bluequbit_runner.py --circuit <circuit.json> [--samples <n>]
```

### How it works

1. Reads a `pps-circuit-v1` JSON file.
2. Builds a Qiskit `QuantumCircuit` from the gate list.
3. Converts the observable string (`Z0`, `Z62`, `Mz`) to a BlueQubit
   `pauli_sum` list of `(pauli_string, coefficient)` tuples.
4. Calls `bq_client.run(qc, device="pauli-path", pauli_sum=..., ...)`.
5. Runs a second call with `pauli_path_truncation_threshold=0.0` for the
   reference (exact) value.
6. Prints a single JSON line on stdout conforming to the BenchmarkResult schema.

### Qiskit qubit ordering

Qiskit Pauli strings use reversed qubit order — qubit 0 is the rightmost
character. The runner handles this conversion internally when building both
the circuit gates and the `pauli_sum` observable strings.

### Output schema notes

| Field | Value |
|---|---|
| `backend` | `"python_bluequbit"` |
| `final_terms` | `-1` (not exposed by the BlueQubit API) |
| `memory_measure` | `"process_peak_rss"` |
| `device` | `"pauli-path"` |

### Notes

- Requires a live BlueQubit API token.
- The runner exits with an error if `BLUEQUBIT_API_TOKEN` is not set.
- All computation is performed on BlueQubit servers; no local GPU is required.

### Makefile targets

```bash
make build-bluequbit    # create venv and install dependencies
make smoke-bluequbit    # run a small end-to-end benchmark
make test-bluequbit     # run Julia integration tests (requires API token)
```

---

## cuquantum_runner.py

Pauli propagation via the [cuQuantum Python high-level API](https://docs.nvidia.com/cuda/cuquantum/latest/python/pauliprop.html):
`cuquantum.pauliprop.experimental`.

This runner uses the **high-level Pythonic API** (the `experimental` module), which provides
`PauliExpansion`, `PauliRotationGate`, `LibraryHandle`, and `Truncation`.  It is distinct from
the low-level C-binding CUDA backend (`cuquantum.bindings.cupauliprop`) used by the
`cuda_cupauliprop` backend.

### Requirements

```
pip install -r requirements_cuquantum.txt
```

`requirements_cuquantum.txt` installs `cuquantum-cu12` (CUDA 12 build).  Substitute
`cuquantum-cu11` for CUDA 11 environments.

A **CUDA-capable GPU** and a compatible CUDA toolkit are required for the cuQuantum library to
initialise at runtime.

### Installation

```bash
# With CUDA 12:
pip install -r requirements_cuquantum.txt

# Or manually:
pip install cuquantum-cu12
```

### Usage example

```bash
python3 wrappers/python/cuquantum_runner.py \
    --circuit /tmp/circuit.json \
    --samples 3
```

### Pauli string convention

The cuQuantum API uses Pauli strings of length `nqubits` where position `i` corresponds
to qubit `i` (0-indexed).  Example: qubit 2 carries Z in an 8-qubit system →
`"IIZIIIII"`.

### Observable parsing

| Observable string        | Expansion                                        |
|--------------------------|--------------------------------------------------|
| `"Z0"`, `"X5"`, `"Z62"` | Single term: coefficient 1.0, Pauli on qubit idx |
| `"Mz"`, `"magnetization"` | 1/N * Σ_i Z_i (uniform Z magnetisation)         |

### Expectation extraction

⟨0|P|0⟩ = 1 when every factor of P is I or Z; 0 when any factor is X or Y.
The runner accumulates contributions only from purely I/Z terms.

### Memory accounting

Peak RSS is read from `resource.getrusage(resource.RUSAGE_SELF).ru_maxrss` and
converted to bytes (Linux reports in kB).

### Thread limits

`OMP_NUM_THREADS=1` and `OPENBLAS_NUM_THREADS=1` are set before importing cuQuantum
to enforce single-core operation consistent with the benchmark policy.
