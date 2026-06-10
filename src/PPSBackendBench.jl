module PPSBackendBench

include("io/schema.jl")
include("backends/abstract.jl")
include("backends/julia_pauliprop.jl")
include("backends/rust_pauliprop.jl")
include("backends/python_cuquantum.jl")
include("backends/cuda_cupauliprop.jl")
include("backends/cpp_pauliengine.jl")

export AbstractBackend,
    BenchmarkResult,
    BenchmarkSpec,
    BenchmarkSweepPoint,
    BenchmarkSweepResult,
    CircuitDescription,
    CircuitGate,
    CppPauliEngineBackend,
    CudaCuPauliPropBackend,
    JuliaPauliPropBackend,
    PythonCuQuantumBackend,
    RustPauliPropBackend,
    backend_name,
    benchmark_result_dict,
    benchmark_sweep_result_dict,
    circuit_description_dict,
    export_circuit,
    export_circuit_at_angle,
    load_benchmark_spec,
    load_circuit_description,
    lowesa_angle_grid,
    lowesa_reference_curve,
    reference_curve_path,
    rudolph_angle_grid,
    run_backend,
    run_backend_sweep,
    run_direct_builder,
    run_external_backend_sweep,
    run_surrogate_sweep,
    run_sweep,
    write_circuit_description

end
