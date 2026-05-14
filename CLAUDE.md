# PPS Backend Benchmark

## Project Goal

This repository benchmarks multiple backends for Pauli propagation and symbolic Pauli arithmetic.

Julia is the orchestration layer. Backend implementations may use Julia, Python, Rust, C++, or CUDA, but every backend must read the same benchmark specification and produce the same result schema.

## Target Backends

1. Julia / PauliPropagation.jl
2. CUDA / cuPauliProp
3. Rust / Qiskit pauli-prop
4. C++ / PauliEngine
5. Python / BlueQubit
6. Python / cuQuantum Python

## Current Phase

Phase 1 only implements the Julia orchestration layer and the Julia / PauliPropagation.jl backend.

Do not implement CUDA, C++, Rust, BlueQubit, or cuQuantum Python until the Julia-only benchmark pipeline is working.

## Core Workflow

No Issue, no code change.

Every task must follow:

1. Create or read a GitHub Issue.
2. Create a branch for that Issue.
3. Implement only the requested scope.
4. Run tests.
5. Run a smoke benchmark.
6. Commit changes.
7. Open a PR.
8. Do not merge without human approval.

## Git Safety Rules

- Never commit directly to main.
- Never force push.
- Never rewrite benchmark results manually.
- Never change the result schema without updating tests.
- Never make broad refactors unless the Issue explicitly asks for it.

## Repository Structure

- src/ contains Julia source code.
- src/backends/ contains backend interfaces and wrappers.
- benchmarks/ contains executable benchmark scripts.
- configs/ contains benchmark configuration files.
- wrappers/ contains Python, C++, and CUDA runners.
- results/ contains generated benchmark outputs.
- logs/ contains raw execution logs.
- test/ contains Julia tests.
- docs/ contains protocol and reproducibility notes.

## Required Benchmark Result Fields

Every backend result must include:

- backend
- task_id
- success
- runtime_sec
- memory_bytes
- final_terms
- expectation
- reference
- absolute_error
- metadata

## Validation Commands

Before committing, run:

```bash
make test
make smokeCoding Rules

## Coding Rules

Prefer simple, explicit code.
Keep backend-specific logic isolated.
Do not optimize before correctness tests pass.
Every wrapper must fail loudly and return structured error information.
Use deterministic random seeds for benchmark tasks.
