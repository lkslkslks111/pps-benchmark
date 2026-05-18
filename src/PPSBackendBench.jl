module PPSBackendBench

include("io/schema.jl")
include("backends/abstract.jl")
include("backends/julia_pauliprop.jl")

export AbstractBackend,
    BenchmarkResult,
    BenchmarkSpec,
    JuliaPauliPropBackend,
    backend_name,
    benchmark_result_dict,
    load_benchmark_spec,
    run_backend

end
