struct PythonCuQuantumBackend <: AbstractBackend
    python_cmd::String
    script_path::String
    samples::Int

    function PythonCuQuantumBackend(;
        python_cmd::AbstractString="python3",
        script_path::AbstractString=_default_cuquantum_script_path(),
        samples::Int=1,
    )
        samples > 0 || throw(ArgumentError("samples must be positive"))
        return new(String(python_cmd), String(script_path), samples)
    end
end

backend_name(::PythonCuQuantumBackend) = "python_cuquantum"

function _default_cuquantum_script_path()
    return abspath(joinpath(@__DIR__, "..", "..", "wrappers", "python", "cuquantum_runner.py"))
end

function run_backend(backend::PythonCuQuantumBackend, spec::BenchmarkSpec)
    description = export_circuit(spec)
    return run_backend(backend, description; circuit_source="exported_from_spec")
end

function run_backend(
    backend::PythonCuQuantumBackend,
    description::CircuitDescription;
    circuit_source::AbstractString="circuit_json",
)
    _validate_circuit_description(description)
    isfile(backend.script_path) || throw(ErrorException(
        "cuquantum_runner.py not found at $(backend.script_path); " *
        "ensure wrappers/python/cuquantum_runner.py exists",
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
                "cuquantum_runner.py exited with code $(process.exitcode):\n$(stderr_str)",
            ))
        end

        parsed = _parse_cuquantum_runner_stdout(stdout_str, stderr_str)
        metadata = _coerce_cuquantum_metadata(parsed["metadata"])
        metadata["circuit_source"] = String(circuit_source)

        return BenchmarkResult(
            String(parsed["backend"]),
            String(parsed["task_id"]),
            Bool(parsed["success"]),
            Float64(parsed["runtime_sec"]),
            _cuq_to_int(parsed["memory_bytes"]),
            _cuq_to_int(parsed["final_terms"]),
            Float64(parsed["expectation"]),
            Float64(parsed["reference"]),
            Float64(parsed["absolute_error"]),
            metadata,
        )
    finally
        isfile(tmp_path) && rm(tmp_path; force=true)
    end
end

_cuq_to_int(x::Integer) = Int(x)
_cuq_to_int(x::AbstractFloat) = Int(round(x))

function _coerce_cuquantum_metadata(raw)
    return Dict{String,Any}(String(k) => v for (k, v) in raw)
end

# Parse the last non-empty line of stdout as JSON.  Tolerates stray preceding
# output (Python import warnings etc.) and surfaces parse failures with stderr.
function _parse_cuquantum_runner_stdout(stdout_str::AbstractString, stderr_str::AbstractString)
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
            "cuquantum_runner.py produced no stdout; stderr: $(stderr_str)",
        ))
    end
    try
        return JSON3.read(candidate, Dict{String,Any})
    catch err
        preview = first(candidate, 500)
        throw(ErrorException(
            "cuquantum_runner.py returned unparseable stdout ($(err)); " *
            "last stdout line preview: $(preview); stderr: $(stderr_str)",
        ))
    end
end
