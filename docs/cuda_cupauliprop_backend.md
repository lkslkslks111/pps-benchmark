# `cuda_cupauliprop` backend — architecture and protocol

## Overview

The `cuda_cupauliprop` backend benchmarks Heisenberg-picture Pauli propagation
using NVIDIA's **cuPauliProp** library, which is part of the
[cuQuantum SDK](https://docs.nvidia.com/cuda/cuquantum/latest/cupauliprop/index.html).
cuPauliProp accelerates sparse Pauli-string arithmetic on NVIDIA GPUs.

Architecture:

```
Julia orchestration (PPSBackendBench.jl)
    └── CudaCuPauliPropBackend (src/backends/cuda_cupauliprop.jl)
            └── subprocess: python3 wrappers/cuda/cupauliprop_runner.py
                    └── cuquantum.pauliprop.experimental (GPU)
```

## cuQuantum / cuPauliProp description

[cuPauliProp](https://docs.nvidia.com/cuda/cuquantum/latest/cupauliprop/index.html)
is an NVIDIA library for GPU-accelerated Pauli propagation. It provides:

- `PauliExpansion` — sparse container of weighted Pauli strings
- `PauliRotationGate` — applies `exp(-i * theta/2 * P)` in the Heisenberg picture
- `Truncation` — controls term growth by discarding small-coefficient terms
- `LibraryHandle` — manages GPU device context and memory

The Python API lives under `cuquantum.pauliprop.experimental` (as of cuQuantum
25.x). It is installed via the `cuquantum-cu12` PyPI package (CUDA 12.x).

## Subprocess contract

**Invocation:**

```bash
python3 wrappers/cuda/cupauliprop_runner.py \
    --circuit <pps-circuit-v1.json> \
    --samples <n>
```

**Success (exit 0):** one JSON line on stdout matching `BenchmarkResult`.

**Failure (exit 1):** human-readable diagnostic on stderr, nothing on stdout.

If `cuquantum` is not installed or no CUDA device is available, the runner
exits 1 immediately with an `ERROR: cuquantum not available: ...` message on
stderr.

## Pauli string format

cuPauliProp uses strings of length `nqubits` where character index `i`
represents qubit `i` (0-indexed, left-to-right):

```
"XIZIIIII"  →  X on qubit 0, I on qubit 1, Z on qubit 2, I on qubits 3-7
```

The pps-circuit-v1 format stores `gate.qubits` as 0-indexed integers and
`gate.paulis` as matching single-character strings. The conversion is:

```python
def gate_to_pauli_string(gate, nqubits):
    pauli_arr = ['I'] * nqubits
    for qubit, op in zip(gate['qubits'], gate['paulis']):
        pauli_arr[qubit] = op
    return ''.join(pauli_arr)
```

## Observable to expansion conversion

The runner converts the circuit's `observable` string to a list of
`(coeff, pauli_str)` pairs for the initial `PauliExpansion`:

| Observable | Expansion |
|---|---|
| `"Z0"` | `[(1.0, "ZII...I")]` |
| `"Z62"` | `[(1.0, "II...ZII...I")]` (Z at index 62) |
| `"X5"` | `[(1.0, "IIIIIXII...I")]` (X at index 5) |
| `"Mz"` or `"magnetization"` | `[(1/n, string_with_Z_at_i) for i in 0..n-1]` |

## Propagation loop (Heisenberg picture)

Gates are applied in **reverse** order (Heisenberg picture):

```python
for gate in reversed(circuit['gates']):
    pauli_str = gate_to_pauli_string(gate, nqubits)
    rot_gate = PauliRotationGate(pauli_str, gate['theta'])
    expansion = rot_gate.apply(expansion, truncation=truncation)
```

This is equivalent to computing `U† O U` by left-multiplying each gate's
adjoint onto the observable.

## Expectation extraction

`<0...0|O|0...0>` is extracted from the `PauliExpansion` by summing all terms
whose Pauli string contains only `I` and `Z`:

```
<0|I|0> = 1,  <0|Z|0> = 1,  <0|X|0> = 0,  <0|Y|0> = 0
```

Terms with any `X` or `Y` character contribute zero and are skipped.

## Reference value

The runner performs two propagation runs per circuit:

1. **Reference run** with `threshold=0.0` (exact, no truncation) to obtain the
   ground-truth expectation value.
2. **N timed samples** with the circuit's configured truncation threshold.

`absolute_error = |expectation - reference|`.

## Memory accounting

Peak RSS is measured after all timed runs complete:

```python
resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024  # Linux: kB → bytes
```

## Thread limits

The runner enforces single-core CPU execution:

```python
os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
os.environ.setdefault("MKL_NUM_THREADS", "1")
```

GPU parallelism is not restricted; cuPauliProp uses the full GPU.

## GPU requirements

- NVIDIA GPU with compute capability 7.0+ (Volta or later) recommended
- CUDA 12.x toolkit
- `cuquantum-cu12` Python package

If no GPU is present, the runner exits 1 at import time with:
```
ERROR: cuquantum not available: <ImportError details>
```

## Build

```bash
make build-cuda   # creates wrappers/cuda/.venv and installs cuquantum-cu12
make smoke-cuda   # runs bench_small via cuda_cupauliprop
make test-cuda    # numerical comparison against julia_pauliprop
```
