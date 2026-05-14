JULIA = julia --project=.

.PHONY: instantiate test smoke bench-small clean

instantiate:
	$(JULIA) -e 'using Pkg; Pkg.instantiate()'

test:
	$(JULIA) -e 'using Pkg; Pkg.test()'

smoke:
	$(JULIA) benchmarks/run_backend.jl --backend julia_pauliprop --config configs/bench_small.toml

bench-small:
	$(JULIA) benchmarks/run_all.jl --config configs/bench_small.toml

clean:
	rm -rf results/tmp/*
	rm -rf logs/tmp/*
