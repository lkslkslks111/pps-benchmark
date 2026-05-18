using BenchmarkTools
using PauliPropagation

struct JuliaPauliPropBackend <: AbstractBackend
    samples::Int
    evals::Int

    function JuliaPauliPropBackend(; samples::Int=5, evals::Int=1)
        samples > 0 || throw(ArgumentError("samples must be positive"))
        evals > 0 || throw(ArgumentError("evals must be positive"))
        return new(samples, evals)
    end
end

backend_name(::JuliaPauliPropBackend) = "julia_pauliprop"

function run_backend(backend::JuliaPauliPropBackend, spec::BenchmarkSpec)
    circuit_description = export_circuit(spec)
    return run_backend(backend, circuit_description; circuit_source="exported_from_spec")
end

function run_backend(
    backend::JuliaPauliPropBackend,
    circuit_description::CircuitDescription;
    circuit_source::AbstractString="explicit_circuit",
)
    _validate_circuit_description(circuit_description)
    circuit, thetas, observable = _build_pauliprop_task(circuit_description)
    metadata_extra = Dict{String,Any}(
        "circuit_schema_version" => circuit_description.schema_version,
        "circuit_source" => String(circuit_source),
        "family" => circuit_description.family,
        "nqubits" => circuit_description.nqubits,
    )
    return _run_pauliprop_task(
        backend,
        circuit_description.task_id,
        circuit_description.truncation,
        circuit_description.observable,
        circuit,
        thetas,
        observable,
        metadata_extra,
    )
end

function run_direct_builder(backend::JuliaPauliPropBackend, spec::BenchmarkSpec)
    circuit, thetas, observable = _build_pauliprop_task(spec)
    return _run_pauliprop_task(
        backend,
        spec.task_id,
        spec.truncation,
        spec.observable,
        circuit,
        thetas,
        observable,
        Dict{String,Any}("circuit_source" => "direct_builder"),
    )
end

function run_sweep(
    backend::JuliaPauliPropBackend,
    spec::BenchmarkSpec;
    angle_indices=nothing,
)
    spec.family == "rudolph_eagle_127" ||
        throw(ArgumentError("run_sweep currently supports family = rudolph_eagle_127"))

    circuit, _, _ = _export_task_components(spec)
    observable = _parse_observable(spec.nqubits, spec.observable)
    angles = rudolph_angle_grid(spec)
    selected_indices = isnothing(angle_indices) ? collect(eachindex(angles)) : collect(angle_indices)
    threshold = _threshold(spec.truncation)
    max_weight = Int(get(spec.metadata, "max_weight", 8))
    parameter_count = countparameters(circuit)

    points = BenchmarkSweepPoint[]
    for angle_index in selected_indices
        1 <= angle_index <= length(angles) ||
            throw(ArgumentError("angle index $angle_index is outside 1:$(length(angles))"))
        angle = Float64(angles[angle_index])
        thetas = fill(angle, parameter_count)
        point = _run_pauliprop_sweep_point(
            backend,
            circuit,
            thetas,
            observable,
            angle_index,
            angle,
            threshold,
            max_weight,
        )
        push!(points, point)
    end

    metadata = copy(spec.metadata)
    merge!(
        metadata,
        Dict{String,Any}(
            "family" => spec.family,
            "nqubits" => spec.nqubits,
            "nlayers" => spec.nlayers,
            "observable" => spec.observable,
            "topology" => "ibm_eagle",
            "angle_start" => first(angles),
            "angle_stop" => last(angles),
            "angle_count" => length(angles),
            "evaluated_angle_count" => length(points),
            "min_abs_coeff" => threshold,
            "max_weight" => max_weight,
            "circuit_size" => length(circuit),
            "parameter_count" => parameter_count,
            "benchmark_samples" => backend.samples,
            "benchmark_evals" => backend.evals,
            "reference_arxiv" => "https://arxiv.org/abs/2505.21606",
            "reference_code" => "https://github.com/MSRudolph/PauliPropagation.jl",
            "ibm_kicked_ising_context" => "https://quantum.cloud.ibm.com/docs/tutorials/dc-hex-ising",
        ),
    )

    return BenchmarkSweepResult(
        backend_name(backend),
        spec.task_id,
        all(point -> point.success, points),
        points,
        metadata,
    )
end

