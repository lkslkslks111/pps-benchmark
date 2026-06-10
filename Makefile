JULIA = julia --project=.

.PHONY: instantiate test smoke smoke-eagle reproduce-rudolph-eagle benchmark-lowesa-127 bench-small benchmark-medium clean \
	build-rust smoke-rust test-rust smoke-lowesa-127-rust benchmark-lowesa-127-rust \
	build-cuquantum smoke-cuquantum test-cuquantum smoke-lowesa-127-cuquantum benchmark-lowesa-127-cuquantum \
	build-cuda smoke-cuda test-cuda smoke-lowesa-127-cuda benchmark-lowesa-127-cuda \
	build-cpp smoke-cpp test-cpp smoke-lowesa-127-cpp benchmark-lowesa-127-cpp \
	benchmark-lowesa-127-all \
	remote-submit remote-collect remote-validate

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
		'@assert result.peak_terms isa Int' \
		'@assert result.peak_terms >= result.final_terms' \
		'@assert result.throughput_terms_per_sec > 0' \
		'@assert result.metadata["truncation_applied"]["method"] == "threshold"' \
		'@assert result.metadata["truncation_applied"]["coefficient_threshold"] == 1.0e-8' \
		'result_dict = benchmark_result_dict(result)' \
		'@assert haskey(result_dict, "peak_terms")' \
		'@assert haskey(result_dict, "throughput_terms_per_sec")' \
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
		'theta_h_test = pi / 4' \
		'circuit_at_angle = export_circuit_at_angle(lowesa_spec, theta_h_test)' \
		'@assert circuit_at_angle.family == "lowesa_tfi_127"' \
		'@assert length(circuit_at_angle.gates) == 1355' \
		'rx_gates = filter(g -> g.paulis == ["X"], circuit_at_angle.gates)' \
		'rzz_gates = filter(g -> g.paulis == ["Z", "Z"], circuit_at_angle.gates)' \
		'@assert all(isapprox(g.theta, theta_h_test; atol=0.0, rtol=0.0) for g in rx_gates)' \
		'@assert all(isapprox(g.theta, -pi / 2; atol=0.0, rtol=0.0) for g in rzz_gates)' \
		'sweep_via_alias = run_backend_sweep(backend, lowesa_spec; angle_indices=[1, 80, 158], max_freq=6, max_weight=4)' \
		'@assert sweep_via_alias.backend == "julia_pauliprop"' \
		'@assert sweep_via_alias.task_id == "lowesa_tfi_127_l5_mz_sweep"' \
		'@assert length(sweep_via_alias.results) == 3' \
		'@assert isapprox(sweep_via_alias.results[1].expectation, surrogate_sweep.results[1].expectation; atol=1e-12)' \
		'generic_spec = load_benchmark_spec("configs/sweep_medium.toml")' \
		'@assert generic_spec.family == "clifford_pauli_rotation"' \
		'generic_angles = generic_angle_grid(generic_spec)' \
		'@assert length(generic_angles) == 21' \
		'@assert isapprox(first(generic_angles), 0.0; atol=0.0, rtol=0.0)' \
		'@assert isapprox(last(generic_angles), pi / 2; atol=1e-12)' \
		'angle_desc = export_circuit_at_angle(generic_spec, 0.31)' \
		'@assert all(isapprox(g.theta, 0.31; atol=0.0, rtol=0.0) for g in angle_desc.gates)' \
		'@assert angle_desc.truncation["method"] == "threshold"' \
		'generic_sweep = run_surrogate_sweep(backend, generic_spec; angle_indices=[1, 11, 21], max_freq=10, max_weight=4)' \
		'@assert generic_sweep.success' \
		'@assert length(generic_sweep.results) == 3' \
		'@assert isapprox(generic_sweep.results[1].expectation, 1.0; atol=1e-10)' \
		'@assert all(point -> isfinite(point.expectation), generic_sweep.results)' \
		'@assert generic_sweep.metadata["sweep_rule"] == "correlated: every Pauli rotation = theta_h"' \
		'@assert generic_sweep.metadata["num_paths_kept"] > 0' \
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
	@mkdir -p results results/tmp
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_sweep.jl --backend julia_pauliprop --config configs/lowesa_tfi_127_L5_mz.toml > results/tmp/lowesa_tfi_127_L5_mz.json && mv results/tmp/lowesa_tfi_127_L5_mz.json results/lowesa_tfi_127_L5_mz.json
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_sweep.jl --backend julia_pauliprop --config configs/lowesa_tfi_127_L5_z62.toml > results/tmp/lowesa_tfi_127_L5_z62.json && mv results/tmp/lowesa_tfi_127_L5_z62.json results/lowesa_tfi_127_L5_z62.json

