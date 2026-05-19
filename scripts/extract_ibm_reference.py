#!/usr/bin/env python3
"""Extract IBM "utility" paper exact reference curves for the LOWESA L=5 benchmark.

Dev-only, one-off. NOT part of the runtime pipeline (Phase 1 is Julia-only).
Reads the published exact data and writes two plain-text reference curves that the
Julia benchmark consumes; the text outputs are committed, this script is not run
by `make`.

Source: Kim et al., "Evidence for the utility of quantum computing before fault
tolerance" (Nature 618, 500-505, 2023), accompanying data, 5 Trotter steps,
127 qubits.

Requires numpy (used only here). Run from the repository root, e.g.:

    python3 -m venv /tmp/ppsenv && /tmp/ppsenv/bin/pip install numpy
    /tmp/ppsenv/bin/python scripts/extract_ibm_reference.py

Outputs (158 lines each, `theta value`):
    reference/ibm_utility_L5_Mz.txt   -- magnetization Mz = (1/127) sum_i <Z_i>
    reference/ibm_utility_L5_Z62.txt  -- single-site <Z_62> (0-based qubit index)
"""
import pickle
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[1]
DATA = (
    REPO
    / "reference"
    / "Evidence-for-the-utility-of-quantum-computing-before-fault-tolerance-mainfig"
    / "Evidence-for-the-utility-of-quantum-computing-before-fault-tolerance-main"
    / "data"
    / "exactMagnetization_steps5_qubits127_reducedTrue_HFalse.pkl"
)
OUT_DIR = REPO / "reference"
Z62_QUBIT = 62  # 0-based


def _write_curve(path: Path, thetas, values, header):
    lines = [f"# {header}", "# theta value"]
    for theta, value in zip(thetas, values):
        lines.append(f"{float(theta)!r} {float(value)!r}")
    path.write_text("\n".join(lines) + "\n")
    print(f"wrote {path.relative_to(REPO)} ({len(values)} points)")


def main():
    with open(DATA, "rb") as handle:
        data = pickle.load(handle)

    thetas = np.asarray(data["theta"], dtype=float)
    avg_sz = np.asarray(data["avg_Sz"]).real.astype(float)
    szs = np.asarray(data["Szs"]).real.astype(float)  # shape (n_theta, n_qubits)

    assert thetas.shape == (158,), thetas.shape
    assert szs.shape == (158, 127), szs.shape
    assert data["steps"] == 5 and data["qubits"] == 127

    # avg_Sz must be the per-qubit mean -- sanity check the provenance.
    assert np.allclose(avg_sz, szs.mean(axis=1), atol=1e-9)

    _write_curve(
        OUT_DIR / "ibm_utility_L5_Mz.txt",
        thetas,
        avg_sz,
        "IBM utility paper exact Mz = (1/127) sum_i <Z_i>, L=5, 127 qubits",
    )
    _write_curve(
        OUT_DIR / "ibm_utility_L5_Z62.txt",
        thetas,
        szs[:, Z62_QUBIT],
        f"IBM utility paper exact <Z_{Z62_QUBIT}> (0-based), L=5, 127 qubits",
    )


if __name__ == "__main__":
    main()
