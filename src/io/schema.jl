using JSON3
using PauliPropagation
using TOML

const CIRCUIT_SCHEMA_VERSION = "pps-circuit-v1"
const CIRCUIT_GATE_TYPE_PAULI_ROTATION = "pauli_rotation"
const SUPPORTED_PAULI_SYMBOLS = Set(["I", "X", "Y", "Z"])

struct BenchmarkSpec
    task_id::String
    family::String
    nqubits::Int
    nlayers::Int
    observable::String
    seed::Int
    truncation::Dict{String,Any}
    reference::Dict{String,Any}
    metadata::Dict{String,Any}
end

struct BenchmarkResult
    backend::String
    task_id::String
    success::Bool
    runtime_sec::Float64
    memory_bytes::Int
    final_terms::Int
    expectation::Float64
    reference::Float64
    absolute_error::Float64
    metadata::Dict{String,Any}
end

struct CircuitGate
    type::String
    paulis::Vector{String}
    qubits::Vector{Int}
    theta::Float64
end

struct CircuitDescription
    schema_version::String
    task_id::String
    family::String
    seed::Int
    nqubits::Int
    observable::String
    truncation::Dict{String,Any}
    reference::Dict{String,Any}
    gates::Vector{CircuitGate}
    metadata::Dict{String,Any}
end

function _string_any_dict(data)
    return Dict{String,Any}(String(k) => v for (k, v) in data)
end

function load_benchmark_spec(path::AbstractString)
    config = TOML.parsefile(path)
    task = config["task"]

    return BenchmarkSpec(
        String(task["task_id"]),
        String(task["family"]),
        Int(task["nqubits"]),
        Int(task["nlayers"]),
        String(task["observable"]),
        Int(config["seed"]),
        _string_any_dict(config["truncation"]),
        _string_any_dict(config["reference"]),
        Dict{String,Any}("name" => String(config["name"]), "config_path" => String(path)),
    )
end

function benchmark_result_dict(result::BenchmarkResult)
    return Dict{String,Any}(
        "backend" => result.backend,
        "task_id" => result.task_id,
        "success" => result.success,
        "runtime_sec" => result.runtime_sec,
        "memory_bytes" => result.memory_bytes,
        "final_terms" => result.final_terms,
        "expectation" => result.expectation,
        "reference" => result.reference,
        "absolute_error" => result.absolute_error,
        "metadata" => result.metadata,
    )
end

function export_circuit(spec::BenchmarkSpec)
    spec.family == "clifford_pauli_rotation" ||
        throw(ArgumentError("unsupported benchmark family: $(spec.family)"))

    circuit = hardwareefficientcircuit(spec.nqubits, spec.nlayers)
    thetas = [sin(spec.seed + idx) for idx in 1:countparameters(circuit)]
    gates = CircuitGate[
        CircuitGate(
            CIRCUIT_GATE_TYPE_PAULI_ROTATION,
            String.(gate.symbols),
            Int.(gate.qinds .- 1),
            Float64(theta),
        )
        for (gate, theta) in zip(circuit, thetas)
    ]

    metadata = copy(spec.metadata)
    metadata["nlayers"] = spec.nlayers

    description = CircuitDescription(
        CIRCUIT_SCHEMA_VERSION,
        spec.task_id,
        spec.family,
        spec.seed,
        spec.nqubits,
        spec.observable,
        copy(spec.truncation),
        copy(spec.reference),
        gates,
        metadata,
    )
    _validate_circuit_description(description)
    return description
end

function circuit_description_dict(description::CircuitDescription)
    return Dict{String,Any}(
        "schema_version" => description.schema_version,
        "task_id" => description.task_id,
        "family" => description.family,
        "seed" => description.seed,
        "nqubits" => description.nqubits,
        "observable" => description.observable,
        "truncation" => description.truncation,
        "reference" => description.reference,
        "gates" => [
            Dict{String,Any}(
                "type" => gate.type,
                "paulis" => gate.paulis,
                "qubits" => gate.qubits,
                "theta" => gate.theta,
            )
            for gate in description.gates
        ],
        "metadata" => description.metadata,
    )
end

function write_circuit_description(path::AbstractString, description::CircuitDescription)
    _validate_circuit_description(description)
    open(path, "w") do io
        JSON3.write(io, circuit_description_dict(description))
        println(io)
    end
    return path
end

function load_circuit_description(path::AbstractString)
    parsed = JSON3.read(read(path, String))
    description = _circuit_description_from_json(parsed)
    _validate_circuit_description(description)
    return description
end

function _circuit_description_from_json(data)
    gates = CircuitGate[
        CircuitGate(
            String(gate[:type]),
            String.(collect(gate[:paulis])),
            Int.(collect(gate[:qubits])),
            Float64(gate[:theta]),
        )
        for gate in data[:gates]
    ]

    return CircuitDescription(
        String(data[:schema_version]),
        String(data[:task_id]),
        String(data[:family]),
        Int(data[:seed]),
        Int(data[:nqubits]),
        String(data[:observable]),
        _string_any_dict(data[:truncation]),
        _string_any_dict(data[:reference]),
        gates,
        _string_any_dict(data[:metadata]),
    )
end

function _validate_circuit_description(description::CircuitDescription)
    description.schema_version == CIRCUIT_SCHEMA_VERSION ||
        throw(ArgumentError("unsupported circuit schema version: $(description.schema_version)"))
    description.nqubits > 0 || throw(ArgumentError("nqubits must be positive"))

    for (idx, gate) in enumerate(description.gates)
        gate.type == CIRCUIT_GATE_TYPE_PAULI_ROTATION ||
            throw(ArgumentError("unsupported gate type at gate $idx: $(gate.type)"))
        length(gate.paulis) == length(gate.qubits) ||
            throw(ArgumentError("gate $idx paulis and qubits must have the same length"))
        isempty(gate.paulis) && throw(ArgumentError("gate $idx must act on at least one qubit"))

        for pauli in gate.paulis
            pauli in SUPPORTED_PAULI_SYMBOLS ||
                throw(ArgumentError("unsupported Pauli symbol at gate $idx: $pauli"))
        end

        for qubit in gate.qubits
            0 <= qubit < description.nqubits ||
                throw(ArgumentError("gate $idx qubit index $qubit is outside 0:$(description.nqubits - 1)"))
        end
    end

    return nothing
end
