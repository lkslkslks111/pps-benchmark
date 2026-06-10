abstract type AbstractBackend end

# Optional numeric fields from external runner JSON: absent or null -> nothing.
_optional_int(x) = x === nothing ? nothing : Int(round(Float64(x)))
_optional_float(x) = x === nothing ? nothing : Float64(x)

function backend_name(backend::AbstractBackend)
    throw(MethodError(backend_name, (backend,)))
end

function run_backend(backend::AbstractBackend, spec::BenchmarkSpec)
    throw(MethodError(run_backend, (backend, spec)))
end

function run_backend_sweep(backend::AbstractBackend, spec::BenchmarkSpec; kwargs...)
    throw(MethodError(run_backend_sweep, (backend, spec)))
end

function run_external_backend_sweep(
    backend::AbstractBackend,
    spec::BenchmarkSpec;
    angle_indices=nothing,
)
    spec.family == "lowesa_tfi_127" ||
        throw(ArgumentError("run_external_backend_sweep requires family = lowesa_tfi_127"))

    angles = lowesa_angle_grid(spec)
    selected = isnothing(angle_indices) ? collect(eachindex(angles)) : collect(angle_indices)

    has_reference = Bool(get(spec.reference, "enabled", false))
    reference_values = if has_reference
        _, ref_vals = lowesa_reference_curve(spec)
        ref_vals
    else
        Float64[]
    end

    points = BenchmarkSweepPoint[]
    squared_error_sum = 0.0
    error_count = 0

    for angle_index in selected
        1 <= angle_index <= length(angles) ||
            throw(ArgumentError("angle index $angle_index is outside 1:$(length(angles))"))
        angle = Float64(angles[angle_index])
        description = export_circuit_at_angle(spec, angle)
        result = run_backend(backend, description; circuit_source="lowesa_sweep_angle_$(angle_index)")
        # Per-gate term-count histories are for single-run growth plots; at
        # sweep scale (angles x gates) they would bloat the sweep JSON.
        delete!(result.metadata, "terms_history")

        reference = has_reference ? Float64(reference_values[angle_index]) : NaN
        absolute_error = has_reference ? abs(result.expectation - reference) : NaN
        if has_reference
            squared_error_sum += absolute_error^2
            error_count += 1
        end

        push!(
            points,
            BenchmarkSweepPoint(
                angle_index,
                angle,
                result.success,
                result.runtime_sec,
                result.memory_bytes,
                result.final_terms,
                result.expectation,
                reference,
                absolute_error,
                result.metadata,
            ),
        )
    end

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
            "max_freq" => Int(get(spec.truncation, "max_freq", 40)),
            "max_weight" => Int(get(spec.truncation, "max_weight", 8)),
            "reference_enabled" => has_reference,
            "reference_file" => String(get(spec.reference, "file", "")),
            "rmse" => rmse,
            "reference_arxiv" => "https://arxiv.org/abs/2308.09109",
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
