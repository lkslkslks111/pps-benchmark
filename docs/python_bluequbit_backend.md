# Python / BlueQubit Backend

## Architecture

The BlueQubit backend follows the same subprocess pattern as `rust_pauliprop`:

1. The Julia wrapper (`src/backends/python_bluequbit.jl`) exports the circuit
   to a temporary JSON file (`pps-circuit-v1` schema).
2. It spawns `python3 wrappers/python/bluequbit_runner.py --circuit <path> --samples <n>`.
3. The Python runner calls the BlueQubit cloud API and prints a single JSON
   line on stdout conforming to the `BenchmarkResult` schema.
4. The Julia wrapper parses that JSON and constructs a `BenchmarkResult`.

## BlueQubit SDK

BlueQubit provides a cloud quantum simulation service. The `pauli-path` device
implements truncated Pauli-path simulation — the same algorithm as
PauliPropagation.jl — but executed on BlueQubit's infrastructure.

Install the SDK:
```bash
pip install bluequbit qiskit
```

Or use the managed venv:
```bash
make build-bluequbit
```

## API Token

The runner reads the API token from the `BLUEQUBIT_API_TOKEN` environment
variable. If the variable is not set the runner exits with code 1 and prints
a diagnostic to stderr. Obtain a token at <https://app.bluequbit.io>.

```bash
export BLUEQUBIT_API_TOKEN=<your-token>
make smoke-bluequbit
```

## Subprocess Contract

| | |
|---|---|
| **Command** | `python3 wrappers/python/bluequbit_runner.py --circuit <path> [--samples <n>]` |
| **stdin** | not used |
| **stdout on success** | one JSON line, `BenchmarkResult` schema |
| **stdout on failure** | empty |
| **stderr on failure** | diagnostic message |
| **exit code** | 0 = success, 1 = failure |

## Qiskit Qubit Ordering Convention

Qiskit Pauli strings use reversed qubit order relative to the `pps-circuit-v1`
convention:

- In `pps-circuit-v1`, qubit indices are 0-based with qubit 0 being the
  first (leftmost) qubit.
- In Qiskit Pauli strings, qubit 0 is the **rightmost** character.

The runner handles this reversal in two places:

1. **Gate construction** — single-qubit gates (`rx`, `ry`, `rz`) take a
   Qiskit qubit index directly. Multi-qubit and non-diagonal two-qubit Pauli
   rotations use `PauliEvolutionGate` with a full-width Pauli string built by
   placing each operator at position `nqubits - 1 - qubit_index`.

2. **Observable to pauli_sum** — the `to_qiskit_pauli_str(qubit, op, nqubits)`
   helper places the operator at `arr[nqubits - 1 - qubit]`.

## Observable to pauli_sum Conversion

The `pauli_sum` argument to `bq_client.run` is a list of
`(pauli_string, coefficient)` tuples, where `pauli_string` has length
`nqubits` and uses Qiskit qubit ordering.

| Observable | pauli_sum |
|---|---|
| `"Z0"` | `[("I...IZ", 1.0)]` (Z at rightmost position) |
| `"Z62"` on 127 qubits | `[("I...ZI...I", 1.0)]` (Z at Qiskit index 64) |
| `"Mz"` | 127 terms, each `(pauli_str_with_Z_at_qubit_i, 1/127)` |

## Truncation Threshold Mapping

The `pps-circuit-v1` `truncation.threshold` field maps directly to
`pauli_path_truncation_threshold` in the BlueQubit API call.

For the reference value, a second call is made with
`pauli_path_truncation_threshold=0.0` (exact, no truncation). If the main
threshold is already 0.0, the reference equals the expectation value and no
second API call is made.

## Memory Accounting

Memory is measured as the peak RSS of the Python process at the time the
runner exits, using `resource.getrusage(resource.RUSAGE_SELF).ru_maxrss`.
On Linux this is reported in kilobytes and converted to bytes. This captures
local memory overhead but does not reflect server-side memory consumed by
BlueQubit's cloud infrastructure.

The `memory_measure` metadata field is set to `"process_peak_rss"`.

## final_terms

BlueQubit's `pauli-path` device does not expose the number of internal Pauli
terms at the end of propagation. The `final_terms` field is therefore always
`-1` for this backend.

## Makefile Targets

| Target | Action |
|---|---|
| `make build-bluequbit` | Create `wrappers/python/.venv` and install dependencies |
| `make smoke-bluequbit` | Run a single small benchmark end-to-end |
| `make test-bluequbit` | Run Julia integration tests comparing BlueQubit and Julia results |
