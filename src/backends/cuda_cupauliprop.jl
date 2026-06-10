struct CudaCuPauliPropBackend <: AbstractBackend
    python_cmd::String
    script_path::String
    samples::Int

    function CudaCuPauliPropBackend(;
        python_cmd::AbstractString=_default_cuda_python_cmd(),
        script_path::AbstractString=_default_cuda_script_path(),
        samples::Int=1,
    )
        samples > 0 || throw(ArgumentError("samples must be positive"))
        return new(String(python_cmd), String(script_path), samples)
    end
end

backend_name(::CudaCuPauliPropBackend) = "cuda_cupauliprop"

# `@__DIR__` is `<repo>/src/backends`; walk up two levels to the repo root.
function _default_cuda_script_path()
    return abspath(joinpath(@__DIR__, "..", "..", "wrappers", "cuda", "cupauliprop_runner.py"))
end

# Prefer the bundled venv python (created by `make build-cuda`) so that
# cuquantum is available without requiring a system-wide installation.
function _default_cuda_python_cmd()
    venv_python = abspath(joinpath(@__DIR__, "..", "..", "wrappers", "cuda", ".venv", "bin", "python3"))
    return isfile(venv_python) ? venv_python : "python3"
end

function run_backend(backend::CudaCuPauliPropBackend, spec::BenchmarkSpec)
    description = export_circuit(spec)
    return run_backend(backend, description; circuit_source="exported_from_spec")
end

function run_backend(
    backend::CudaCuPauliPropBackend,
    description::CircuitDescription;
    circuit_source::AbstractString="circuit_json",
)
    _validate_circuit_description(description)
    isfile(backend.script_path) || throw(ErrorException(
        "cuda_cupauliprop script not found at $(backend.script_path); " *
        "ensure wrappers/cuda/cupauliprop_runner.py exists",
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
                "cuda_cupauliprop_runner exited with code $(process.exitcode):\n$(stderr_str)",
            ))
        end

        parsed = _parse_cuda_runner_stdout(stdout_str, stderr_str)
        metadata = _coerce_cuda_metadata(parsed["metadata"])
        metadata["circuit_source"] = String(circuit_source)

        return BenchmarkResult(
            String(parsed["backend"]),
            String(parsed["task_id"]),
            Bool(parsed["success"]),
            Float64(parsed["runtime_sec"]),
            _cuda_to_int(parsed["memory_bytes"]),
            _cuda_to_int(parsed["final_terms"]),
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
    backend::CudaCuPauliPropBackend,
    spec::BenchmarkSpec;
    angle_indices=nothing,
)
    return run_external_backend_sweep(backend, spec; angle_indices=angle_indices)
end

_cuda_to_int(x::Integer) = Int(x)
_cuda_to_int(x::AbstractFloat) = Int(round(x))

function _coerce_cuda_metadata(raw)
    return Dict{String,Any}(String(k) => v for (k, v) in raw)
end

# The runner emits exactly one JSON line on stdout. Be tolerant of stray
# preceding output (Python warnings, accidental print) and surface parse
# failures with the runner's stderr so callers see a structured backend error
# rather than a bare JSON3.Error.
function _parse_cuda_runner_stdout(stdout_str::AbstractString, stderr_str::AbstractString)
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
            "cuda_cupauliprop_runner produced no stdout; stderr: $(stderr_str)",
        ))
    end
    try
        return JSON3.read(candidate, Dict{String,Any})
    catch err
        preview = first(candidate, 500)
        throw(ErrorException(
            "cuda_cupauliprop_runner returned unparseable stdout ($(err)); " *
            "last stdout line preview: $(preview); stderr: $(stderr_str)",
        ))
    end
end
