#!/usr/bin/env python3
"""sweep_truncation.py — accuracy/speed trade-off across truncation thresholds.

For each coefficient threshold, runs every requested backend on a copy of the
base config and records runtime, term counts, and the error against the Julia
exact (threshold = 0) reference expectation. Produces a Markdown table and a
two-panel plot (error vs threshold, runtime vs threshold).

Usage:
  python3 scripts/sweep_truncation.py \
      --config configs/bench_medium.toml \
      --backends julia_pauliprop rust_pauliprop cpp_pauliengine \
      --thresholds 1e-3 1e-4 1e-5 1e-6 1e-7 \
      --out-prefix results/truncation_sweep
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def make_config(base_text: str, threshold: float) -> str:
    """Rewrite both threshold keys in the [truncation] block."""
    text = re.sub(
        r"^(coefficient_threshold\s*=\s*).*$",
        rf"\g<1>{threshold:e}",
        base_text,
        flags=re.M,
    )
    return re.sub(r"^(threshold\s*=\s*).*$", rf"\g<1>{threshold:e}", text, flags=re.M)


def run_backend(backend: str, config_path: Path) -> dict:
    cmd = [
        "julia",
        "--project=.",
        "benchmarks/run_backend.jl",
        "--backend",
        backend,
        "--config",
        str(config_path),
    ]
    proc = subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        env={**os.environ, "JULIA_PKG_PRECOMPILE_AUTO": "0"},
    )
    if proc.returncode != 0:
        raise RuntimeError(f"{backend} failed:\n{proc.stderr[-2000:]}")
    last_line = [l for l in proc.stdout.splitlines() if l.strip()][-1]
    return json.loads(last_line)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="configs/bench_medium.toml")
    parser.add_argument(
        "--backends",
        nargs="+",
        default=["julia_pauliprop", "rust_pauliprop", "cpp_pauliengine"],
    )
    parser.add_argument(
        "--thresholds",
        nargs="+",
        type=float,
        default=[1e-3, 1e-4, 1e-5, 1e-6, 1e-7],
    )
    parser.add_argument("--out-prefix", default="results/truncation_sweep")
    args = parser.parse_args()

    base_text = (REPO_ROOT / args.config).read_text()
    rows = []  # (backend, threshold, runtime, final_terms, error_vs_exact)

    for threshold in args.thresholds:
        with tempfile.NamedTemporaryFile(
            "w", suffix=".toml", prefix="pps_sweep_", delete=False
        ) as f:
            f.write(make_config(base_text, threshold))
            tmp_config = Path(f.name)
        try:
            exact_reference = None
            for backend in args.backends:
                print(f"[{threshold:.0e}] {backend} ...", file=sys.stderr, flush=True)
                result = run_backend(backend, tmp_config)
                # The Julia backend's `reference` field is the exact
                # (threshold = 0) expectation — the shared ground truth.
                if backend == "julia_pauliprop":
                    exact_reference = result["reference"]
                error = (
                    abs(result["expectation"] - exact_reference)
                    if exact_reference is not None
                    else None
                )
                rows.append(
                    (
                        backend,
                        threshold,
                        result["runtime_sec"],
                        result["final_terms"],
                        error,
                    )
                )
        finally:
            tmp_config.unlink(missing_ok=True)

    # --- Markdown table ---
    lines = [
        "| Backend | Threshold | Runtime (s) | Final terms | Error vs exact |",
        "|---|---|---|---|---|",
    ]
    for backend, threshold, runtime, final_terms, error in rows:
        err_str = f"{error:.2e}" if error is not None else "—"
        lines.append(
            f"| {backend} | {threshold:.0e} | {runtime:.4g} | {final_terms} | {err_str} |"
        )
    table = "\n".join(lines)
    print(table)

    prefix = Path(args.out_prefix)
    prefix.parent.mkdir(parents=True, exist_ok=True)
    prefix.with_suffix(".md").write_text(
        f"# Truncation sweep — {args.config}\n\n{table}\n"
    )
    print(f"Wrote {prefix.with_suffix('.md')}", file=sys.stderr)

    # --- Plot ---
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("NOTE: matplotlib not available; skipping plot", file=sys.stderr)
        return 0

    fig, (ax_err, ax_time) = plt.subplots(1, 2, figsize=(11, 4.5))
    for backend in args.backends:
        pts = [(t, e, rt) for b, t, rt, _, e in rows if b == backend]
        thresholds = [p[0] for p in pts]
        errors = [max(p[1], 1e-17) if p[1] is not None else None for p in pts]
        runtimes = [p[2] for p in pts]
        ax_err.plot(thresholds, errors, "o-", label=backend)
        ax_time.plot(thresholds, runtimes, "o-", label=backend)

    ax_err.set_xscale("log")
    ax_err.set_yscale("log")
    ax_err.set_xlabel("Coefficient threshold")
    ax_err.set_ylabel("|expectation − exact|")
    ax_err.set_title("Accuracy vs truncation")
    ax_err.legend(fontsize=8)

    ax_time.set_xscale("log")
    ax_time.set_yscale("log")
    ax_time.set_xlabel("Coefficient threshold")
    ax_time.set_ylabel("Runtime (s)")
    ax_time.set_title("Runtime vs truncation")
    ax_time.legend(fontsize=8)

    fig.tight_layout()
    fig.savefig(prefix.with_suffix(".png"), dpi=150)
    print(f"Wrote {prefix.with_suffix('.png')}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