bench-small:
	$(JULIA) benchmarks/run_all.jl --config configs/bench_small.toml

# Cross-backend medium benchmark: run every locally available backend on
# configs/bench_medium.toml, then emit a comparison table + plots.
# The CUDA leg is skipped (with a notice) when cuquantum is not installed.
benchmark-medium: build-rust build-cpp
	@mkdir -p results results/tmp
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_backend.jl --backend julia_pauliprop --config configs/bench_medium.toml > results/tmp/medium_julia.json && mv results/tmp/medium_julia.json results/medium_julia.json
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_backend.jl --backend rust_pauliprop --config configs/bench_medium.toml > results/tmp/medium_rust.json && mv results/tmp/medium_rust.json results/medium_rust.json
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_backend.jl --backend cpp_pauliengine --config configs/bench_medium.toml > results/tmp/medium_cpp.json && mv results/tmp/medium_cpp.json results/medium_cpp.json
	@out=$$(JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_backend.jl --backend cuda_cupauliprop --config configs/bench_medium.toml 2>&1); \
	if [ $$? -eq 0 ]; then \
		echo "$$out" | tail -1 > results/tmp/medium_cuda.json && mv results/tmp/medium_cuda.json results/medium_cuda.json; \
	else \
		echo "SKIP: cuda_cupauliprop medium benchmark skipped (cuquantum unavailable)"; \
		rm -f results/medium_cuda.json; \
	fi
	@python3 scripts/compare_backends.py --out-prefix results/comparison_medium results/medium_*.json

wrappers/rust/.venv/.installed: wrappers/rust/requirements.txt
	@test -d wrappers/rust/.venv || python3 -m venv wrappers/rust/.venv
	@wrappers/rust/.venv/bin/pip install -q --upgrade pip
	@wrappers/rust/.venv/bin/pip install -q -r wrappers/rust/requirements.txt
	@touch $@

build-rust: wrappers/rust/.venv/.installed
	@PYO3_PYTHON=$(CURDIR)/wrappers/rust/.venv/bin/python \
		cargo build --release --manifest-path wrappers/rust/Cargo.toml

smoke-rust: build-rust
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_backend.jl --backend rust_pauliprop --config configs/bench_small.toml

smoke-lowesa-127-rust: build-rust
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_backend.jl --backend rust_pauliprop --config configs/lowesa_tfi_127_L5_mz.toml

benchmark-lowesa-127-rust: build-rust
	@mkdir -p results results/tmp
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_sweep.jl --backend rust_pauliprop --config configs/lowesa_tfi_127_L5_mz.toml > results/tmp/rust_lowesa_tfi_127_L5_mz.json && mv results/tmp/rust_lowesa_tfi_127_L5_mz.json results/rust_lowesa_tfi_127_L5_mz.json
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_sweep.jl --backend rust_pauliprop --config configs/lowesa_tfi_127_L5_z62.toml > results/tmp/rust_lowesa_tfi_127_L5_z62.json && mv results/tmp/rust_lowesa_tfi_127_L5_z62.json results/rust_lowesa_tfi_127_L5_z62.json

