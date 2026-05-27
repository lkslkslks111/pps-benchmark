#!/usr/bin/env julia

using JSON3
using PPSBackendBench

function _usage()
    return "usage: julia --project=. benchmarks/run_backend.jl --backend julia_pauliprop --config configs/bench_small.toml [--circuit circuit.json]"
end

function _parse_args(args)
    parsed = Dict{String,String}()
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg in ("--backend", "--config", "--circuit")
            i < length(args) || throw(ArgumentError("missing value for $arg"))
            parsed[arg[3:end]] = args[i + 1]
            i += 2
        else
            throw(ArgumentError("unknown argument: $arg"))
        end
    end

    haskey(parsed, "backend") || throw(ArgumentError("missing --backend; $(_usage())"))
    (haskey(parsed, "config") || haskey(parsed, "circuit")) ||
        throw(ArgumentError("missing --config or --circuit; $(_usage())"))
    return parsed
end

function _make_backend(name::AbstractString)
    if name == "julia_pauliprop"
        return JuliaPauliPropBackend()
    elseif name == "rust_pauliprop"
        return RustPauliPropBackend()
    elseif name == "python_cuquantum"
        return PythonCuQuantumBackend()
    elseif name == "cuda_cupauliprop"
        return CudaCuPauliPropBackend()
    elseif name == "cpp_pauliengine"
        return CppPauliEngineBackend()
    end
    throw(ArgumentError("unsupported backend: $name"))
end

function main(args)
    parsed = _parse_args(args)
    backend = _make_backend(parsed["backend"])
    result = if haskey(parsed, "circuit")
        circuit_description = load_circuit_description(parsed["circuit"])
        run_backend(backend, circuit_description; circuit_source="circuit_json")
    else
        spec = load_benchmark_spec(parsed["config"])
        run_backend(backend, spec)
    end
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
