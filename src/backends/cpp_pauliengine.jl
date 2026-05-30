struct CppPauliEngineBackend <: AbstractBackend
    python_cmd::String
    script_path::String
    samples::Int

    function CppPauliEngineBackend(;
        python_cmd::AbstractString="python3",
        script_path::AbstractString=_default_cpp_script_path(),
        samples::Int=1,
    )
        samples > 0 || throw(ArgumentError("samples must be positive"))
        return new(String(python_cmd), String(script_path), samples)
    end
end

backend_name(::CppPauliEngineBackend) = "cpp_pauliengine"

const _CPP_SCRIPT_RELATIVE_PATH = joinpath("wrappers", "cpp", "pauliengine_runner.py")

# `@__DIR__` is `<repo>/src/backends`; walk up two levels to the repo root.
function _default_cpp_script_path()
    return abspath(joinpath(@__DIR__, "..", "..", _CPP_SCRIPT_RELATIVE_PATH))
end

function run_backend(backend::CppPauliEngineBackend, spec::BenchmarkSpec)
    description = export_circuit(spec)
    return run_backend(backend, description; circuit_source="exported_from_spec")
end

function run_backend(
    backend::CppPauliEngineBackend,
    description::CircuitDescription;
    circuit_source::AbstractString="circuit_json",
)
    _validate_circuit_description(description)
    isfile(backend.script_path) || throw(ErrorException(
        "cpp_pauliengine runner not found at $(backend.script_path); " *
        "install pauliengine with `make build-cpp` or `pip install pauliengine`",
    ))

    tmp_path, tmp_io = mktemp(; cleanup=false)
    close(tmp_io)
    try
        write_circuit_description(tmp_path, description)
        cmd = `$(backend.python_cmd) $(backend.script_path) --circuit $tmp_path --samples $(backend.samples)`

        out_buf = IOBuffer()
        err_buf = IOBuffer()
        process = run(pipeline(cmd; stdout=out_buf, stderr=err_buf); wait=false)
        wait(process)

        stdout_str = String(take!(out_buf))
        stderr_str = String(take!(err_buf))
        if !success(process)
            throw(ErrorException(
                "pauliengine_runner.py exited with code $(process.exitcode):\n$(stderr_str)",
            ))
        end

        parsed = _parse_cpp_runner_stdout(stdout_str, stderr_str)
        metadata = _coerce_cpp_metadata(parsed["metadata"])
        metadata["circuit_source"] = String(circuit_source)

        return BenchmarkResult(
            String(parsed["backend"]),
            String(parsed["task_id"]),
            Bool(parsed["success"]),
            Float64(parsed["runtime_sec"]),
            _to_cpp_int(parsed["memory_bytes"]),
            _to_cpp_int(parsed["final_terms"]),
            Float64(parsed["expectation"]),
            Float64(parsed["reference"]),
            Float64(parsed["absolute_error"]),
            metadata,
        )
    finally
        isfile(tmp_path) && rm(tmp_path; force=true)
    end
end

function run_backend_sweep(
    backend::CppPauliEngineBackend,
    spec::BenchmarkSpec;
    angle_indices=nothing,
)
    return run_external_backend_sweep(backend, spec; angle_indices=angle_indices)
end

_to_cpp_int(x::Integer) = Int(x)
_to_cpp_int(x::AbstractFloat) = Int(round(x))

function _coerce_cpp_metadata(raw)
    return Dict{String,Any}(String(k) => v for (k, v) in raw)
end

# The runner emits exactly one JSON line on stdout. Be tolerant of stray
# preceding output (Python warnings, accidental print) and surface parse
# failures with the runner's stderr so callers see a structured backend error
# rather than a bare JSON3.Error.
function _parse_cpp_runner_stdout(stdout_str::AbstractString, stderr_str::AbstractString)
    candidate = ""
    for line in Iterators.reverse(split(stdout_str, '\n'))
        trimmed = strip(line)
        if !isempty(trimmed)
            candidate = String(trimmed)
            break
        end
    end
    if isempty(candidate)
        throw(ErrorException(
            "pauliengine_runner.py produced no stdout; stderr: $(stderr_str)",
        ))
    end
    try
        return JSON3.read(candidate, Dict{String,Any})
    catch err
        preview = first(candidate, 500)
        throw(ErrorException(
            "pauliengine_runner.py returned unparseable stdout ($(err)); " *
            "last stdout line preview: $(preview); stderr: $(stderr_str)",
        ))
    end
end