test-rust: build-rust
	@cargo test --manifest-path wrappers/rust/Cargo.toml --no-default-features --lib
	@tmp=$$(mktemp -d /tmp/pps-benchmark-rust-test.XXXXXX); \
	trap 'rm -rf "$$tmp"' EXIT; \
	printf '%s\n' \
		'using PPSBackendBench' \
		'using Test' \
		'spec = load_benchmark_spec("configs/bench_small.toml")' \
		'julia_backend = JuliaPauliPropBackend(samples=2, evals=1)' \
		'rust_backend = RustPauliPropBackend(samples=2)' \
		'julia_result = run_backend(julia_backend, spec)' \
		'rust_result = run_backend(rust_backend, spec)' \
		'@assert rust_result.backend == "rust_pauliprop"' \
		'@assert rust_result.task_id == julia_result.task_id' \
		'@assert rust_result.success' \
		'@assert rust_result.final_terms > 0' \
		'@assert rust_result.runtime_sec >= 0' \
		'@assert rust_result.memory_bytes >= 0' \
		'@assert rust_result.peak_terms === nothing' \
		'@assert rust_result.throughput_terms_per_sec > 0' \
		'@assert rust_result.metadata["truncation_applied"]["method"] == "threshold"' \
		'@assert isfinite(rust_result.expectation)' \
		'@assert isfinite(rust_result.reference)' \
		'@assert rust_result.absolute_error >= 0' \
		'@assert isapprox(rust_result.expectation, julia_result.expectation; atol=1e-6, rtol=0)' \
		'@assert isapprox(rust_result.reference, julia_result.reference; atol=1e-6, rtol=0)' \
		'@assert rust_result.metadata["engine"] == "qiskit_pauli_prop"' \
		'@assert haskey(rust_result.metadata, "pauli_prop_version")' \
		'@assert haskey(rust_result.metadata, "qiskit_version")' \
		'@assert haskey(rust_result.metadata, "median_time_sec")' \
		'@assert haskey(rust_result.metadata, "truncated_one_norm")' \
		'@assert rust_result.metadata["circuit_source"] == "exported_from_spec"' \
		'@assert rust_result.metadata["circuit_schema_version"] == "pps-circuit-v1"' \
		'desc = export_circuit(spec)' \
		'rust_explicit = run_backend(rust_backend, desc; circuit_source="circuit_json")' \
		'@assert rust_explicit.success' \
		'@assert rust_explicit.metadata["circuit_source"] == "circuit_json"' \
		'@assert isapprox(rust_explicit.expectation, julia_result.expectation; atol=1e-6, rtol=0)' \
		'missing_backend = RustPauliPropBackend(binary_path="/nonexistent/rust_pauliprop_runner", samples=2)' \
		'@test_throws ErrorException run_backend(missing_backend, spec)' \
		'mixed_gates = [CircuitGate("pauli_rotation", ["X","Z"], [1,2], 0.3), CircuitGate("pauli_rotation", ["Y","Z","X"], [0,2,3], 0.7)]' \
		'mixed_desc = CircuitDescription("pps-circuit-v1", "mixed_pauli_smoke", "synthetic", 42, 4, "Z0", Dict{String,Any}("method"=>"threshold","threshold"=>1.0e-10), Dict{String,Any}("source"=>"synthetic"), mixed_gates, Dict{String,Any}())' \
		'julia_mixed = run_backend(julia_backend, mixed_desc; circuit_source="circuit_json")' \
		'rust_mixed = run_backend(rust_backend, mixed_desc; circuit_source="circuit_json")' \
		'@assert rust_mixed.success' \
		'@assert rust_mixed.final_terms > 0' \
		'@assert isapprox(rust_mixed.expectation, julia_mixed.expectation; atol=1e-6, rtol=0)' \
		'@assert isapprox(rust_mixed.reference, julia_mixed.reference; atol=1e-6, rtol=0)' \
		'@assert rust_mixed.metadata["memory_measure"] == "process_peak_rss"' \
		'@assert haskey(rust_mixed.metadata, "thread_limits")' \
		'@assert rust_mixed.metadata["thread_limits"]["OMP_NUM_THREADS"] == "1"' \
		'println("rust_pauliprop comparison tests passed")' \
		> "$$tmp/runtests.jl"; \
	JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) "$$tmp/runtests.jl"

wrappers/python/.venv/.installed.cuquantum: wrappers/python/requirements_cuquantum.txt
	@test -d wrappers/python/.venv || python3 -m venv wrappers/python/.venv
	@wrappers/python/.venv/bin/pip install -q --upgrade pip
	@wrappers/python/.venv/bin/pip install -q -r wrappers/python/requirements_cuquantum.txt
	@touch $@

build-cuquantum: wrappers/python/.venv/.installed.cuquantum

smoke-cuquantum: build-cuquantum
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_backend.jl \
		--backend python_cuquantum --config configs/bench_small.toml

smoke-lowesa-127-cuquantum: build-cuquantum
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_backend.jl \
		--backend python_cuquantum --config configs/lowesa_tfi_127_L5_mz.toml

