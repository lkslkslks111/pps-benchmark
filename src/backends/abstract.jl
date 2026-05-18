abstract type AbstractBackend end

function backend_name(backend::AbstractBackend)
    throw(MethodError(backend_name, (backend,)))
end

function run_backend(backend::AbstractBackend, spec::BenchmarkSpec)
    throw(MethodError(run_backend, (backend, spec)))
end
