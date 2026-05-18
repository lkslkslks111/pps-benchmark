using TOML

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