benchmark-lowesa-127-cuquantum: build-cuquantum
	@mkdir -p results results/tmp
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_sweep.jl --backend python_cuquantum --config configs/lowesa_tfi_127_L5_mz.toml > results/tmp/cuquantum_lowesa_tfi_127_L5_mz.json && mv results/tmp/cuquantum_lowesa_tfi_127_L5_mz.json results/cuquantum_lowesa_tfi_127_L5_mz.json
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_sweep.jl --backend python_cuquantum --config configs/lowesa_tfi_127_L5_z62.toml > results/tmp/cuquantum_lowesa_tfi_127_L5_z62.json && mv results/tmp/cuquantum_lowesa_tfi_127_L5_z62.json results/cuquantum_lowesa_tfi_127_L5_z62.json

test-cuquantum: build-cuquantum
	@tmp=$$(mktemp -d /tmp/pps-benchmark-cuquantum-test.XXXXXX); \
	trap 'rm -rf "$$tmp"' EXIT; \
	printf '%s\n' \
		'using PPSBackendBench' \
		'using Test' \
		'spec = load_benchmark_spec("configs/bench_small.toml")' \
		'julia_backend = JuliaPauliPropBackend(samples=2, evals=1)' \
		'cuq_backend = PythonCuQuantumBackend(samples=1)' \
		'julia_result = run_backend(julia_backend, spec)' \
		'cuq_result = run_backend(cuq_backend, spec)' \
		'@assert cuq_result.backend == "python_cuquantum"' \
		'@assert cuq_result.task_id == julia_result.task_id' \
		'@assert cuq_result.success' \
		'@assert cuq_result.final_terms >= 0' \
		'@assert cuq_result.runtime_sec >= 0' \
		'@assert cuq_result.memory_bytes >= 0' \
		'@assert isfinite(cuq_result.expectation)' \
		'@assert isfinite(cuq_result.reference)' \
		'@assert cuq_result.absolute_error >= 0' \
		'@assert isapprox(cuq_result.expectation, julia_result.expectation; atol=1e-6, rtol=0)' \
		'@assert cuq_result.metadata["engine"] == "cuquantum_pauliprop"' \
		'@assert haskey(cuq_result.metadata, "cuquantum_version")' \
		'@assert cuq_result.metadata["circuit_schema_version"] == "pps-circuit-v1"' \
		'missing_backend = PythonCuQuantumBackend(script_path="/nonexistent/cuquantum_runner.py")' \
		'@test_throws ErrorException run_backend(missing_backend, spec)' \
		'println("python_cuquantum comparison tests passed")' \
		> "$$tmp/runtests.jl"; \
	JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) "$$tmp/runtests.jl"

wrappers/cuda/.venv/.installed: wrappers/cuda/requirements.txt
	@test -d wrappers/cuda/.venv || python3 -m venv wrappers/cuda/.venv
	@wrappers/cuda/.venv/bin/pip install -q --upgrade pip
	@wrappers/cuda/.venv/bin/pip install -q -r wrappers/cuda/requirements.txt
	@touch $@

build-cuda: wrappers/cuda/.venv/.installed

smoke-cuda: build-cuda
	@out=$$(JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_backend.jl \
		--backend cuda_cupauliprop --config configs/bench_small.toml 2>&1); \
	status=$$?; \
	if [ $$status -eq 0 ]; then \
		echo "$$out"; \
	elif echo "$$out" | grep -qiE "cuquantum not available|No module named 'cuquantum|No module named cuquantum"; then \
		echo "SKIP: cuda_cupauliprop smoke skipped — cuquantum not installed"; \
		echo "$$out"; \
	else \
		echo "$$out"; \
		exit $$status; \
	fi

smoke-lowesa-127-cuda: build-cuda
	@out=$$(JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_backend.jl \
		--backend cuda_cupauliprop --config configs/lowesa_tfi_127_L5_mz.toml 2>&1); \
	status=$$?; \
	if [ $$status -eq 0 ]; then \
		echo "$$out"; \
	elif echo "$$out" | grep -qiE "cuquantum not available|No module named 'cuquantum|No module named cuquantum"; then \
		echo "SKIP: cuda_cupauliprop smoke skipped — cuquantum not installed"; \
		echo "$$out"; \
	else \
		echo "$$out"; \
		exit $$status; \
	fi

