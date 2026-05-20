//! PyO3 layer: embeds CPython and drives the `pauli_prop` Python API to
//! propagate the observable through the circuit in the Heisenberg frame.
//!
//! Rust owns orchestration, timing, and memory measurement; Python performs the
//! propagation (`pauli_prop.propagate_through_circuit`) and the diagonal-term
//! reduction that yields the `<0|O|0>` expectation value.

use pyo3::prelude::*;
use pyo3::types::{PyDict, PyModule};
use std::time::Instant;

use rust_pauliprop::circuit::{self, CircuitDescription};
use rust_pauliprop::gatemap::{classify, GateOp};

/// No practical cap on the term count — truncation is driven by `atol`.
const MAX_TERMS: i64 = 100_000_000;

/// Python helper: reduce an evolved `SparsePauliOp` to `<0|O|0>` (sum of the
/// coefficients of fully diagonal Pauli terms) and report its term count.
const HELPER_SOURCE: &str = r#"
import numpy as np


def summarize(op):
    mask = ~op.paulis.x.any(axis=1)
    overlap = float(np.real(np.asarray(op.coeffs)[mask].sum()))
    return (overlap, int(op.size))
"#;

/// Result of propagating one circuit: numbers the runner turns into a result.
pub struct PropagationOutcome {
    pub expectation: f64,
    pub reference: f64,
    pub final_terms: i64,
    pub minimum_time_sec: f64,
    pub median_time_sec: f64,
    pub truncated_one_norm: f64,
    pub memory_bytes: i64,
    pub threshold: f64,
    pub pauli_prop_version: String,
    pub qiskit_version: String,
}

/// Propagate the observable through the circuit, timing `samples` truncated
/// runs and one exact (`atol = 0`) reference run.
pub fn propagate(
    description: &CircuitDescription,
    samples: usize,
) -> Result<PropagationOutcome, String> {
    let threshold = circuit::truncation_threshold(description)?;
    let (symbol, index) =
        circuit::parse_observable(&description.observable, description.nqubits)?;

    Python::with_gil(|py| {
        run_in_py(py, description, samples, threshold, symbol, index)
            .map_err(|e| format!("pauli_prop propagation failed: {e}"))
    })
}

fn run_in_py(
    py: Python<'_>,
    description: &CircuitDescription,
    samples: usize,
    threshold: f64,
    symbol: char,
    index: i64,
) -> PyResult<PropagationOutcome> {
    let qc = build_circuit(py, description)?;
    let pauli_prop = py.import_bound("pauli_prop")?;
    let propagate_fn = pauli_prop.getattr("propagate_through_circuit")?;
    let helper = PyModule::from_code_bound(py, HELPER_SOURCE, "pp_helper.py", "pp_helper")?;
    let summarize = helper.getattr("summarize")?;

    // Truncated runs — timed.
    let mut durations: Vec<f64> = Vec::with_capacity(samples);
    let mut last = None;
    for _ in 0..samples {
        let observable = build_observable(py, symbol, index, description.nqubits)?;
        let started = Instant::now();
        let tuple = propagate_fn.call(
            (observable, qc.clone()),
            Some(&propagation_kwargs(py, threshold)?),
        )?;
        durations.push(started.elapsed().as_secs_f64());
        last = Some(tuple);
    }
    let truncated = last.expect("samples >= 1 guaranteed by the caller");
    let truncated_one_norm: f64 = truncated.get_item(1)?.extract()?;
    let (expectation, final_terms): (f64, i64) =
        summarize.call1((truncated.get_item(0)?,))?.extract()?;

    // Exact reference run — no truncation.
    let observable = build_observable(py, symbol, index, description.nqubits)?;
    let exact = propagate_fn.call(
        (observable, qc.clone()),
        Some(&propagation_kwargs(py, 0.0)?),
    )?;
    let (reference, _): (f64, i64) = summarize.call1((exact.get_item(0)?,))?.extract()?;

    durations.sort_by(|a, b| a.partial_cmp(b).expect("durations are finite"));

    Ok(PropagationOutcome {
        expectation,
        reference,
        final_terms,
        minimum_time_sec: durations[0],
        median_time_sec: median(&durations),
        truncated_one_norm,
        memory_bytes: peak_rss_bytes(),
        threshold,
        pauli_prop_version: pip_version(py, "pauli-prop"),
        qiskit_version: version_of(py.import_bound("qiskit")?.as_any()),
    })
}

