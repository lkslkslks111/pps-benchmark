//! `rust_pauliprop_runner` — the Rust / Qiskit pauli-prop benchmark backend.
//!
//! Reads a `pps-circuit-v1` circuit JSON, propagates the observable through the
//! circuit via the embedded `pauli_prop` Python API, and prints a single-line
//! `BenchmarkResult` JSON to stdout. Any failure goes to stderr with exit 1.
//!
//! Usage: `rust_pauliprop_runner --circuit <path> [--samples <n>]`

mod propagate;

use std::collections::BTreeMap;

use serde_json::Value;

use rust_pauliprop::circuit;
use rust_pauliprop::result::BenchmarkResult;

const BACKEND_NAME: &str = "rust_pauliprop";
const DEFAULT_SAMPLES: usize = 5;

fn main() {
    match run() {
        Ok(line) => println!("{line}"),
        Err(message) => {
            eprintln!("rust_pauliprop_runner: {message}");
            std::process::exit(1);
        }
    }
}

fn run() -> Result<String, String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (circuit_path, samples) = parse_args(&args)?;

    let json = std::fs::read_to_string(&circuit_path)
        .map_err(|e| format!("cannot read circuit file '{circuit_path}': {e}"))?;
    let description = circuit::parse_circuit(&json)?;

    // Single-core benchmark policy: cap thread pools before any Python or BLAS
    // library initialises (they latch the value at first use).
    let thread_limits = enforce_single_core_threads();

    // The embedded interpreter reads PYTHONPATH at initialisation, so the bundled
    // venv must be on it before the first `Python::with_gil` call.
    configure_python_path();
    let outcome = propagate::propagate(&description, samples)?;

    let mut metadata: BTreeMap<String, Value> = BTreeMap::new();
    metadata.insert("engine".into(), Value::from("qiskit_pauli_prop"));
    metadata.insert(
        "pauli_prop_version".into(),
        Value::from(outcome.pauli_prop_version),
    );
    metadata.insert("qiskit_version".into(), Value::from(outcome.qiskit_version));
    metadata.insert("benchmark_samples".into(), Value::from(samples));
    metadata.insert(
        "minimum_time_sec".into(),
        Value::from(outcome.minimum_time_sec),
    );
    metadata.insert(
        "median_time_sec".into(),
        Value::from(outcome.median_time_sec),
    );
    metadata.insert(
        "truncated_one_norm".into(),
        Value::from(outcome.truncated_one_norm),
    );
    metadata.insert(
        "circuit_size".into(),
        Value::from(description.gates.len()),
    );
    metadata.insert(
        "truncation_threshold".into(),
        Value::from(outcome.threshold),
    );
    metadata.insert(
        "truncation_applied".into(),
        serde_json::json!({
            "method": "threshold",
            "coefficient_threshold": outcome.threshold,
            "max_terms": outcome.max_terms,
            "pauli_weight_cutoff": null,
            "max_freq": null,
            "max_weight": null,
        }),
    );
    metadata.insert(
        "observable".into(),
        Value::from(description.observable.clone()),
    );
    metadata.insert("circuit_source".into(), Value::from("circuit_json"));
    metadata.insert("family".into(), Value::from(description.family.clone()));
    metadata.insert("nqubits".into(), Value::from(description.nqubits));
    metadata.insert(
        "circuit_schema_version".into(),
        Value::from(description.schema_version.clone()),
    );
    metadata.insert(
        "thread_limits".into(),
        serde_json::to_value(&thread_limits)
            .map_err(|e| format!("could not serialise thread_limits: {e}"))?,
    );
    // The Julia backend reports BenchmarkTools allocation bytes; this runner
    // reports the whole-process VmHWM. `memory_measure` marks the difference so
    // downstream tooling can avoid cross-backend `memory_bytes` comparisons.
    metadata.insert(
        "memory_measure".into(),
        Value::from("process_peak_rss"),
    );

    let throughput = if outcome.median_time_sec > 0.0 {
        Some(outcome.final_terms as f64 / outcome.median_time_sec)
    } else {
        None
    };

    let result = BenchmarkResult {
        backend: BACKEND_NAME.to_string(),
        task_id: description.task_id.clone(),
        success: true,
        runtime_sec: outcome.median_time_sec,
        memory_bytes: outcome.memory_bytes,
        final_terms: outcome.final_terms,
        // pauli-prop propagates the whole circuit in one opaque Python call;
        // intermediate term counts are not observable from this runner.
        peak_terms: None,
        throughput_terms_per_sec: throughput,
        expectation: outcome.expectation,
        reference: outcome.reference,
        absolute_error: (outcome.expectation - outcome.reference).abs(),
        metadata,
    };
    result.to_json_line()
}

