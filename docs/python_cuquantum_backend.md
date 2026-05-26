# Python / cuQuantum Python Backend

## Architecture overview

The `python_cuquantum` backend follows the same subprocess pattern as all external backends
in this repository:

```
Julia orchestrator
  └── run_backend(PythonCuQuantumBackend, spec)
        ├── export_circuit(spec) → CircuitDescription
        ├── write_circuit_description(tmp.json, description)
        ├── spawn: python3 wrappers/python/cuquantum_runner.py --circuit tmp.json --samples N
        ├── wait for exit 0
        └── parse stdout JSON → BenchmarkResult
```

The Julia side (`src/backends/python_cuquantum.jl`) handles:
- Exporting the circuit to a temp JSON file
- Spawning the Python subprocess
- Parsing the 10-field result JSON

The Python side (`wrappers/python/cuquantum_runner.py`) handles:
- Loading the circuit JSON
- Converting circuit gates to cuQuantum Pauli strings
- Running Heisenberg-picture propagation
- Computing the expectation value in |0...0⟩
- Writing the result JSON to stdout

## cuQuantum Python high-level API

This backend uses the **high-level Pythonic API** exposed by
`cuquantum.pauliprop.experimental`, which provides:

| Symbol             | Role                                                          |
|--------------------|---------------------------------------------------------------|
| `LibraryHandle`    | Resource manager (initialises the cuQuantum library)         |
| `PauliExpansion`   | Container for a sum of weighted Pauli strings                 |
| `PauliRotationGate`| Represents exp(−i θ/2 P); applied via `.apply(expansion)`   |
| `Truncation`       | Threshold-based pruning of small-coefficient terms           |

### Distinction from the low-level CUDA backend

The `cuda_cupauliprop` backend (planned) will use
`cuquantum.bindings.cupauliprop` — the low-level C FFI bindings.  The
`python_cuquantum` backend uses the `experimental` high-level module, which is
fully Pythonic and does not require manual memory management.

## Subprocess contract

```
python3 wrappers/python/cuquantum_runner.py --circuit <path> [--samples <n>]
```

| Argument    | Required | Description                                              |
|-------------|----------|----------------------------------------------------------|
| `--circuit` | yes      | Path to the circuit JSON file (`pps-circuit-v1` schema) |
| `--samples` | no       | Propagation runs for median timing (default 1)           |

**Success**: exit 0, one JSON line on stdout with all 10 required fields.
**Failure**: diagnostic to stderr, exit 1.

## Pauli string indexing convention

cuQuantum uses a plain Python string of length `nqubits` where **position `i`
corresponds to qubit `i`** (0-indexed, same as the circuit JSON schema).

Example: Z on qubit 2 in an 8-qubit system → `"IIZIIIII"`.

Gate-to-string conversion:

```python
def gate_to_pauli_string(gate, nqubits):
    arr = ['I'] * nqubits
    for qubit, op in zip(gate['qubits'], gate['paulis']):
        arr[qubit] = op
    return ''.join(arr)
```

## Observable parsing

| Observable string         | Expansion                                               |
|---------------------------|---------------------------------------------------------|
| `"Z0"`, `"X5"`, `"Z62"` | One term: coefficient 1.0, Pauli char at qubit index   |
| `"Mz"`, `"magnetization"` | N terms: (1/N, Z_i) for each qubit i                  |

## Expectation value extraction

The expectation ⟨0|P|0⟩ in the all-zeros computational basis state equals:

- **1** if every single-qubit factor P_i is I or Z
- **0** if any factor is X or Y

The runner accumulates:

```python
total = sum(coeff for (pauli_str, coeff) in expansion
            if all(c in ('I', 'Z') for c in pauli_str))
```

## Truncation and reference value

The truncation threshold is read from the circuit JSON (`truncation.threshold`).
If `threshold > 0`, a `Truncation(threshold=threshold)` object is passed to each
`PauliRotationGate.apply()` call, pruning terms with coefficient magnitude below
the threshold.

The **reference** value is computed by a second propagation with `threshold=0.0`
(no truncation).  If the main run already uses `threshold=0.0`, the reference is
the same as the expectation (no second pass).

## Memory accounting

Peak RSS is read via:

```python
resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024
```

Linux reports RSS in kilobytes; multiplying by 1024 gives bytes.  The field is
labelled `"memory_measure": "process_peak_rss"` in the metadata.

## Thread limits

`OMP_NUM_THREADS=1` and `OPENBLAS_NUM_THREADS=1` are set at module import time
via `os.environ.setdefault(...)` to enforce single-core operation consistent with
the single-core benchmark policy documented in
[single-core-benchmark-policy.md](../memory/single-core-benchmark-policy.md).

## Build and smoke-test

```bash
# Install cuquantum into a venv
make build-cuquantum

# Run the small benchmark
make smoke-cuquantum

# Run the full comparison test suite (requires cuquantum + GPU)
make test-cuquantum
```

If cuquantum is not installed or no GPU is available, `make smoke-cuquantum` will
fail with a clear error message from the Python runner.

## Installation

```bash
# CUDA 12
pip install cuquantum-cu12

# CUDA 11
pip install cuquantum-cu11
```

A CUDA-capable GPU and a compatible CUDA toolkit are required at runtime.
