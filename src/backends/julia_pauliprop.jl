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

"""
    run_surrogate_sweep(backend, spec; angle_indices=nothing, max_freq=nothing, max_weight=nothing)

Run the LOWESA surrogate benchmark for a `lowesa_tfi_127` spec. Builds the Pauli
propagation surrogate once (the LOWESA path graph), then evaluates the magnetization /
single-site expectation at every theta_h on the sweep grid. Reproduces Rudolph et al.
2023, Fig. 2a.

`angle_indices`, `max_freq`, `max_weight` override the config; used by the reduced
`make test` smoke check.
"""
function run_surrogate_sweep(
    backend::JuliaPauliPropBackend,
    spec::BenchmarkSpec;
    angle_indices=nothing,
    max_freq=nothing,
    max_weight=nothing,
)
    spec.family == "lowesa_tfi_127" ||
        throw(ArgumentError("run_surrogate_sweep requires family = lowesa_tfi_127"))

    circuit, _, _ = _export_task_components(spec)
    observable = _parse_observable(spec.nqubits, spec.observable)

    ℓ = isnothing(max_freq) ? Int(get(spec.truncation, "max_freq", 40)) : Int(max_freq)
    weight = isnothing(max_weight) ? Int(get(spec.truncation, "max_weight", 8)) : Int(max_weight)
    ℓ > 0 || throw(ArgumentError("max_freq must be positive"))
    weight > 0 || throw(ArgumentError("max_weight must be positive"))

    angles = lowesa_angle_grid(spec)
    selected = isnothing(angle_indices) ? collect(eachindex(angles)) : collect(angle_indices)

    has_reference = Bool(get(spec.reference, "enabled", false))
    reference_values = if has_reference
        ref_thetas, ref_values = lowesa_reference_curve(spec)
        length(ref_values) == length(angles) ||
            throw(ArgumentError("reference curve length $(length(ref_values)) != angle grid $(length(angles))"))
        ref_values
    else
        Float64[]
    end

    # RX parameters carry the swept field theta_h; RZZ parameters are fixed at -pi/2.
    is_rx = [gate.symbols == [:X] for gate in circuit]
    nparams = countparameters(circuit)
    length(is_rx) == nparams ||
        throw(ArgumentError("parameter mask length $(length(is_rx)) != countparameters $nparams"))

    # --- Build the surrogate once (the LOWESA path graph). ---
    obs_psum = observable isa PauliSum ? observable : PauliSum(observable)
    wrapped = _wrap_surrogate_observable(obs_psum)
    build = @timed propagate(circuit, wrapped; max_freq=ℓ, max_weight=weight)
    surrogate = build.value
    build_time_sec = Float64(build.time)
    peak_rss_bytes = Int(Sys.maxrss())

    num_paths_kept = length(surrogate.terms)
    num_paths_found = _count_surrogate_nodes(surrogate)

    # Drop X/Y strings (zero overlap with |0...0>) to speed up evaluation.
    zerofilter!(surrogate)

    # --- Evaluate every theta_h on the swept surrogate. ---
    points = BenchmarkSweepPoint[]
    squared_error_sum = 0.0
    error_count = 0
    eval_start = time_ns()
    for angle_index in selected
        1 <= angle_index <= length(angles) ||
            throw(ArgumentError("angle index $angle_index is outside 1:$(length(angles))"))
        angle = Float64(angles[angle_index])
        thetas = [is_rx[i] ? angle : -pi / 2 for i in 1:nparams]

        evaluated = @timed evaluate!(surrogate, thetas)
        expectation = Float64(real(overlapwithzero(surrogate)))

        reference = has_reference ? Float64(reference_values[angle_index]) : NaN
        absolute_error = has_reference ? abs(expectation - reference) : NaN
        if has_reference
            squared_error_sum += absolute_error^2
            error_count += 1
        end

        push!(
            points,
            BenchmarkSweepPoint(
                angle_index,
                angle,
                true,
                Float64(evaluated.time),
                Int(evaluated.bytes),
                num_paths_kept,
                expectation,
                reference,
                absolute_error,
                Dict{String,Any}("eval_allocs_bytes" => Int(evaluated.bytes)),
            ),
        )
    end
    eval_time_sec = Float64(time_ns() - eval_start) / 1.0e9
    rmse = error_count > 0 ? sqrt(squared_error_sum / error_count) : NaN

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
            "max_freq" => ℓ,
            "max_weight" => weight,
            "circuit_size" => length(circuit),
            "parameter_count" => nparams,
            "build_time_sec" => build_time_sec,
            "eval_time_sec" => eval_time_sec,
            "num_paths_found" => num_paths_found,
            "num_paths_kept" => num_paths_kept,
            "peak_rss_bytes" => peak_rss_bytes,
            "rmse" => rmse,
            "reference_enabled" => has_reference,
            "reference_file" => String(get(spec.reference, "file", "")),
            "reference_arxiv" => "https://arxiv.org/abs/2308.09109",
            "reference_code" => "https://github.com/MSRudolph/PauliPropagation.jl",
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

# Wrap an observable PauliSum into surrogate `NodePathProperties` coefficients.
#
# PauliPropagation's own `wrapcoefficients(_, NodePathProperties)` stores each observable
# Pauli string in `EvalEndNode.pstr::Int`, which overflows for >~31-qubit strings (a
# 127-qubit string needs UInt256). That `pstr` field is only used for pretty-printing --
# never during `evaluate!` -- so we wrap manually with a dummy `pstr = 0` label while the
# real UInt256 Pauli keys stay on the PauliSum. This makes the surrogate work at 127
# qubits without depending on the broken helper.
function _wrap_surrogate_observable(psum::PauliSum)
    terms = Dict(
        pstr => NodePathProperties(PauliPropagation.EvalEndNode(0, Float64(coeff), 0.0, false))
        for (pstr, coeff) in psum.terms
    )
    return PauliSum(psum.nqubits, terms)
end

# Count distinct nodes in the surrogate path graph (PauliRotationNode + EvalEndNode),
# reached by de-duplicated traversal from every surviving Pauli operator. This is the
# benchmark's `num_paths_found`: PauliPropagation merges paths and truncates inside
# max_weight/max_freq, so a pre-truncation candidate count is not recoverable.
function _count_surrogate_nodes(surrogate)
    seen = Set{UInt}()
    stack = Any[]
    for path in coefficients(surrogate)
        push!(stack, path.node)
    end
    while !isempty(stack)
        node = pop!(stack)
        node_id = objectid(node)
        node_id in seen && continue
        push!(seen, node_id)
        if node isa PauliPropagation.PauliRotationNode
            append!(stack, node.parents)
        end
    end
    return length(seen)
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
        NaN,
        NaN,
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
    if observable == "Mz" || observable == "magnetization"
        # Mz = (1/nqubits) * sum_i Z_i
        psum = PauliSum(nqubits)
        coeff = 1.0 / nqubits
        for qind in 1:nqubits
            add!(psum, :Z, qind, coeff)
        end
        return psum
    end

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
