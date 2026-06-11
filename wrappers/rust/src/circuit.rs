//! Parsing and validation of the `pps-circuit-v1` circuit exchange format.
//!
//! Mirrors the validation in the Julia orchestration layer
//! (`src/io/schema.jl::_validate_circuit_description`). The runner consumes the
//! explicit `gates` list and never rebuilds a circuit from the task spec.

use serde::Deserialize;
use serde_json::Value;

pub const SCHEMA_VERSION: &str = "pps-circuit-v1";
pub const GATE_TYPE_PAULI_ROTATION: &str = "pauli_rotation";
const SUPPORTED_PAULIS: [&str; 4] = ["I", "X", "Y", "Z"];

/// A single gate from the exchange format. Phase 1 supports only Pauli rotations.
#[derive(Debug, Clone, Deserialize)]
pub struct CircuitGate {
    #[serde(rename = "type")]
    pub gate_type: String,
    pub paulis: Vec<String>,
    pub qubits: Vec<i64>,
    pub theta: f64,
}

/// A full `pps-circuit-v1` circuit description.
#[derive(Debug, Clone, Deserialize)]
pub struct CircuitDescription {
    pub schema_version: String,
    pub task_id: String,
    pub family: String,
    pub seed: i64,
    pub nqubits: i64,
    pub observable: String,
    pub truncation: Value,
    pub reference: Value,
    pub gates: Vec<CircuitGate>,
    pub metadata: Value,
}

/// Parse and validate a `pps-circuit-v1` JSON document.
pub fn parse_circuit(json: &str) -> Result<CircuitDescription, String> {
    let description: CircuitDescription =
        serde_json::from_str(json).map_err(|e| format!("invalid circuit JSON: {e}"))?;
    validate(&description)?;
    Ok(description)
}

/// Validate a parsed circuit description against the `pps-circuit-v1` rules.
pub fn validate(description: &CircuitDescription) -> Result<(), String> {
    if description.schema_version != SCHEMA_VERSION {
        return Err(format!(
            "unsupported circuit schema version: {}",
            description.schema_version
        ));
    }
    if description.nqubits <= 0 {
        return Err("nqubits must be positive".to_string());
    }

    for (idx, gate) in description.gates.iter().enumerate() {
        let gate_no = idx + 1;
        if gate.gate_type != GATE_TYPE_PAULI_ROTATION {
            return Err(format!(
                "unsupported gate type at gate {gate_no}: {}",
                gate.gate_type
            ));
        }
        if gate.paulis.len() != gate.qubits.len() {
            return Err(format!(
                "gate {gate_no} paulis and qubits must have the same length"
            ));
        }
        if gate.paulis.is_empty() {
            return Err(format!("gate {gate_no} must act on at least one qubit"));
        }
        for pauli in &gate.paulis {
            if !SUPPORTED_PAULIS.contains(&pauli.as_str()) {
                return Err(format!(
                    "unsupported Pauli symbol at gate {gate_no}: {pauli}"
                ));
            }
        }
        for &qubit in &gate.qubits {
            if qubit < 0 || qubit >= description.nqubits {
                return Err(format!(
                    "gate {gate_no} qubit index {qubit} is outside 0:{}",
                    description.nqubits - 1
                ));
            }
        }
    }
    Ok(())
}

/// Extract the truncation threshold. Phase 1 supports only `method = "threshold"`.
/// Reads the unified `coefficient_threshold` key first, falling back to the
/// legacy `threshold` key.
pub fn truncation_threshold(description: &CircuitDescription) -> Result<f64, String> {
    let method = description
        .truncation
        .get("method")
        .and_then(Value::as_str)
        .unwrap_or("");
    if method != "threshold" {
        return Err(format!("unsupported truncation method: {method}"));
    }
    description
        .truncation
        .get("coefficient_threshold")
        .or_else(|| description.truncation.get("threshold"))
        .and_then(Value::as_f64)
        .ok_or_else(|| "truncation.threshold must be a number".to_string())
}

/// Extract the optional `max_terms` (top-K) truncation knob. `None` means no
/// term-count cap (the pauli-prop default behaviour).
pub fn truncation_max_terms(description: &CircuitDescription) -> Result<Option<i64>, String> {
    match description.truncation.get("max_terms") {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_i64()
            .filter(|&n| n > 0)
            .map(Some)
            .ok_or_else(|| "truncation.max_terms must be a positive integer".to_string()),
    }
}

/// Parse an observable label into a list of `(pauli, qubit, coeff)` terms.
/// `"Mz"` / `"magnetization"` expands to `sum_i Z_i / nqubits`, matching the
/// cpp/cuda runners and the Julia backend; anything else must be a
/// single-qubit Pauli label such as `"Z62"`.
pub fn parse_observable_terms(
    observable: &str,
    nqubits: i64,
) -> Result<Vec<(char, i64, f64)>, String> {
    let obs = observable.trim();
    if obs == "Mz" || obs == "magnetization" {
        let coeff = 1.0 / nqubits as f64;
        return Ok((0..nqubits).map(|qubit| ('Z', qubit, coeff)).collect());
    }
    let (symbol, index) = parse_observable(obs, nqubits)?;
    Ok(vec![(symbol, index, 1.0)])
}

