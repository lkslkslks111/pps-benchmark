#!/usr/bin/env julia

using JSON3
using PPSBackendBench

function _usage()
    return "usage: julia --project=. benchmarks/run_sweep.jl --backend julia_pauliprop --config configs/reproduce_rudolph_eagle_127.toml"
end

function _parse_args(args)
    parsed = Dict{String,String}()
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg in ("--backend", "--config")
            i < length(args) || throw(ArgumentError("missing value for $arg"))
            parsed[arg[3:end]] = args[i + 1]
            i += 2
        else
            throw(ArgumentError("unknown argument: $arg"))
        end
    end

    haskey(parsed, "backend") || throw(ArgumentError("missing --backend; $(_usage())"))
    haskey(parsed, "config") || throw(ArgumentError("missing --config; $(_usage())"))
    return parsed
end

function _make_backend(name::AbstractString)
    if name == "julia_pauliprop"
        return JuliaPauliPropBackend(samples=1, evals=1)
    elseif name == "rust_pauliprop"
        return RustPauliPropBackend(samples=1)
    elseif name == "python_cuquantum"
        return PythonCuQuantumBackend(samples=1)
    elseif name == "cuda_cupauliprop"
        return CudaCuPauliPropBackend(samples=1)
    elseif name == "cpp_pauliengine"
        return CppPauliEngineBackend(samples=1)
    end
    throw(ArgumentError("unsupported backend: $name"))
end

function main(args)
    parsed = _parse_args(args)
    backend = _make_backend(parsed["backend"])
    spec = load_benchmark_spec(parsed["config"])
    # rudolph_eagle_127 keeps its dedicated per-angle propagate path; every
    # other family goes through run_backend_sweep (Julia: surrogate built once,
    # evaluated per angle; external backends: full re-propagation per angle).
    result = if spec.family == "rudolph_eagle_127"
        run_sweep(backend, spec)
    else
        run_backend_sweep(backend, spec)
    end
    println(JSON3.write(benchmark_sweep_result_dict(result)))
    return 0
end

try
    exit(main(ARGS))
catch err
    showerror(stderr, err)
    println(stderr)
    exit(1)
end
