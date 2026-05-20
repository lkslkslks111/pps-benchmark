//! Pure-logic core of the Rust / Qiskit pauli-prop benchmark backend.
//!
//! These modules carry no Python dependency so they can be unit-tested with
//! `cargo test --no-default-features --lib`. The PyO3-based propagation lives in
//! the binary crate (`src/main.rs`, `src/propagate.rs`).

pub mod circuit;
pub mod gatemap;
pub mod result;