test-cuda: build-cuda
	@tmp=$$(mktemp -d /tmp/pps-benchmark-cuda-test.XXXXXX); \
	trap 'rm -rf "$$tmp"' EXIT; \
	printf '%s\n' \
		'using PPSBackendBench' \
		'using Test' \
		'spec = load_benchmark_spec("configs/bench_small.toml")' \
		'julia_backend = JuliaPauliPropBackend(samples=2, evals=1)' \
		'cuda_backend = CudaCuPauliPropBackend(samples=1)' \
		'julia_result = run_backend(julia_backend, spec)' \
		'cuda_result = run_backend(cuda_backend, spec)' \
		'@assert cuda_result.backend == "cuda_cupauliprop"' \
		'@assert cuda_result.task_id == julia_result.task_id' \
		'@assert cuda_result.success' \
		'@assert cuda_result.final_terms > 0' \
		'@assert cuda_result.runtime_sec >= 0' \
		'@assert cuda_result.memory_bytes >= 0' \
		'@assert isfinite(cuda_result.expectation)' \
		'@assert isfinite(cuda_result.reference)' \
		'@assert cuda_result.absolute_error >= 0' \
		'@assert isapprox(cuda_result.expectation, julia_result.expectation; atol=1e-6, rtol=0)' \
		'@assert cuda_result.metadata["engine"] == "cupauliprop"' \
		'@assert haskey(cuda_result.metadata, "cuquantum_version")' \
		'@assert cuda_result.metadata["circuit_schema_version"] == "pps-circuit-v1"' \
		'missing_backend = CudaCuPauliPropBackend(script_path="/nonexistent/runner.py")' \
		'@test_throws ErrorException run_backend(missing_backend, spec)' \
		'println("cuda_cupauliprop comparison tests passed")' \
		> "$$tmp/runtests.jl"; \
	JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) "$$tmp/runtests.jl"

wrappers/cpp/.venv/.installed: wrappers/cpp/requirements.txt
	@test -d wrappers/cpp/.venv || python3 -m venv wrappers/cpp/.venv
	@wrappers/cpp/.venv/bin/pip install -q --upgrade pip
	@wrappers/cpp/.venv/bin/pip install -q -r wrappers/cpp/requirements.txt 2>/dev/null || true
	@touch $@

build-cpp: wrappers/cpp/.venv/.installed

smoke-cpp: build-cpp
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_backend.jl \
		--backend cpp_pauliengine --config configs/bench_small.toml

smoke-lowesa-127-cpp: build-cpp
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_backend.jl \
		--backend cpp_pauliengine --config configs/lowesa_tfi_127_L5_mz.toml

benchmark-lowesa-127-cpp: build-cpp
	@mkdir -p results results/tmp
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_sweep.jl --backend cpp_pauliengine --config configs/lowesa_tfi_127_L5_mz.toml > results/tmp/cpp_lowesa_tfi_127_L5_mz.json && mv results/tmp/cpp_lowesa_tfi_127_L5_mz.json results/cpp_lowesa_tfi_127_L5_mz.json
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_sweep.jl --backend cpp_pauliengine --config configs/lowesa_tfi_127_L5_z62.toml > results/tmp/cpp_lowesa_tfi_127_L5_z62.json && mv results/tmp/cpp_lowesa_tfi_127_L5_z62.json results/cpp_lowesa_tfi_127_L5_z62.json

