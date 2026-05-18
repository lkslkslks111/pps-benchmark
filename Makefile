JULIA = julia --project=.

.PHONY: instantiate test smoke bench-small clean

instantiate:
	$(JULIA) -e 'using Pkg; Pkg.instantiate()'

test:
	@tmp=$$(mktemp -d /tmp/pps-benchmark-test.XXXXXX); \
	trap 'rm -rf "$$tmp"' EXIT; \
	printf '%s\n' \
		'using PPSBackendBench' \
		'using PauliPropagation' \
		'using Test' \
		'spec = load_benchmark_spec("configs/bench_small.toml")' \
		'backend = JuliaPauliPropBackend(samples=2, evals=1)' \
		'circuit_description = export_circuit(spec)' \
		'@assert circuit_description.schema_version == "pps-circuit-v1"' \
		'@assert circuit_description.task_id == spec.task_id' \
		'@assert all(0 <= q < spec.nqubits for gate in circuit_description.gates for q in gate.qubits)' \
		'@assert length(circuit_description.gates) == countparameters(hardwareefficientcircuit(spec.nqubits, spec.nlayers))' \
		'circuit_json_path = joinpath(ENV["PPS_TEST_TMP"], "circuit.json")' \
		'write_circuit_description(circuit_json_path, circuit_description)' \
		'roundtrip = load_circuit_description(circuit_json_path)' \
		'@assert circuit_description_dict(roundtrip) == circuit_description_dict(circuit_description)' \
		'result = run_backend(backend, spec)' \
		'explicit_result = run_backend(backend, roundtrip)' \
		'direct_result = run_direct_builder(backend, spec)' \
		'@assert result.backend == "julia_pauliprop"' \
		'@assert result.task_id == "small_clifford_rotation_n4_l4_seed1"' \
		'@assert result.success' \
		'@assert explicit_result.success' \
		'@assert direct_result.success' \
		'@assert result.final_terms > 0' \
		'@assert result.runtime_sec >= 0' \
		'@assert result.memory_bytes >= 0' \
		'@assert isfinite(result.expectation)' \
		'@assert isfinite(result.reference)' \
		'@assert result.absolute_error >= 0' \
		'@assert isapprox(explicit_result.expectation, direct_result.expectation; atol=0.0, rtol=0.0)' \
		'@assert isapprox(explicit_result.reference, direct_result.reference; atol=0.0, rtol=0.0)' \
		'@assert isapprox(explicit_result.absolute_error, direct_result.absolute_error; atol=0.0, rtol=0.0)' \
		'@assert haskey(result.metadata, "benchmark_samples")' \
		'@assert haskey(result.metadata, "median_time_sec")' \
		'@assert haskey(result.metadata, "parameter_count")' \
		'@assert result.metadata["circuit_schema_version"] == "pps-circuit-v1"' \
		'@assert result.metadata["circuit_source"] == "exported_from_spec"' \
		'invalid_qubit = CircuitDescription("pps-circuit-v1", spec.task_id, spec.family, spec.seed, spec.nqubits, spec.observable, spec.truncation, spec.reference, [CircuitGate("pauli_rotation", ["X"], [spec.nqubits], 0.1)], Dict{String,Any}())' \
		'@test_throws ArgumentError run_backend(backend, invalid_qubit)' \
		'invalid_gate = CircuitDescription("pps-circuit-v1", spec.task_id, spec.family, spec.seed, spec.nqubits, spec.observable, spec.truncation, spec.reference, [CircuitGate("unknown", ["X"], [0], 0.1)], Dict{String,Any}())' \
		'@test_throws ArgumentError run_backend(backend, invalid_gate)' \
		'invalid_shape = CircuitDescription("pps-circuit-v1", spec.task_id, spec.family, spec.seed, spec.nqubits, spec.observable, spec.truncation, spec.reference, [CircuitGate("pauli_rotation", ["X", "Y"], [0], 0.1)], Dict{String,Any}())' \
		'@test_throws ArgumentError run_backend(backend, invalid_shape)' \
		'println("temporary smoke tests passed")' \
		> "$$tmp/runtests.jl"; \
	PPS_TEST_TMP="$$tmp" $(JULIA) "$$tmp/runtests.jl"

smoke:
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_backend.jl --backend julia_pauliprop --config configs/bench_small.toml

bench-small:
	$(JULIA) benchmarks/run_all.jl --config configs/bench_small.toml

clean:
	rm -rf results/tmp/*
	rm -rf logs/tmp/*
