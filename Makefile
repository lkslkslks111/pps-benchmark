JULIA = julia --project=.

.PHONY: instantiate test smoke smoke-eagle reproduce-rudolph-eagle benchmark-lowesa-127 bench-small clean

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
		'eagle_spec = load_benchmark_spec("configs/bench_eagle_127.toml")' \
		'eagle_circuit = export_circuit(eagle_spec)' \
		'@assert eagle_circuit.family == "ibm_eagle_tfi"' \
		'@assert eagle_circuit.nqubits == 127' \
		'@assert eagle_circuit.metadata["topology"] == "ibm_eagle"' \
		'@assert eagle_circuit.metadata["reference_paper"] == "IBM Nature 618, 500-505 (2023)"' \
		'@assert length(eagle_circuit.gates) == 271' \
		'@assert count(gate -> gate.paulis == ["Z", "Z"], eagle_circuit.gates) == 144' \
		'@assert count(gate -> gate.paulis == ["X"], eagle_circuit.gates) == 127' \
		'@assert all(0 <= q < 127 for gate in eagle_circuit.gates for q in gate.qubits)' \
		'eagle_result = run_backend(backend, eagle_circuit; circuit_source="eagle_127_test")' \
		'@assert eagle_result.success' \
		'@assert eagle_result.task_id == "ibm_eagle_127_tfi_l1_z0"' \
		'@assert eagle_result.metadata["circuit_source"] == "eagle_127_test"' \
		'@assert eagle_result.metadata["circuit_schema_version"] == "pps-circuit-v1"' \
		'@assert eagle_result.metadata["family"] == "ibm_eagle_tfi"' \
		'@assert eagle_result.metadata["nqubits"] == 127' \
		'rudolph_spec = load_benchmark_spec("configs/reproduce_rudolph_eagle_127.toml")' \
		'@assert rudolph_spec.family == "rudolph_eagle_127"' \
		'@assert rudolph_spec.nqubits == 127' \
		'@assert rudolph_spec.nlayers == 20' \
		'@assert rudolph_spec.observable == "Z62"' \
		'rudolph_circuit = export_circuit(rudolph_spec)' \
		'@assert rudolph_circuit.family == "rudolph_eagle_127"' \
		'@assert rudolph_circuit.metadata["topology"] == "ibm_eagle"' \
		'@assert rudolph_circuit.metadata["observable_julia_index"] == 63' \
		'@assert length(rudolph_circuit.gates) == 5420' \
		'@assert count(gate -> gate.paulis == ["Z", "Z"], rudolph_circuit.gates) == 2880' \
		'@assert count(gate -> gate.paulis == ["X"], rudolph_circuit.gates) == 2540' \
		'@assert count(gate -> gate.paulis == ["Z", "Z"] && isapprox(gate.theta, -pi / 2; atol=0.0, rtol=0.0), rudolph_circuit.gates) == 2880' \
		'@assert all(0 <= q < 127 for gate in rudolph_circuit.gates for q in gate.qubits)' \
		'angle_grid = rudolph_angle_grid(rudolph_spec)' \
		'@assert length(angle_grid) == 20' \
		'@assert isapprox(first(angle_grid), 0.0; atol=0.0, rtol=0.0)' \
		'@assert isapprox(last(angle_grid), pi / 2; atol=0.0, rtol=0.0)' \
		'reduced_sweep = run_sweep(backend, rudolph_spec; angle_indices=[10, 15, 20])' \
		'@assert reduced_sweep.backend == "julia_pauliprop"' \
		'@assert reduced_sweep.task_id == "rudolph_eagle_127_tfi_l20_z62_sweep"' \
		'@assert reduced_sweep.success' \
		'@assert length(reduced_sweep.results) == 3' \
		'@assert all(point -> point.success, reduced_sweep.results)' \
		'@assert all(point -> isfinite(point.expectation), reduced_sweep.results)' \
		'@assert all(point -> point.runtime_sec >= 0, reduced_sweep.results)' \
		'@assert all(point -> point.memory_bytes >= 0, reduced_sweep.results)' \
		'@assert all(point -> point.final_terms >= 0, reduced_sweep.results)' \
		'@assert reduced_sweep.metadata["angle_count"] == 20' \
		'@assert reduced_sweep.metadata["evaluated_angle_count"] == 3' \
		'@assert reduced_sweep.metadata["max_weight"] == 8' \
		'@assert reduced_sweep.metadata["min_abs_coeff"] == 1.0e-4' \
		'sweep_dict = benchmark_sweep_result_dict(reduced_sweep)' \
		'@assert length(sweep_dict["results"]) == 3' \
		'@assert sweep_dict["metadata"]["reference_arxiv"] == "https://arxiv.org/abs/2505.21606"' \
		'lowesa_spec = load_benchmark_spec("configs/lowesa_tfi_127_L5_mz.toml")' \
		'@assert lowesa_spec.family == "lowesa_tfi_127"' \
		'@assert lowesa_spec.nqubits == 127' \
		'@assert lowesa_spec.nlayers == 5' \
		'@assert lowesa_spec.observable == "Mz"' \
		'lowesa_circuit = export_circuit(lowesa_spec)' \
		'@assert lowesa_circuit.family == "lowesa_tfi_127"' \
		'@assert length(lowesa_circuit.gates) == 1355' \
		'@assert count(gate -> gate.paulis == ["X"], lowesa_circuit.gates) == 635' \
		'@assert count(gate -> gate.paulis == ["Z", "Z"], lowesa_circuit.gates) == 720' \
		'@assert count(gate -> gate.paulis == ["Z", "Z"] && isapprox(gate.theta, -pi / 2; atol=0.0, rtol=0.0), lowesa_circuit.gates) == 720' \
		'@assert all(0 <= q < 127 for gate in lowesa_circuit.gates for q in gate.qubits)' \
		'lowesa_angles = lowesa_angle_grid(lowesa_spec)' \
		'@assert length(lowesa_angles) == 158' \
		'@assert isapprox(first(lowesa_angles), 0.0; atol=0.0, rtol=0.0)' \
		'surrogate_sweep = run_surrogate_sweep(backend, lowesa_spec; angle_indices=[1, 80, 158], max_freq=6, max_weight=4)' \
		'@assert surrogate_sweep.backend == "julia_pauliprop"' \
		'@assert surrogate_sweep.task_id == "lowesa_tfi_127_l5_mz_sweep"' \
		'@assert surrogate_sweep.success' \
		'@assert length(surrogate_sweep.results) == 3' \
		'@assert all(point -> point.success, surrogate_sweep.results)' \
		'@assert all(point -> isfinite(point.expectation), surrogate_sweep.results)' \
		'@assert all(point -> isfinite(point.reference), surrogate_sweep.results)' \
		'@assert all(point -> point.absolute_error >= 0, surrogate_sweep.results)' \
		'@assert isapprox(surrogate_sweep.results[1].expectation, 1.0; atol=1.0e-6)' \
		'@assert surrogate_sweep.metadata["num_paths_kept"] > 0' \
		'@assert surrogate_sweep.metadata["num_paths_kept"] <= surrogate_sweep.metadata["num_paths_found"]' \
		'@assert surrogate_sweep.metadata["build_time_sec"] >= 0' \
		'@assert surrogate_sweep.metadata["eval_time_sec"] >= 0' \
		'@assert surrogate_sweep.metadata["peak_rss_bytes"] > 0' \
		'@assert isfinite(surrogate_sweep.metadata["rmse"])' \
		'@assert surrogate_sweep.metadata["max_freq"] == 6' \
		'@assert surrogate_sweep.metadata["max_weight"] == 4' \
		'@assert surrogate_sweep.metadata["angle_count"] == 158' \
		'@assert surrogate_sweep.metadata["evaluated_angle_count"] == 3' \
		'surrogate_dict = benchmark_sweep_result_dict(surrogate_sweep)' \
		'@assert length(surrogate_dict["results"]) == 3' \
		'@assert haskey(surrogate_dict["results"][1], "reference")' \
		'@assert haskey(surrogate_dict["results"][1], "absolute_error")' \
		'println("temporary smoke tests passed")' \
		> "$$tmp/runtests.jl"; \
	PPS_TEST_TMP="$$tmp" $(JULIA) "$$tmp/runtests.jl"

smoke:
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_backend.jl --backend julia_pauliprop --config configs/bench_small.toml

smoke-eagle:
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_backend.jl --backend julia_pauliprop --config configs/bench_eagle_127.toml

reproduce-rudolph-eagle:
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_sweep.jl --backend julia_pauliprop --config configs/reproduce_rudolph_eagle_127.toml

benchmark-lowesa-127:
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_sweep.jl --backend julia_pauliprop --config configs/lowesa_tfi_127_L5_mz.toml
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_sweep.jl --backend julia_pauliprop --config configs/lowesa_tfi_127_L5_z62.toml

bench-small:
	$(JULIA) benchmarks/run_all.jl --config configs/bench_small.toml

clean:
	rm -rf results/tmp/*
	rm -rf logs/tmp/*