function _run_pauliprop_task(
    backend::JuliaPauliPropBackend,
    task_id::AbstractString,
    truncation::Dict{String,Any},
    observable_label::AbstractString,
    circuit,
    thetas,
    observable,
    metadata_extra::Dict{String,Any},
)
    threshold = _threshold(truncation)
    threshold_run = () -> propagate(circuit, observable, thetas; min_abs_coeff=threshold)

    samples = backend.samples
    evals = backend.evals
    trial = run(@benchmarkable $threshold_run() samples = samples evals = evals)
    threshold_result = threshold_run()
    exact_result = propagate(circuit, observable, thetas; min_abs_coeff=0.0)

    expectation = Float64(real(overlapwithzero(threshold_result)))
    reference = Float64(real(overlapwithzero(exact_result)))
    med = median(trial)
    min_est = minimum(trial)

    metadata = Dict{String,Any}(
        "benchmark_samples" => backend.samples,
        "benchmark_evals" => backend.evals,
        "minimum_time_sec" => Float64(min_est.time) / 1.0e9,
        "median_time_sec" => Float64(med.time) / 1.0e9,
        "median_gctime_sec" => Float64(med.gctime) / 1.0e9,
        "median_allocs" => Int(med.allocs),
        "circuit_size" => length(circuit),
        "parameter_count" => length(thetas),
        "truncation_threshold" => threshold,
        "observable" => String(observable_label),
    )
    merge!(metadata, metadata_extra)

    return BenchmarkResult(
        backend_name(backend),
        String(task_id),
        true,
        Float64(med.time) / 1.0e9,
        Int(med.memory),
        length(threshold_result.terms),
        expectation,
        reference,
        abs(expectation - reference),
        metadata,
    )
end

function _run_pauliprop_sweep_point(
    backend::JuliaPauliPropBackend,
    circuit,
    thetas,
    observable,
    angle_index::Int,
    angle::Float64,
    threshold::Float64,
    max_weight::Int,
)
    threshold_run = () -> propagate(circuit, observable, thetas; min_abs_coeff=threshold, max_weight=max_weight)

    samples = backend.samples
    evals = backend.evals
    trial = run(@benchmarkable $threshold_run() samples = samples evals = evals)
    threshold_result = threshold_run()
    expectation = Float64(real(overlapwithzero(threshold_result)))
    med = median(trial)
    min_est = minimum(trial)

    metadata = Dict{String,Any}(
        "minimum_time_sec" => Float64(min_est.time) / 1.0e9,
        "median_time_sec" => Float64(med.time) / 1.0e9,
        "median_gctime_sec" => Float64(med.gctime) / 1.0e9,
        "median_allocs" => Int(med.allocs),
    )

    return BenchmarkSweepPoint(
        angle_index,
        angle,
        true,
        Float64(med.time) / 1.0e9,
        Int(med.memory),
        length(threshold_result.terms),
        expectation,
        metadata,
    )
end

function _build_pauliprop_task(spec::BenchmarkSpec)
    circuit, thetas, _ = _export_task_components(spec)
    observable = _parse_observable(spec.nqubits, spec.observable)
    return circuit, thetas, observable
end

function _build_pauliprop_task(description::CircuitDescription)
    circuit = [
        PauliRotation(Symbol.(gate.paulis), Int.(gate.qubits .+ 1))
        for gate in description.gates
    ]
    thetas = [gate.theta for gate in description.gates]
    observable = _parse_observable(description.nqubits, description.observable)
    return circuit, thetas, observable
end

function _parse_observable(nqubits::Int, observable::AbstractString)
    match_result = match(r"^([IXYZ])(\d+)$", observable)
    match_result === nothing && throw(ArgumentError("unsupported observable: $observable"))

    symbol = Symbol(match_result.captures[1])
    zero_based_index = parse(Int, match_result.captures[2])
    qind = zero_based_index + 1
    1 <= qind <= nqubits ||
        throw(ArgumentError("observable qubit index $zero_based_index is outside 0:$(nqubits - 1)"))

    return PauliString(nqubits, symbol, qind)
end

function _threshold(spec::BenchmarkSpec)
    return _threshold(spec.truncation)
end

function _threshold(truncation::Dict{String,Any})
    method = get(truncation, "method", "")
    method == "threshold" || throw(ArgumentError("unsupported truncation method: $method"))
    return Float64(truncation["threshold"])
end