/// Parse a single-qubit observable label such as `"Z0"` into its Pauli symbol
/// and 0-based qubit index. Mirrors `_parse_observable` in `julia_pauliprop.jl`.
pub fn parse_observable(observable: &str, nqubits: i64) -> Result<(char, i64), String> {
    let mut chars = observable.chars();
    let symbol = chars
        .next()
        .filter(|c| SUPPORTED_PAULIS.contains(&c.to_string().as_str()))
        .ok_or_else(|| format!("unsupported observable: {observable}"))?;
    let index_str: String = chars.collect();
    if index_str.is_empty() {
        return Err(format!("unsupported observable: {observable}"));
    }
    let index: i64 = index_str
        .parse()
        .map_err(|_| format!("unsupported observable: {observable}"))?;
    if index < 0 || index >= nqubits {
        return Err(format!(
            "observable qubit index {index} is outside 0:{}",
            nqubits - 1
        ));
    }
    Ok((symbol, index))
}

#[cfg(test)]
mod tests {
    use super::*;

    const VALID: &str = r#"{
        "schema_version": "pps-circuit-v1",
        "task_id": "small_clifford_rotation_n4_l4_seed1",
        "family": "clifford_pauli_rotation",
        "seed": 1,
        "nqubits": 4,
        "observable": "Z0",
        "truncation": {"method": "threshold", "threshold": 1.0e-8},
        "reference": {"enabled": true, "method": "exact_small"},
        "gates": [
            {"type": "pauli_rotation", "paulis": ["X"], "qubits": [0], "theta": 0.9092974268256817},
            {"type": "pauli_rotation", "paulis": ["Z", "Z"], "qubits": [0, 1], "theta": 0.5}
        ],
        "metadata": {"name": "bench_small", "nlayers": 4}
    }"#;

    #[test]
    fn parses_a_valid_circuit() {
        let description = parse_circuit(VALID).expect("valid circuit must parse");
        assert_eq!(description.task_id, "small_clifford_rotation_n4_l4_seed1");
        assert_eq!(description.nqubits, 4);
        assert_eq!(description.observable, "Z0");
        assert_eq!(description.gates.len(), 2);
        assert_eq!(description.gates[1].paulis, vec!["Z", "Z"]);
        assert_eq!(description.gates[1].qubits, vec![0, 1]);
    }

    #[test]
    fn rejects_an_unsupported_schema_version() {
        let json = VALID.replace("pps-circuit-v1", "pps-circuit-v2");
        let err = parse_circuit(&json).expect_err("bad schema must be rejected");
        assert!(err.contains("schema version"), "got: {err}");
    }

    #[test]
    fn rejects_a_qubit_index_out_of_range() {
        let json = VALID.replace("\"qubits\": [0],", "\"qubits\": [4],");
        let err = parse_circuit(&json).expect_err("out-of-range qubit must be rejected");
        assert!(err.contains("outside 0:3"), "got: {err}");
    }

    #[test]
    fn rejects_mismatched_paulis_and_qubits() {
        let json = VALID.replace("\"paulis\": [\"X\"], \"qubits\": [0]", "\"paulis\": [\"X\", \"Y\"], \"qubits\": [0]");
        let err = parse_circuit(&json).expect_err("shape mismatch must be rejected");
        assert!(err.contains("same length"), "got: {err}");
    }

    #[test]
    fn rejects_an_unsupported_gate_type() {
        let json = VALID.replace("pauli_rotation\", \"paulis\": [\"X\"]", "measure\", \"paulis\": [\"X\"]");
        let err = parse_circuit(&json).expect_err("unknown gate type must be rejected");
        assert!(err.contains("unsupported gate type"), "got: {err}");
    }

    #[test]
    fn rejects_an_unsupported_pauli_symbol() {
        let json = VALID.replace("\"paulis\": [\"X\"]", "\"paulis\": [\"W\"]");
        let err = parse_circuit(&json).expect_err("unknown Pauli must be rejected");
        assert!(err.contains("unsupported Pauli symbol"), "got: {err}");
    }

    #[test]
    fn reads_the_truncation_threshold() {
        let description = parse_circuit(VALID).unwrap();
        let threshold = truncation_threshold(&description).expect("threshold must be readable");
        assert_eq!(threshold, 1.0e-8);
    }

    #[test]
    fn parses_a_single_qubit_observable() {
        assert_eq!(parse_observable("Z0", 4).unwrap(), ('Z', 0));
        assert_eq!(parse_observable("X3", 4).unwrap(), ('X', 3));
    }

    #[test]
    fn expands_mz_into_per_qubit_z_terms() {
        let terms = parse_observable_terms("Mz", 4).unwrap();
        assert_eq!(terms, vec![('Z', 0, 0.25), ('Z', 1, 0.25), ('Z', 2, 0.25), ('Z', 3, 0.25)]);
        assert_eq!(parse_observable_terms("magnetization", 4).unwrap(), terms);
    }

    #[test]
    fn wraps_a_single_qubit_observable_into_one_term() {
        assert_eq!(parse_observable_terms("Z2", 4).unwrap(), vec![('Z', 2, 1.0)]);
    }

    #[test]
    fn rejects_an_observable_out_of_range() {
        let err = parse_observable("Z4", 4).expect_err("out-of-range observable must be rejected");
        assert!(err.contains("outside 0:3"), "got: {err}");
    }

    #[test]
    fn rejects_a_malformed_observable() {
        assert!(parse_observable("ZZ", 4).is_err());
        assert!(parse_observable("Z", 4).is_err());
        assert!(parse_observable("W0", 4).is_err());
    }

    #[test]
    fn rejects_an_unsupported_truncation_method() {
        let json = VALID.replace("\"method\": \"threshold\"", "\"method\": \"top_k\"");
        let description = parse_circuit(&json).unwrap();
        let err = truncation_threshold(&description).expect_err("non-threshold must be rejected");
        assert!(err.contains("unsupported truncation method"), "got: {err}");
    }
}
