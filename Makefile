JULIA = julia --project=.

.PHONY: instantiate test smoke bench-small clean

instantiate:
	$(JULIA) -e 'using Pkg; Pkg.instantiate()'

test:
	@tmp=$$(mktemp -d /tmp/pps-benchmark-test.XXXXXX); \
	trap 'rm -rf "$$tmp"' EXIT; \
	printf '%s\n' \
		'using PPSBackendBench' \
		'spec = load_benchmark_spec("configs/bench_small.toml")' \
		'backend = JuliaPauliPropBackend(samples=2, evals=1)' \
		'result = run_backend(backend, spec)' \
		'@assert result.backend == "julia_pauliprop"' \
		'@assert result.task_id == "small_clifford_rotation_n4_l4_seed1"' \
		'@assert result.success' \
		'@assert result.final_terms > 0' \
		'@assert result.runtime_sec >= 0' \
		'@assert result.memory_bytes >= 0' \
		'@assert isfinite(result.expectation)' \
		'@assert isfinite(result.reference)' \
		'@assert result.absolute_error >= 0' \
		'@assert haskey(result.metadata, "benchmark_samples")' \
		'@assert haskey(result.metadata, "median_time_sec")' \
		'@assert haskey(result.metadata, "parameter_count")' \
		'println("temporary smoke tests passed")' \
		> "$$tmp/runtests.jl"; \
	$(JULIA) "$$tmp/runtests.jl"

smoke:
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_backend.jl --backend julia_pauliprop --config configs/bench_small.toml

bench-small:
	$(JULIA) benchmarks/run_all.jl --config configs/bench_small.toml

clean:
	rm -rf results/tmp/*
	rm -rf logs/tmp/*