/// Force every thread-pool variable that numpy/BLAS/qiskit/pauli-prop read at
/// import time to "1", unless the caller has set them explicitly. The returned
/// map records the resolved value of each variable for benchmark metadata.
fn enforce_single_core_threads() -> BTreeMap<String, String> {
    const VARS: &[&str] = &[
        "OMP_NUM_THREADS",
        "OPENBLAS_NUM_THREADS",
        "MKL_NUM_THREADS",
        "VECLIB_MAXIMUM_THREADS",
        "NUMEXPR_NUM_THREADS",
        "RAYON_NUM_THREADS",
    ];
    let mut resolved = BTreeMap::new();
    for var in VARS {
        if std::env::var_os(var).is_none() {
            std::env::set_var(var, "1");
        }
        let value = std::env::var(var).unwrap_or_else(|_| "1".to_string());
        resolved.insert((*var).to_string(), value);
    }
    resolved
}

/// Make `pauli-prop` importable from the embedded interpreter.
///
/// Resolution order:
/// 1. `RUST_PAULIPROP_SITE_PACKAGES` (an absolute site-packages path).
/// 2. The bundled venv next to the binary at `wrappers/rust/.venv`, discovered
///    by walking three parents up from the binary.
///
/// In either case the path is prepended to `PYTHONPATH` (existing value kept).
fn configure_python_path() {
    let extra = std::env::var_os("RUST_PAULIPROP_SITE_PACKAGES")
        .map(std::path::PathBuf::from)
        .or_else(find_bundled_site_packages);

    let Some(extra) = extra else { return };
    let mut combined = std::ffi::OsString::from(&extra);
    if let Some(existing) = std::env::var_os("PYTHONPATH") {
        combined.push(":");
        combined.push(existing);
    }
    std::env::set_var("PYTHONPATH", combined);
}

fn find_bundled_site_packages() -> Option<std::path::PathBuf> {
    // exe: .../wrappers/rust/target/release/rust_pauliprop_runner
    // crate root: .../wrappers/rust
    let exe = std::env::current_exe().ok()?;
    let crate_root = exe.parent()?.parent()?.parent()?;
    let venv_lib = crate_root.join(".venv").join("lib");
    for entry in std::fs::read_dir(venv_lib).ok()?.flatten() {
        let name = entry.file_name();
        if name.to_string_lossy().starts_with("python") {
            let site = entry.path().join("site-packages");
            if site.is_dir() {
                return Some(site);
            }
        }
    }
    None
}

/// Parse `--circuit <path>` (required) and `--samples <n>` (optional).
fn parse_args(args: &[String]) -> Result<(String, usize), String> {
    let usage = "usage: rust_pauliprop_runner --circuit <path> [--samples <n>]";
    let mut circuit_path: Option<String> = None;
    let mut samples = DEFAULT_SAMPLES;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--circuit" => {
                let value = args
                    .get(i + 1)
                    .ok_or_else(|| format!("missing value for --circuit; {usage}"))?;
                circuit_path = Some(value.clone());
                i += 2;
            }
            "--samples" => {
                let value = args
                    .get(i + 1)
                    .ok_or_else(|| format!("missing value for --samples; {usage}"))?;
                samples = value
                    .parse::<usize>()
                    .map_err(|_| format!("--samples must be a positive integer; {usage}"))?;
                i += 2;
            }
            other => return Err(format!("unknown argument: {other}; {usage}")),
        }
    }

    if samples == 0 {
        return Err(format!("--samples must be greater than 0; {usage}"));
    }
    let circuit_path = circuit_path.ok_or_else(|| format!("missing --circuit; {usage}"))?;
    Ok((circuit_path, samples))
}
