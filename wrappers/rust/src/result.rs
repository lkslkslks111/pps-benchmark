//! The `BenchmarkResult` payload the runner prints to stdout.
//!
//! Field names and types match `benchmark_result_dict` in the Julia
//! orchestration layer (`src/io/schema.jl`). The Julia subprocess backend
//! parses this JSON back into a `BenchmarkResult` struct.

use serde::Serialize;
use serde_json::Value;
use std::collections::BTreeMap;

/// A single benchmark result, serialized as one JSON line on stdout.
#[derive(Debug, Clone, Serialize)]
pub struct BenchmarkResult {
    pub backend: String,
    pub task_id: String,
    pub success: bool,
    pub runtime_sec: f64,
    pub memory_bytes: i64,
    pub final_terms: i64,
    pub expectation: f64,
    pub reference: f64,
    pub absolute_error: f64,
    pub metadata: BTreeMap<String, Value>,
}

impl BenchmarkResult {
    /// Serialize to a single-line JSON string (no trailing newline).
    pub fn to_json_line(&self) -> Result<String, String> {
        serde_json::to_string(self).map_err(|e| format!("failed to serialize result: {e}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> BenchmarkResult {
        let mut metadata = BTreeMap::new();
        metadata.insert("engine".to_string(), Value::from("qiskit_pauli_prop"));
        BenchmarkResult {
            backend: "rust_pauliprop".to_string(),
            task_id: "small_clifford_rotation_n4_l4_seed1".to_string(),
            success: true,
            runtime_sec: 0.0123,
            memory_bytes: 4096,
            final_terms: 7,
            expectation: 0.5,
            reference: 0.5,
            absolute_error: 0.0,
            metadata,
        }
    }

    #[test]
    fn serializes_to_a_single_json_line() {
        let line = sample().to_json_line().expect("result must serialize");
        assert!(!line.contains('\n'), "must be a single line: {line}");
        let parsed: Value = serde_json::from_str(&line).expect("output must be valid JSON");
        assert_eq!(parsed["backend"], "rust_pauliprop");
        assert_eq!(parsed["success"], true);
        assert_eq!(parsed["final_terms"], 7);
        assert_eq!(parsed["metadata"]["engine"], "qiskit_pauli_prop");
    }

    #[test]
    fn includes_every_required_schema_field() {
        let line = sample().to_json_line().unwrap();
        let parsed: Value = serde_json::from_str(&line).unwrap();
        for field in [
            "backend",
            "task_id",
            "success",
            "runtime_sec",
            "memory_bytes",
            "final_terms",
            "expectation",
            "reference",
            "absolute_error",
            "metadata",
        ] {
            assert!(
                parsed.get(field).is_some(),
                "missing required field: {field}"
            );
        }
    }
}