/// Keyword arguments for `propagate_through_circuit` (Heisenberg frame).
fn propagation_kwargs(py: Python<'_>, atol: f64) -> PyResult<Bound<'_, PyDict>> {
    let kwargs = PyDict::new_bound(py);
    kwargs.set_item("max_terms", MAX_TERMS)?;
    kwargs.set_item("atol", atol)?;
    kwargs.set_item("frame", "h")?;
    Ok(kwargs)
}

/// Build the single-term observable as a `qiskit` `SparsePauliOp`.
fn build_observable<'py>(
    py: Python<'py>,
    symbol: char,
    index: i64,
    nqubits: i64,
) -> PyResult<Bound<'py, PyAny>> {
    let quantum_info = py.import_bound("qiskit.quantum_info")?;
    let kwargs = PyDict::new_bound(py);
    kwargs.set_item("num_qubits", nqubits)?;
    let sparse_list = vec![(symbol.to_string(), vec![index], 1.0_f64)];
    quantum_info
        .getattr("SparsePauliOp")?
        .call_method("from_sparse_list", (sparse_list,), Some(&kwargs))
}

/// Build a `qiskit` `QuantumCircuit` from the `pps-circuit-v1` gate list.
fn build_circuit<'py>(
    py: Python<'py>,
    description: &CircuitDescription,
) -> PyResult<Bound<'py, PyAny>> {
    let qc = py
        .import_bound("qiskit")?
        .getattr("QuantumCircuit")?
        .call1((description.nqubits,))?;

    for gate in &description.gates {
        match classify(gate) {
            GateOp::Single { axis, qubit, theta } => {
                qc.call_method1(format!("r{axis}").as_str(), (theta, qubit))?;
            }
            GateOp::Double {
                axis,
                q0,
                q1,
                theta,
            } => {
                qc.call_method1(format!("r{axis}{axis}").as_str(), (theta, q0, q1))?;
            }
            GateOp::General {
                label,
                qubits,
                theta,
            } => {
                let evolution = build_pauli_evolution(py, &label, qubits.len(), theta)?;
                qc.call_method1("append", (evolution, qubits))?;
            }
        }
    }
    Ok(qc)
}

/// Build a `PauliEvolutionGate` for a general (mixed / >2 qubit) Pauli rotation.
/// `PauliEvolutionGate(P, time=t) = exp(-i*t*P)`, so `t = theta/2` reproduces the
/// `exp(-i*theta/2*P)` convention of `pps-circuit-v1`.
fn build_pauli_evolution<'py>(
    py: Python<'py>,
    label: &str,
    nqubits: usize,
    theta: f64,
) -> PyResult<Bound<'py, PyAny>> {
    let local_qubits: Vec<i64> = (0..nqubits as i64).collect();
    let op_kwargs = PyDict::new_bound(py);
    op_kwargs.set_item("num_qubits", nqubits as i64)?;
    let operator = py
        .import_bound("qiskit.quantum_info")?
        .getattr("SparsePauliOp")?
        .call_method(
            "from_sparse_list",
            (vec![(label.to_string(), local_qubits, 1.0_f64)],),
            Some(&op_kwargs),
        )?;

    let gate_kwargs = PyDict::new_bound(py);
    gate_kwargs.set_item("time", theta / 2.0)?;
    py.import_bound("qiskit.circuit.library")?
        .getattr("PauliEvolutionGate")?
        .call((operator,), Some(&gate_kwargs))
}

fn version_of(module: &Bound<'_, PyAny>) -> String {
    module
        .getattr("__version__")
        .and_then(|v| v.extract::<String>())
        .unwrap_or_default()
}

/// `importlib.metadata.version(<dist>)`, for packages without a `__version__`.
fn pip_version(py: Python<'_>, distribution: &str) -> String {
    py.import_bound("importlib.metadata")
        .and_then(|m| m.call_method1("version", (distribution,)))
        .and_then(|v| v.extract::<String>())
        .unwrap_or_default()
}

fn median(sorted: &[f64]) -> f64 {
    let n = sorted.len();
    if n % 2 == 1 {
        sorted[n / 2]
    } else {
        (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }
}

/// Peak resident set size of this process, in bytes (Linux `/proc/self/status`).
fn peak_rss_bytes() -> i64 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|status| {
            status
                .lines()
                .find(|line| line.starts_with("VmHWM:"))
                .and_then(|line| line.split_whitespace().nth(1))
                .and_then(|kb| kb.parse::<i64>().ok())
        })
        .map(|kb| kb * 1024)
        .unwrap_or(0)
}
