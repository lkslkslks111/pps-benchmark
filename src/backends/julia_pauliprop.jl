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
    spec.family == "clifford_pauli_rotation" ||
        throw(ArgumentError("unsupported benchmark family: $(spec.family)"))

    circuit, thetas, observable = _build_pauliprop_task(spec)
    threshold = _threshold(spec)
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
        "observable" => spec.observable,
    )

    return BenchmarkResult(
        backend_name(backend),
        spec.task_id,
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

function _build_pauliprop_task(spec::BenchmarkSpec)
    circuit = hardwareefficientcircuit(spec.nqubits, spec.nlayers)
    thetas = [sin(spec.seed + idx) for idx in 1:countparameters(circuit)]
    observable = _parse_observable(spec.nqubits, spec.observable)
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
    method = get(spec.truncation, "method", "")
    method == "threshold" || throw(ArgumentError("unsupported truncation method: $method"))
    return Float64(spec.truncation["threshold"])
end
