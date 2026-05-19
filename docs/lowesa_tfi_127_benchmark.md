# LOWESA 127-qubit TFI benchmark (L=5 homogeneous-field magnetization sweep)

The first formal 127-qubit Pauli-propagation benchmark in this repository. It
reproduces Fig. 2a of Rudolph et al. 2023, *Classical Surrogate Simulation of
Quantum Systems with LOWESA* ([arXiv:2308.09109](https://arxiv.org/abs/2308.09109)),
and is intended as the **main benchmark**: difficulty is moderate enough that every
backend (Julia now, Phase 2+ backends later) can run it to completion, while it still
exercises the genuine LOWESA build-once / evaluate-many model.

## Physical setup

- 127-qubit transverse-field Ising model on the IBM heavy-hex topology
  (`ibmeagletopology`, 144 edges).
- Trotterised into **L = 5** layers. Each layer is a layer of `RX` rotations on all
  127 qubits followed by `RZZ` rotations on all 144 edges.
- Couplings fixed at `J(i,j) = -π/2`, so every `RZZ` is a Clifford gate.
- Homogeneous local field, swept in unison (correlated angle):
  every `RX` carries the same `θ_h`, swept over `[0, π/2]`.
- **158** values of `θ_h` per curve — the grid published with the IBM utility paper.

Circuit size: `5 × (127 RX + 144 RZZ) = 1355` gates, 1355 parameters.

## Observables

- `Mz = (1/127) Σ_i ⟨Z_i⟩` — average magnetization (`observable = "Mz"`).
- `⟨Z_62⟩` — single-site magnetization, 0-based qubit index (`observable = "Z62"`).

## Method

Implemented with the `Surrogate` submodule of PauliPropagation.jl — the LOWESA
implementation by the paper's author. The pipeline (`run_surrogate_sweep` in
`src/backends/julia_pauliprop.jl`):

1. Wrap the observable into surrogate `NodePathProperties` coefficients (see the
   127-qubit note below).
2. **Build** the surrogate path graph once:
   `propagate(circuit, wrapped; max_freq = ℓ, max_weight = W)`.
3. `zerofilter!` the surrogate (drop X/Y strings — zero overlap with `|0…0⟩`).
4. **Evaluate** at every `θ_h`: `evaluate!(surrogate, thetas)` then
   `overlapwithzero`. The `thetas` vector carries `θ_h` in every `RX` slot and
   `-π/2` in every `RZZ` slot.

### 127-qubit note on `wrapcoefficients`

PauliPropagation's `wrapcoefficients(_, NodePathProperties)` stores each observable
Pauli string in `EvalEndNode.pstr::Int`, which overflows for strings beyond ~31
qubits (a 127-qubit string needs `UInt256`). That `pstr` field is used only for
pretty-printing and never read during `evaluate!`, so `run_surrogate_sweep` wraps the
observable manually (`_wrap_surrogate_observable`) with a dummy `pstr = 0` label while
the real `UInt256` Pauli keys stay on the `PauliSum`. The surrogate propagation and
evaluation are otherwise unmodified and qubit-count agnostic.

Truncation (paper panel a): frequency `ℓ = 40`, operator weight `W = 8`. The
probability truncation `p` from the paper's panel b is **not** exposed by the
surrogate submodule and is out of scope here.

> The `Surrogate` submodule is flagged experimental in PauliPropagation.jl. It is
> the only API that exposes a build/evaluate split, so `PauliPropagation` is pinned
> at `0.7.3` in `Manifest.toml`.

The circuit is built from plain parameterised `PauliRotation` gates (not
`FrozenGate`s) because the surrogate accepts only `CliffordGate`s and
`PauliRotation`s; the `RZZ` angle `-π/2` is supplied at evaluation time.

## Reference data (RMSE ground truth)

Exact classical reference curves come from the data published with the IBM utility
paper (Kim et al., *Evidence for the utility of quantum computing before fault
tolerance*, Nature 618, 500-505, 2023), under `reference/Evidence-…-mainfig/`:

- `Mz`     ← `avg_Sz` in `exactMagnetization_steps5_qubits127_reducedTrue_HFalse.pkl`
- `⟨Z_62⟩` ← `Szs[:, 62]` in the same pickle

`scripts/extract_ibm_reference.py` (a dev-only one-off, not run by `make`) extracts
these into the committed plain-text curves the Julia benchmark reads:

- `reference/ibm_utility_L5_Mz.txt`
- `reference/ibm_utility_L5_Z62.txt`

Each file has 158 `theta value` lines. The benchmark takes its `θ_h` grid directly
from these files so the RMSE comparison is point-to-point.

## Recorded metrics

Per-sweep metrics live in `BenchmarkSweepResult.metadata`:

| metric | metadata key | meaning |
|---|---|---|
| `build_time` | `build_time_sec` | wall time to construct the surrogate path graph |
| `eval_time_158` | `eval_time_sec` | wall time to evaluate every swept `θ_h` (158 for the full run; see `evaluated_angle_count`) |
| `num_paths_found` | `num_paths_found` | distinct nodes in the surrogate graph (`PauliRotationNode` + `EvalEndNode`), de-duplicated traversal from every surviving operator |
| `num_paths_kept` | `num_paths_kept` | surviving Pauli operators in the surrogate (`length(surrogate.terms)`) |
| `peak_RSS` | `peak_rss_bytes` | peak process resident memory (`Sys.maxrss()`) |
| `RMSE` | `rmse` | `sqrt(mean(absolute_error²))` over the evaluated points |

Per-`θ_h` data lives in each `BenchmarkSweepPoint`: `expectation` is `f̂(θ_h)`,
`reference` is the IBM exact value, `absolute_error` is `|f̂ − reference|`.

### Note on path counting

PauliPropagation merges paths into a shared graph and applies `max_weight` /
`max_freq` truncation *before* any user callback, so a true "candidate paths before
truncation" count is not recoverable. `num_paths_found` is therefore defined as the
size of the *kept* surrogate graph (all nodes), and `num_paths_kept` as the number of
surviving Pauli operators. Both are exact and reproducible; `num_paths_kept ≤
num_paths_found` always holds.

## Running

```bash
make test                 # includes a reduced surrogate sweep (ℓ=6, W=4, 3 points)
make benchmark-lowesa-127  # full 158-point run for Mz and Z62, JSON to stdout
```

Or directly:

```bash
julia --project=. benchmarks/run_sweep.jl --backend julia_pauliprop \
  --config configs/lowesa_tfi_127_L5_mz.toml
```

The paper reports near-exact agreement for panel a at `ℓ=40, W=8`; expect a small
`rmse`. At `θ_h = 0` the circuit is fully Clifford, so `f̂(0) = 1.0` exactly for both
observables — a quick correctness check.

## Scope

Phase 1: Julia / PauliPropagation.jl backend only. The benchmark spec
(`configs/lowesa_tfi_127_L5_*.toml`) and the result schema are language-neutral so
future backends can implement the same task. Out of scope: the panel-b high-weight
observable and probability truncation `p`, the L=6 panel d, and other backends.
