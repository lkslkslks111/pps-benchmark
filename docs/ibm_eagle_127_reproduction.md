# IBM Eagle 127-Qubit Reproduction Scaffold

Issue #3 adds a first 127-qubit workload for the IBM Eagle kicked transverse-field Ising benchmark discussed in IBM's 2023 utility paper:

- IBM paper page: https://research.ibm.com/publications/evidence-for-the-utility-of-quantum-computing-before-fault-tolerance
- IBM/Qiskit overview: https://qiskit.qotlabs.org/learning/courses/quantum-computing-in-practice/simulating-nature
- Sparse Pauli dynamics note: https://arxiv.org/abs/2306.16372
- Converged classical simulations: https://arxiv.org/abs/2308.05077
- SPD reference code: https://github.com/tbegusic/spd

## Benchmark Scope

`configs/bench_eagle_127.toml` is intentionally a smoke benchmark, not a full paper reproduction. It uses:

- `family = "ibm_eagle_tfi"`
- `nqubits = 127`
- `nlayers = 1`
- PauliPropagation.jl's built-in `ibmeagletopology`
- PauliPropagation.jl's `tfitrottercircuit`
- observable `Z0`

The generated `pps-circuit-v1` gate list contains one TFI Trotter layer on the Eagle heavy-hex topology: 144 `ZZ` rotations and 127 `X` rotations. Parameters are deterministic and documented in the circuit metadata: `ZZ` rotations use `pi/4`, and `X` rotations use `pi/8`.

## Limitations

This benchmark does not reproduce IBM's hardware noise, probabilistic error amplification, zero-noise extrapolation, or the full 60-step multi-parameter magnetization sweep. It is a Julia-only classical simulation scaffold that proves this repository can generate, exchange, and run a 127-qubit Eagle-style Pauli propagation workload through the same result schema used by smaller benchmarks.

Future issues can extend this scaffold with observable aggregation for total magnetization, deeper Trotter steps, parameter sweeps, and comparisons against published SPD or tensor-network reference data.
