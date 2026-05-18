# Circuit Exchange Schema

Issue #2 defines `pps-circuit-v1`, a JSON format for passing explicit benchmark circuits from the Julia orchestration layer to backend runners. Backends must consume the gate list in this file instead of rebuilding circuits from `family`, `nqubits`, `nlayers`, and `seed`.

## Top-Level Object

```json
{
  "schema_version": "pps-circuit-v1",
  "task_id": "small_clifford_rotation_n4_l4_seed1",
  "family": "clifford_pauli_rotation",
  "seed": 1,
  "nqubits": 4,
  "observable": "Z0",
  "truncation": {
    "method": "threshold",
    "threshold": 1.0e-8
  },
  "reference": {
    "enabled": true,
    "method": "exact_small"
  },
  "gates": [
    {
      "type": "pauli_rotation",
      "paulis": ["X"],
      "qubits": [0],
      "theta": 0.9092974268256817
    }
  ],
  "metadata": {
    "name": "bench_small",
    "config_path": "configs/bench_small.toml",
    "nlayers": 4
  }
}
```

Required fields:

- `schema_version`: must be `pps-circuit-v1`.
- `task_id`, `family`, `seed`, `nqubits`, `observable`: copied from the benchmark task context.
- `truncation`, `reference`: copied from the benchmark specification.
- `gates`: ordered list of gates to execute.
- `metadata`: auxiliary information for traceability. Backends must not require metadata to reconstruct the circuit.

## Gate Object

Only Pauli rotations are supported in Phase 1:

- `type`: must be `pauli_rotation`.
- `paulis`: array of Pauli symbols, each one of `I`, `X`, `Y`, or `Z`.
- `qubits`: array of 0-based qubit indices. The length must match `paulis`.
- `theta`: numeric rotation parameter value.

The exchange format always uses 0-based qubit indices. Julia PauliPropagation helpers convert these to 1-based indices when constructing `PauliRotation` objects.

## Phase 1 Semantics

For `family = "clifford_pauli_rotation"`, Julia exports the current `hardwareefficientcircuit(nqubits, nlayers)` gate order and deterministic parameters:

```julia
theta_i = sin(seed + i)
```

where `i` is 1-based in Julia parameter order. After export, backend smoke runs must use the explicit `gates` list and must not rebuild the circuit internally from the compact task spec.

For `family = "ibm_eagle_tfi"`, Julia exports a 127-qubit transverse-field Ising smoke circuit using PauliPropagation.jl's `ibmeagletopology` and `tfitrottercircuit`. This family is a scaffold for the IBM Eagle utility-scale kicked Ising workload, not a full reproduction of hardware noise mitigation or the original multi-parameter sweep. Its deterministic parameters are:

```julia
theta_ZZ = pi / 4
theta_X = pi / 8
```
