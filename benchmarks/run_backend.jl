#!/usr/bin/env julia

using JSON3
using PPSBackendBench

function _usage()
    return "usage: julia --project=. benchmarks/run_backend.jl --backend julia_pauliprop --config configs/bench_small.toml"
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
        return JuliaPauliPropBackend()
    end
    throw(ArgumentError("unsupported backend: $name"))
end

function main(args)
    parsed = _parse_args(args)
    spec = load_benchmark_spec(parsed["config"])
    backend = _make_backend(parsed["backend"])
    result = run_backend(backend, spec)
    println(JSON3.write(benchmark_result_dict(result)))
    return 0
end

try
    exit(main(ARGS))
catch err
    showerror(stderr, err)
    println(stderr)
    exit(1)
end
