module PPSBackendBench

include("io/schema.jl")
include("backends/abstract.jl")
include("backends/julia_pauliprop.jl")

export AbstractBackend,
    BenchmarkResult,
    BenchmarkSpec,
    BenchmarkSweepPoint,
    BenchmarkSweepResult,
    CircuitDescription,
    CircuitGate,
    JuliaPauliPropBackend,
    backend_name,
    benchmark_result_dict,
    benchmark_sweep_result_dict,
    circuit_description_dict,
    export_circuit,
    load_benchmark_spec,
    load_circuit_description,
    rudolph_angle_grid,
    run_backend,
    run_direct_builder,
    run_sweep,
    write_circuit_description

end