test-cpp: build-cpp
	@tmp=$$(mktemp -d /tmp/pps-benchmark-cpp-test.XXXXXX); \
	trap 'rm -rf "$$tmp"' EXIT; \
	printf '%s\n' \
		'using PPSBackendBench' \
		'using Test' \
		'spec = load_benchmark_spec("configs/bench_small.toml")' \
		'julia_backend = JuliaPauliPropBackend(samples=2, evals=1)' \
		'cpp_backend = CppPauliEngineBackend(samples=1)' \
		'julia_result = run_backend(julia_backend, spec)' \
		'cpp_result = run_backend(cpp_backend, spec)' \
		'@assert cpp_result.backend == "cpp_pauliengine"' \
		'@assert cpp_result.task_id == julia_result.task_id' \
		'@assert cpp_result.success' \
		'@assert cpp_result.final_terms > 0' \
		'@assert cpp_result.runtime_sec >= 0' \
		'@assert cpp_result.memory_bytes >= 0' \
		'@assert cpp_result.peak_terms isa Int' \
		'@assert cpp_result.peak_terms >= cpp_result.final_terms' \
		'@assert cpp_result.throughput_terms_per_sec > 0' \
		'@assert cpp_result.metadata["truncation_applied"]["method"] == "threshold"' \
		'@assert isfinite(cpp_result.expectation)' \
		'@assert isfinite(cpp_result.reference)' \
		'@assert cpp_result.absolute_error >= 0' \
		'@assert isapprox(cpp_result.expectation, julia_result.expectation; atol=1e-6, rtol=0)' \
		'@assert cpp_result.metadata["engine"] == "pauliengine"' \
		'@assert haskey(cpp_result.metadata, "pauliengine_version")' \
		'@assert cpp_result.metadata["circuit_schema_version"] == "pps-circuit-v1"' \
		'missing_backend = CppPauliEngineBackend(script_path="/nonexistent/pauliengine_runner.py")' \
		'@test_throws ErrorException run_backend(missing_backend, spec)' \
		'println("cpp_pauliengine comparison tests passed")' \
		> "$$tmp/runtests.jl"; \
	JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) "$$tmp/runtests.jl"

benchmark-lowesa-127-cuda: build-cuda
	@mkdir -p results results/tmp
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_sweep.jl --backend cuda_cupauliprop --config configs/lowesa_tfi_127_L5_mz.toml > results/tmp/cuda_lowesa_tfi_127_L5_mz.json && mv results/tmp/cuda_lowesa_tfi_127_L5_mz.json results/cuda_lowesa_tfi_127_L5_mz.json
	@JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA) benchmarks/run_sweep.jl --backend cuda_cupauliprop --config configs/lowesa_tfi_127_L5_z62.toml > results/tmp/cuda_lowesa_tfi_127_L5_z62.json && mv results/tmp/cuda_lowesa_tfi_127_L5_z62.json results/cuda_lowesa_tfi_127_L5_z62.json

benchmark-lowesa-127-all: benchmark-lowesa-127 benchmark-lowesa-127-rust benchmark-lowesa-127-cpp benchmark-lowesa-127-cuda benchmark-lowesa-127-cuquantum

clean:
	rm -rf results/tmp/*
	rm -rf logs/tmp/*

# ── Remote verification pipeline ─────────────────────────────────────────────
# Usage:
#   make remote-submit  CLUSTER=<host> [REMOTE_PATH=~/pps-benchmark]
#   make remote-collect CLUSTER=<host> [REMOTE_PATH=~/pps-benchmark]
#   make remote-validate                [RESULTS_DIR=results/remote]
#
# Workflow:
#   1. remote-submit  — ssh to cluster, git pull, qsub run_lowesa127_all.pbs
#   2. (wait for PBS job to finish — check with: ssh CLUSTER qstat)
#   3. remote-collect — rsync results/ and logs/ back from cluster
#   4. remote-validate — compare all backend results against reference thresholds

CLUSTER     ?=
REMOTE_PATH ?= ~/pps-benchmark
RESULTS_DIR ?= results/remote

remote-submit:
	@test -n "$(CLUSTER)" || (echo "Usage: make remote-submit CLUSTER=<host> [REMOTE_PATH=<path>]" && exit 1)
	ssh $(CLUSTER) "cd $(REMOTE_PATH) && git pull && mkdir -p results logs && qsub scripts/run_lowesa127_all.pbs" \
	    | tee logs/remote_jobs.txt
	@echo "Job ID recorded in logs/remote_jobs.txt"
	@echo "Monitor with: ssh $(CLUSTER) qstat"

remote-collect:
	@test -n "$(CLUSTER)" || (echo "Usage: make remote-collect CLUSTER=<host> [REMOTE_PATH=<path>]" && exit 1)
	mkdir -p results/remote logs/remote
	rsync -av $(CLUSTER):$(REMOTE_PATH)/results/ results/remote/
	rsync -av $(CLUSTER):$(REMOTE_PATH)/logs/ logs/remote/

remote-validate:
	python3 scripts/validate_lowesa127.py --results-dir $(RESULTS_DIR)
