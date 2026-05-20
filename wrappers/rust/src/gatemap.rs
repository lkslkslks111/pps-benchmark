//! Classification of `pps-circuit-v1` Pauli-rotation gates into the Qiskit
//! gate that the PyO3 layer should emit.
//!
//! A `pps-circuit-v1` gate is the rotation `exp(-i*theta/2 * P)`. Qiskit's
//! `rx/ry/rz` and `rxx/ryy/rzz` use the same `exp(-i*theta/2 * P)` convention,
//! so single- and uniform two-qubit Pauli rotations map directly. Everything
//! else (mixed or >2 qubit Paulis) falls back to a `PauliEvolutionGate`.

use crate::circuit::CircuitGate;

/// The Qiskit gate a `pps-circuit-v1` gate maps to.
#[derive(Debug, Clone, PartialEq)]
pub enum GateOp {
    /// Single-qubit rotation `rx`/`ry`/`rz`; `axis` is `'x'`, `'y'`, or `'z'`.
    Single { axis: char, qubit: i64, theta: f64 },
    /// Uniform two-qubit rotation `rxx`/`ryy`/`rzz`; `axis` is `'x'`/`'y'`/`'z'`.
    Double { axis: char, q0: i64, q1: i64, theta: f64 },
    /// General multi-qubit Pauli rotation, emitted as a `PauliEvolutionGate`.
    /// `label` is the dense Pauli string ordered to match `qubits`.
    General {
        label: String,
        qubits: Vec<i64>,
        theta: f64,
    },
}

/// Classify a circuit gate. Assumes the gate already passed `circuit::validate`.
pub fn classify(gate: &CircuitGate) -> GateOp {
    let axis_of = |pauli: &str| match pauli {
        "X" => Some('x'),
        "Y" => Some('y'),
        "Z" => Some('z'),
        _ => None,
    };

    match gate.paulis.len() {
        1 => {
            if let Some(axis) = axis_of(&gate.paulis[0]) {
                return GateOp::Single {
                    axis,
                    qubit: gate.qubits[0],
                    theta: gate.theta,
                };
            }
        }
        2 if gate.paulis[0] == gate.paulis[1] => {
            if let Some(axis) = axis_of(&gate.paulis[0]) {
                return GateOp::Double {
                    axis,
                    q0: gate.qubits[0],
                    q1: gate.qubits[1],
                    theta: gate.theta,
                };
            }
        }
        _ => {}
    }

    GateOp::General {
        label: gate.paulis.concat(),
        qubits: gate.qubits.clone(),
        theta: gate.theta,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gate(paulis: &[&str], qubits: &[i64], theta: f64) -> CircuitGate {
        CircuitGate {
            gate_type: "pauli_rotation".to_string(),
            paulis: paulis.iter().map(|p| p.to_string()).collect(),
            qubits: qubits.to_vec(),
            theta,
        }
    }

    #[test]
    fn single_qubit_x_rotation_maps_to_rx() {
        let op = classify(&gate(&["X"], &[2], 0.7));
        assert_eq!(
            op,
            GateOp::Single {
                axis: 'x',
                qubit: 2,
                theta: 0.7
            }
        );
    }

    #[test]
    fn single_qubit_z_rotation_maps_to_rz() {
        let op = classify(&gate(&["Z"], &[0], 1.25));
        assert_eq!(
            op,
            GateOp::Single {
                axis: 'z',
                qubit: 0,
                theta: 1.25
            }
        );
    }

    #[test]
    fn uniform_two_qubit_zz_rotation_maps_to_rzz() {
        let op = classify(&gate(&["Z", "Z"], &[0, 1], -1.5707963267948966));
        assert_eq!(
            op,
            GateOp::Double {
                axis: 'z',
                q0: 0,
                q1: 1,
                theta: -1.5707963267948966
            }
        );
    }

    #[test]
    fn mixed_two_qubit_rotation_falls_back_to_general() {
        let op = classify(&gate(&["X", "Z"], &[1, 3], 0.4));
        assert_eq!(
            op,
            GateOp::General {
                label: "XZ".to_string(),
                qubits: vec![1, 3],
                theta: 0.4
            }
        );
    }

    #[test]
    fn three_qubit_rotation_falls_back_to_general() {
        let op = classify(&gate(&["X", "X", "X"], &[0, 1, 2], 0.9));
        assert_eq!(
            op,
            GateOp::General {
                label: "XXX".to_string(),
                qubits: vec![0, 1, 2],
                theta: 0.9
            }
        );
    }

    #[test]
    fn identity_single_qubit_rotation_falls_back_to_general() {
        let op = classify(&gate(&["I"], &[0], 0.3));
        assert_eq!(
            op,
            GateOp::General {
                label: "I".to_string(),
                qubits: vec![0],
                theta: 0.3
            }
        );
    }
}
