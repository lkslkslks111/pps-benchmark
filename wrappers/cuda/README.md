# `cuda_cupauliprop` — CUDA / cuPauliProp benchmark backend

A Python subprocess runner that drives NVIDIA's
[cuPauliProp](https://docs.nvidia.com/cuda/cuquantum/latest/cupauliprop/index.html)
(part of cuQuantum) to benchmark Heisenberg-picture Pauli propagation with
coefficient-threshold truncation on NVIDIA GPUs.

The protocol, gate mapping, and reproducibility notes live in
[`../../docs/cuda_cupauliprop_backend.md`](../../docs/cuda_cupauliprop_backend.md).

## Requirements

- NVIDIA GPU with CUDA 12.x support
- CUDA Toolkit 12.x installed and on `PATH` / `LD_LIBRARY_PATH`
- Python 3.9+ with `cuquantum-cu12` installed

## Layout

```
wrappers/cuda/
├── cupauliprop_runner.py   # subprocess runner
├── requirements.txt        # Python dependency: cuquantum-cu12
└── README.md               # this file
```

## Installation

```bash
# From repo root:
make build-cuda
```

This creates `wrappers/cuda/.venv`, upgrades pip, and installs
`cuquantum-cu12` from PyPI.

Or manually:

```bash
python3 -m venv wrappers/cuda/.venv
wrappers/cuda/.venv/bin/pip install -r wrappers/cuda/requirements.txt
```

## Subprocess contract

**Input:**

```bash
python3 wrappers/cuda/cupauliprop_runner.py \
    --circuit <pps-circuit-v1.json> \
    --samples <n>
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--circuit` | path | required | pps-circuit-v1 JSON file |
| `--samples` | int | 1 | number of timed propagation runs; median is reported |

**Success (exit 0):** one JSON line on stdout matching the `BenchmarkResult`
schema.

**Failure (exit 1):** diagnostic message on stderr, nothing on stdout.

If `cuquantum` is not installed or no GPU is available, the runner exits with
code 1 and a human-readable error on stderr so the Julia caller can surface a
clean `ErrorException`.

## BenchmarkResult schema

```json
{
  "backend":            "cuda_cupauliprop",
  "task_id":            "<from circuit>",
  "success":            true,
  "runtime_sec":        <median timed propagation>,
  "memory_bytes":       <process peak RSS in bytes>,
  "final_terms":        <number of terms after truncated propagation>,
  "expectation":        <float>,
  "reference":          <float, threshold=0 run>,
  "absolute_error":     <|expectation - reference|>,
  "metadata": {
    "engine":                  "cupauliprop",
    "cuquantum_version":       "<version string>",
    "truncation_threshold":    <float>,
    "circuit_schema_version":  "pps-circuit-v1",
    "nqubits":                 <int>,
    "circuit_size":            <int>,
    "observable":              "<str>",
    "family":                  "<str>",
    "median_time_sec":         <float>,
    "memory_measure":          "process_peak_rss",
    "thread_limits":           {"OMP_NUM_THREADS": "1"}
  }
}
```

## Pauli string format

cuPauliProp uses strings of length `nqubits` where character index `i`
represents qubit `i`. For example, `"XIZIIIII"` means X on qubit 0, I on
qubit 1, Z on qubit 2, I on qubits 3-7.

## Observable to expansion conversion

| Observable string | Expansion |
|---|---|
| `"Z0"` | `[(1.0, "ZII...I")]` |
| `"Z62"` | `[(1.0, "II...ZI...I")]` (Z at position 62) |
| `"X5"` | `[(1.0, "II...XI...I")]` (X at position 5) |
| `"Mz"` / `"magnetization"` | `[(1/n, pauli_i) for i in 0..n-1]` where `pauli_i` has Z at position i |

## Expectation extraction

`<0...0|O|0...0>` is computed by summing over all terms in the `PauliExpansion`
where every qubit site carries I or Z (since `<0|X|0> = <0|Y|0> = 0`,
`<0|I|0> = <0|Z|0> = 1`). The coefficient of each such term is added directly.

## Memory accounting

Peak RSS is read from `resource.getrusage(resource.RUSAGE_SELF).ru_maxrss`
after all timed runs complete. On Linux, `ru_maxrss` is in kibibytes; the
runner multiplies by 1024 to produce bytes.

## Thread limits

The runner sets `OMP_NUM_THREADS=1`, `OPENBLAS_NUM_THREADS=1`, and
`MKL_NUM_THREADS=1` at startup so all backends are benchmarked single-core
on the CPU side. GPU parallelism is controlled by cuQuantum internally.
