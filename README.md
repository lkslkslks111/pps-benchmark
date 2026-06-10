# PPS Backend Benchmark

Cross-language benchmark for **Pauli propagation** engines: the same Heisenberg-picture simulation task, the same circuit exchange format, the same result schema — run on Julia, Rust, C++, and CUDA backends and compared head-to-head on runtime, memory, throughput, and accuracy under different truncation strategies.

![Pauli term growth per gate across backends and truncation variants](docs/figures/truncation_types_growth.png)

*Per-gate Pauli term growth on a 10-qubit benchmark circuit. The Julia, C++, and CUDA engines produce **identical** term counts after every gate — the curves overlap exactly — which doubles as a cross-engine correctness check.*

## Why

Pauli propagation (sparse Heisenberg-picture simulation with truncation) has several independent implementations across language ecosystems. They differ in engine design, truncation knobs, and performance characteristics, but there has been no apples-to-apples comparison. This repository provides:

- a **single benchmark specification** (TOML) consumed by every backend,
- a versioned **circuit exchange format** (`pps-circuit-v1` JSON) so no backend rebuilds circuits from scratch,
- a **uniform result schema** with structured truncation records, peak term counts, and throughput,
- **comparison tooling** that turns raw results into tables and figures.

## Backends

| Backend | Language | Engine | Invocation |
|---|---|---|---|
| `julia_pauliprop` | Julia | [PauliPropagation.jl](https://github.com/MSRudolph/PauliPropagation.jl) | in-process |
| `rust_pauliprop` | Rust | [Qiskit pauli-prop](https://github.com/Qiskit/pauli-prop) | subprocess (embedded CPython) |
| `cpp_pauliengine` | C++ | [PauliEngine](https://github.com/tequilahub/pauliengine) (nanobind) | subprocess (bundled venv) |
| `cuda_cupauliprop` | CUDA | [cuPauliProp](https://docs.nvidia.com/cuda/cuquantum/latest/cupauliprop/overview.html) (cuQuantum) | subprocess (bundled venv) |

### Truncation support matrix

| Truncation | Julia | Rust | C++ | CUDA |
|---|:---:|:---:|:---:|:---:|
| `coefficient_threshold` — drop \|coeff\| < ε | ✓ | ✓ (`atol`) | ✓ | ✓ (`pauli_coeff_cutoff`) |
| `pauli_weight_cutoff` — drop weight > W | ✓ | — | ✓ | ✓ |
| `max_terms` — keep largest K terms | — | ✓ | — | — |
| `lowesa_surrogate` — Fourier `max_freq` + `max_weight` | ✓ | — | — | — |
| Combinations of the above | ✓ | ✓ | ✓ | ✓ |

Every result records the truncation actually applied as a structured `truncation_applied` object — no downstream guessing.

## Quick start

```bash
# Julia orchestration layer + Julia backend (no build needed)
make instantiate
make test          # full integration suite
make smoke         # 4-qubit single run, JSON result on stdout

# Optional backends
make build-rust  && make smoke-rust    # needs cargo
make build-cpp   && make smoke-cpp     # C++ pauliengine optional; falls back to Python
make build-cuda  && make smoke-cuda    # needs an NVIDIA GPU + cuquantum

# Cross-backend comparison on the 10-qubit medium task
make benchmark-medium
```

`benchmark-medium` runs every locally available backend on `configs/bench_medium.toml` and writes `results/comparison_medium.{md,png}`:

![Cross-backend comparison](docs/figures/comparison_medium.png)

## Benchmark dimensions

### Accuracy / speed vs truncation threshold

```bash
python3 scripts/sweep_truncation.py
```

![Accuracy and runtime vs truncation threshold](docs/figures/truncation_sweep.png)

### Truncation types and combinations per backend

```bash
python3 scripts/compare_truncation_types.py
```

![Truncation type matrix](docs/figures/truncation_types.png)

Findings from the 10-qubit task (coeff = 1e-7, weight ≤ 4, topK = 4096):

- **Weight truncation agrees exactly across engines**: Julia, C++, and CUDA produce identical final term counts (7494) and identical error (5.3e-2).
- **Top-K beats weight truncation per term**: Rust's `max_terms = 4096` reaches 1.5e-4 error, while weight ≤ 4 keeps 7494 terms at 5.3e-2 — selecting terms by coefficient magnitude is far more efficient than selecting by operator locality on this circuit.
- **Combining coeff + weight compresses 3.5x further** with no additional error (the weight cutoff dominates the error budget).
- **GPU runtime is flat in term count at this scale** (~0.45 s regardless of threshold): kernel-launch overhead dominates below ~10⁵ terms, so the CUDA backend pays off only at larger scales.
- **An interpreted propagation loop caps C++ gains**: swapping the Python fallback's arithmetic for the real C++ PauliEngine core cut runtime ~1.9x, but the per-gate loop still lives in Python — Julia and Rust win because their entire loop is compiled.

### 127-qubit LOWESA reproduction

The `lowesa_tfi_127_L5_*.toml` configs reproduce the 158-angle magnetization sweep of Rudolph et al. 2023 (Fig. 2a) on the IBM Eagle topology, validated against the IBM utility-paper exact curve (RMSE ≈ 4e-3). See [docs/lowesa_tfi_127_benchmark.md](docs/lowesa_tfi_127_benchmark.md).

```bash
make benchmark-lowesa-127        # Julia surrogate sweep
make benchmark-lowesa-127-all    # all backends (GPU/HPC recommended)
```

## Result schema

Every backend emits one JSON object per run:

```jsonc
{
  "backend": "julia_pauliprop",
  "task_id": "medium_clifford_rotation_n10_l8_seed7",
  "success": true,
  "runtime_sec": 0.052,
  "memory_bytes": 2048000,
  "final_terms": 16083,
  "peak_terms": 17146,                  // max term count during propagation
  "throughput_terms_per_sec": 3.1e5,
  "expectation": 0.1184,
  "reference": 0.1184,                  // exact (untruncated) value when tractable
  "absolute_error": 1.2e-6,
  "metadata": {
    "truncation_applied": { "method": "threshold", "coefficient_threshold": 1e-7, /* ... */ },
    "terms_history": [1, 2, 2, ...],    // per-gate term counts (single runs)
    "memory_measure": "process_peak_rss",
    "thread_limits": { "OMP_NUM_THREADS": "1", /* ... */ }
  }
}
```

All benchmarks are pinned to a **single core** (thread-pool environment variables are forced to 1 and recorded) so cross-language runtimes are comparable.

## Repository layout

```
configs/      benchmark specifications (TOML)
src/          Julia orchestration layer + backend wrappers
benchmarks/   executable entry points (run_backend.jl, run_sweep.jl)
wrappers/     Rust / C++ / CUDA / Python runner implementations
scripts/      comparison + validation tooling (Python)
docs/         per-backend notes, exchange-format spec, figures
results/      generated outputs (not tracked)
```

Per-backend documentation: [Rust](docs/rust_pauliprop_backend.md) · [C++](docs/cpp_pauliengine_backend.md) · [CUDA](docs/cuda_cupauliprop_backend.md) · [circuit exchange format](docs/circuit_exchange_schema.md)

## Reproducibility

- Deterministic seeds in every config; parameter rules documented in result metadata.
- Engine versions, thread limits, and memory measurement method recorded per run.
- `memory_bytes` semantics differ by backend (Julia: allocation bytes; others: peak RSS) and are labeled via `metadata.memory_measure` — compare within a backend, not across.
