#!/usr/bin/env python3
"""
Validate collected LOWESA 127-qubit benchmark results from all backends.

Reads result JSONs from --results-dir, checks success and RMSE thresholds,
and writes a summary verification_report.json.

Exit code: 0 = all backends pass, 1 = one or more failures.

Usage:
    python3 scripts/validate_lowesa127.py --results-dir results/remote/
    python3 scripts/validate_lowesa127.py --results-dir results/  # local run
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

BACKENDS = {
    "julia_pauliprop":  {"prefix": "",            "label": "Julia / PauliPropagation.jl"},
    "rust_pauliprop":   {"prefix": "rust_",        "label": "Rust / Qiskit pauli-prop"},
    "cpp_pauliengine":  {"prefix": "cpp_",         "label": "C++ / PauliEngine"},
    "cuda_cupauliprop": {"prefix": "cuda_",        "label": "CUDA / cuPauliProp"},
    "python_cuquantum": {"prefix": "cuquantum_",   "label": "Python / cuQuantum"},
}

CONFIGS = ["lowesa_tfi_127_L5_mz", "lowesa_tfi_127_L5_z62"]

RMSE_THRESHOLD = 5e-3


def load_result(results_dir: Path, backend: str, config: str) -> dict | None:
    prefix = BACKENDS[backend]["prefix"]
    path = results_dir / f"{prefix}{config}.json"
    if not path.exists():
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except Exception as e:
        return {"_load_error": str(e)}


def check_sweep_result(data: dict) -> tuple[bool, str]:
    """Return (pass, reason) for a sweep result JSON."""
    if "_load_error" in data:
        return False, f"JSON parse error: {data['_load_error']}"
    if not data.get("success", False):
        err = data.get("metadata", {}).get("error", "success=false")
        return False, f"success=false: {err}"
    rmse = data.get("metadata", {}).get("rmse")
    if rmse is None:
        return False, "metadata.rmse missing"
    if rmse >= RMSE_THRESHOLD:
        return False, f"rmse={rmse:.3e} >= threshold {RMSE_THRESHOLD:.3e}"
    return True, f"rmse={rmse:.3e}"


def git_sha() -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"], text=True
        ).strip()
    except Exception:
        return "unknown"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--results-dir",
        type=Path,
        default=Path("results/remote"),
        help="Directory containing collected result JSONs",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Path for the report JSON (default: <results-dir>/verification_report.json)",
    )
    args = parser.parse_args()

    results_dir = args.results_dir
    if not results_dir.exists():
        print(f"ERROR: results directory not found: {results_dir}", file=sys.stderr)
        return 1

    output_path = args.output or (results_dir / "verification_report.json")

    report: dict = {
        "date": datetime.now(timezone.utc).isoformat(),
        "commit": git_sha(),
        "results_dir": str(results_dir),
        "rmse_threshold": RMSE_THRESHOLD,
        "backends": {},
        "overall_pass": True,
    }

    print(f"\nValidating LOWESA 127-qubit results in: {results_dir}\n")
    print(f"{'Backend':<22}  {'Config':<28}  {'Status':<6}  Detail")
    print("-" * 75)

    for backend, meta in BACKENDS.items():
        label = meta["label"]
        report["backends"][backend] = {}

        for config in CONFIGS:
            data = load_result(results_dir, backend, config)

            if data is None:
                ok, detail = False, "result file missing"
            else:
                ok, detail = check_sweep_result(data)

            report["backends"][backend][config] = {
                "found": data is not None,
                "pass": ok,
                "detail": detail,
            }
            if not ok:
                report["overall_pass"] = False

            status = "PASS" if ok else "FAIL"
            print(f"{label:<22}  {config:<28}  {status:<6}  {detail}")

    print("-" * 75)
    overall = "PASS" if report["overall_pass"] else "FAIL"
    print(f"\nOverall: {overall}\n")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(report, f, indent=2)
    print(f"Report written to: {output_path}")

    return 0 if report["overall_pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
