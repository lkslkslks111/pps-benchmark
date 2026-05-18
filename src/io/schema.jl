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

struct BenchmarkSweepPoint
    angle_index::Int
    angle::Float64
    success::Bool
    runtime_sec::Float64
    memory_bytes::Int
    final_terms::Int
    expectation::Float64
    metadata::Dict{String,Any}
end

struct BenchmarkSweepResult
    backend::String
    task_id::String
    success::Bool
    results::Vector{BenchmarkSweepPoint}
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
    metadata = Dict{String,Any}("name" => String(config["name"]), "config_path" => String(path))
    if haskey(config, "metadata")
        merge!(metadata, _string_any_dict(config["metadata"]))
    end

    return BenchmarkSpec(
        String(task["task_id"]),
        String(task["family"]),
        Int(task["nqubits"]),
        Int(task["nlayers"]),
        String(task["observable"]),
        Int(config["seed"]),
        _string_any_dict(config["truncation"]),
        _string_any_dict(config["reference"]),
        metadata,
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

function benchmark_sweep_result_dict(result::BenchmarkSweepResult)
    return Dict{String,Any}(
        "backend" => result.backend,
        "task_id" => result.task_id,
        "success" => result.success,
        "results" => [
            Dict{String,Any}(
                "angle_index" => point.angle_index,
                "angle" => point.angle,
                "success" => point.success,
                "runtime_sec" => point.runtime_sec,
                "memory_bytes" => point.memory_bytes,
                "final_terms" => point.final_terms,
                "expectation" => point.expectation,
                "metadata" => point.metadata,
            )
            for point in result.results
        ],
        "metadata" => result.metadata,
    )
end

function export_circuit(spec::BenchmarkSpec)
    circuit, thetas, family_metadata = _export_task_components(spec)
    gates = CircuitGate[]
    theta_idx = 1
    for gate in circuit
        theta = if gate isa FrozenGate
            Float64(gate.parameter)
        elseif gate isa ParametrizedGate
            theta_idx <= length(thetas) ||
                throw(ArgumentError("missing theta for parametrized gate $theta_idx"))
            value = Float64(thetas[theta_idx])
            theta_idx += 1
            value
        else
            throw(ArgumentError("unsupported circuit gate for export: $(typeof(gate))"))
        end
        push!(
            gates,
            CircuitGate(
                CIRCUIT_GATE_TYPE_PAULI_ROTATION,
                String.(_pauli_rotation_symbols(gate)),
                Int.(_pauli_rotation_qinds(gate) .- 1),
                theta,
            ),
        )
    end
    theta_idx == length(thetas) + 1 ||
        throw(ArgumentError("unused theta values while exporting circuit"))

    metadata = copy(spec.metadata)
    metadata["nlayers"] = spec.nlayers
    merge!(metadata, family_metadata)

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

function _export_task_components(spec::BenchmarkSpec)
    if spec.family == "clifford_pauli_rotation"
        circuit = hardwareefficientcircuit(spec.nqubits, spec.nlayers)
        thetas = [sin(spec.seed + idx) for idx in 1:countparameters(circuit)]
        metadata = Dict{String,Any}("parameter_rule" => "theta_i = sin(seed + i)")
        return circuit, thetas, metadata
    elseif spec.family == "ibm_eagle_tfi"
        spec.nqubits == 127 ||
            throw(ArgumentError("ibm_eagle_tfi requires nqubits = 127"))
        circuit = tfitrottercircuit(127, spec.nlayers; topology=ibmeagletopology, start_with_ZZ=true)
        thetas = [_ibm_eagle_tfi_theta(gate) for gate in circuit]
        metadata = Dict{String,Any}(
            "topology" => "ibm_eagle",
            "parameter_rule" => "ZZ rotations use pi/4; X rotations use pi/8",
            "reference_paper" => "IBM Nature 618, 500-505 (2023)",
            "reproduction_scope" => "127-qubit Julia PauliPropagation scaffold; not IBM hardware noise mitigation",
        )
        return circuit, thetas, metadata
    elseif spec.family == "rudolph_eagle_127"
        spec.nqubits == 127 ||
            throw(ArgumentError("rudolph_eagle_127 requires nqubits = 127"))
        spec.nlayers == 20 ||
            throw(ArgumentError("rudolph_eagle_127 requires nlayers = 20"))
        circuit = _rudolph_eagle_127_circuit(spec.nlayers)
        thetas = zeros(Float64, countparameters(circuit))
        metadata = Dict{String,Any}(
            "topology" => "ibm_eagle",
            "parameter_rule" => "RX parameters sweep LinRange(0, pi/2, 20); RZZ rotations are frozen at -pi/2",
            "observable_julia_index" => 63,
            "reference_arxiv" => "https://arxiv.org/abs/2505.21606",
            "reference_code" => "https://github.com/MSRudolph/PauliPropagation.jl",
            "ibm_kicked_ising_context" => "https://quantum.cloud.ibm.com/docs/tutorials/dc-hex-ising",
            "reproduction_scope" => "Julia PauliPropagation.jl 127-qubit utility example sweep; not IBM hardware noise mitigation",
        )
        return circuit, thetas, metadata
    end

    throw(ArgumentError("unsupported benchmark family: $(spec.family)"))
end

function _rudolph_eagle_127_circuit(nlayers::Int)
    circuit = Gate[]
    for _ in 1:nlayers
        rxlayer!(circuit, 127)
        append!(circuit, (PauliRotation([:Z, :Z], pair, -pi / 2) for pair in ibmeagletopology))
    end
    return circuit
end

function _ibm_eagle_tfi_theta(gate)
    if gate.symbols == [:Z, :Z]
        return Float64(pi / 4)
    elseif gate.symbols == [:X]
        return Float64(pi / 8)
    end
    throw(ArgumentError("unsupported ibm_eagle_tfi gate symbols: $(gate.symbols)"))
end

function _pauli_rotation_symbols(gate::PauliRotation)
    return gate.symbols
end

function _pauli_rotation_symbols(gate::FrozenGate)
    return _pauli_rotation_symbols(gate.gate)
end

function _pauli_rotation_qinds(gate::PauliRotation)
    return gate.qinds
end

function _pauli_rotation_qinds(gate::FrozenGate)
    return _pauli_rotation_qinds(gate.gate)
end

function rudolph_angle_grid(spec::BenchmarkSpec)
    spec.family == "rudolph_eagle_127" ||
        throw(ArgumentError("rudolph_angle_grid requires family = rudolph_eagle_127"))
    start = Float64(get(spec.metadata, "angle_start", 0.0))
    stop = Float64(get(spec.metadata, "angle_stop", pi / 2))
    count = Int(get(spec.metadata, "angle_count", 20))
    count > 1 || throw(ArgumentError("angle_count must be greater than 1"))
    return collect(LinRange(start, stop, count))
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
