#!/usr/bin/env python3
"""compare_truncation_types.py — per-backend truncation types and combinations.

Runs every backend on the same base circuit under each truncation variant it
supports, then emits:
  1. A Markdown matrix:  variant x backend  (runtime / terms / error vs exact)
  2. Grouped bar charts (runtime, final terms) — <out-prefix>.png
  3. Per-gate Pauli-term growth curves, one panel per variant, one line per
     backend — <out-prefix>_growth.png  (layer boundaries marked)

Variant support matrix (from the official engine APIs):
  coeff          coefficient_threshold        julia, rust, cpp, cuda
  weight         pauli_weight_cutoff          julia, cpp, cuda
  coeff+weight   both combined                julia, cpp, cuda
  topK           max_terms (largest-K)        rust
  coeff+topK     both combined                rust

Usage:
  python3 scripts/compare_truncation_types.py --out-prefix results/truncation_types
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

COEFF = 1e-7
WEIGHT = 4
TOPK = 4096

# label -> (truncation TOML lines, backends)
VARIANTS = {
    "coeff": (
        {"coefficient_threshold": COEFF},
        ["julia_pauliprop", "rust_pauliprop", "cpp_pauliengine", "cuda_cupauliprop"],
    ),
    "weight": (
        {"coefficient_threshold": 0.0, "pauli_weight_cutoff": WEIGHT},
        ["julia_pauliprop", "cpp_pauliengine", "cuda_cupauliprop"],
    ),
    "coeff+weight": (
        {"coefficient_threshold": COEFF, "pauli_weight_cutoff": WEIGHT},
        ["julia_pauliprop", "cpp_pauliengine", "cuda_cupauliprop"],
    ),
    "topK": (
        {"coefficient_threshold": 0.0, "max_terms": TOPK},
        ["rust_pauliprop"],
    ),
    "coeff+topK": (
        {"coefficient_threshold": COEFF, "max_terms": TOPK},
        ["rust_pauliprop"],
    ),
}

BACKEND_ORDER = ["julia_pauliprop", "rust_pauliprop", "cpp_pauliengine", "cuda_cupauliprop"]
BACKEND_COLOR = {
    "julia_pauliprop": "tab:purple",
    "rust_pauliprop": "tab:orange",
    "cpp_pauliengine": "tab:blue",
    "cuda_cupauliprop": "tab:green",
}
# Distinct dashes so overlapping growth curves (backends agree exactly on the
# per-gate term counts) remain individually visible.
BACKEND_STYLE = {
    "julia_pauliprop": (4.5, "-"),
    "cpp_pauliengine": (3.0, "--"),
    "cuda_cupauliprop": (1.5, ":"),
}


def variant_config(base_text: str, knobs: dict) -> str:
    """Replace the [truncation] block of the base TOML with the variant knobs."""
    lines = ["[truncation]", 'method = "threshold"']
    for key, value in knobs.items():
        if isinstance(value, float):
            lines.append(f"{key} = {value:e}")
        else:
            lines.append(f"{key} = {value}")
    # Legacy `threshold` mirror for parsers that predate coefficient_threshold.
    lines.append(f"threshold = {knobs.get('coefficient_threshold', 0.0):e}")
    block = "\n".join(lines)
    return re.sub(r"\[truncation\][^\[]*", block + "\n\n", base_text, count=1)


def run_backend(backend: str, config_path: Path) -> dict:
    cmd = [
        "julia", "--project=.", "benchmarks/run_backend.jl",
        "--backend", backend, "--config", str(config_path),
    ]
    proc = subprocess.run(
        cmd, cwd=REPO_ROOT, capture_output=True, text=True,
        env={**os.environ, "JULIA_PKG_PRECOMPILE_AUTO": "0"},
    )
    if proc.returncode != 0:
        raise RuntimeError(f"{backend} failed:\n{proc.stderr[-2000:]}")
    return json.loads([l for l in proc.stdout.splitlines() if l.strip()][-1])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="configs/bench_medium.toml")
    parser.add_argument("--out-prefix", default="results/truncation_types")
    parser.add_argument(
        "--skip-backends", nargs="*", default=[],
        help="Backends to leave out (e.g. cuda_cupauliprop on a GPU-less host)",
    )
    args = parser.parse_args()

    base_text = (REPO_ROOT / args.config).read_text()
    nlayers_match = re.search(r"^nlayers\s*=\s*(\d+)", base_text, re.M)
    nlayers = int(nlayers_match.group(1)) if nlayers_match else None

    records = []  # (variant, backend, result_dict)
    exact_reference = None

    for variant, (knobs, backends) in VARIANTS.items():
        with tempfile.NamedTemporaryFile(
            "w", suffix=".toml", prefix="pps_trunc_", delete=False
        ) as f:
            f.write(variant_config(base_text, knobs))
            tmp_config = Path(f.name)
        try:
            for backend in backends:
                if backend in args.skip_backends:
                    continue
                print(f"[{variant}] {backend} ...", file=sys.stderr, flush=True)
                result = run_backend(backend, tmp_config)
                records.append((variant, backend, result))
                # Julia's `reference` is the exact (untruncated) expectation —
                # identical across variants, so capture it once as ground truth.
                if backend == "julia_pauliprop" and exact_reference is None:
                    exact_reference = result["reference"]
        finally:
            tmp_config.unlink(missing_ok=True)

    # --- Markdown table ---
    lines = [
        "| Variant | Backend | Runtime (s) | Final terms | Peak terms | Error vs exact |",
        "|---|---|---|---|---|---|",
    ]
    for variant, backend, r in records:
        error = (
            abs(r["expectation"] - exact_reference)
            if exact_reference is not None
            else None
        )
        peak = r.get("peak_terms")
        lines.append(
            f"| {variant} | {backend} | {r['runtime_sec']:.4g} | {r['final_terms']} "
            f"| {peak if peak is not None else '—'} "
            f"| {f'{error:.2e}' if error is not None else '—'} |"
        )
    table = "\n".join(lines)
    print(table)

    prefix = Path(args.out_prefix)
    prefix.parent.mkdir(parents=True, exist_ok=True)
    knob_note = f"coeff = {COEFF:g}, weight cutoff = {WEIGHT}, topK = {TOPK}"
    prefix.with_suffix(".md").write_text(
        f"# Truncation types x backends — {args.config}\n\n({knob_note})\n\n{table}\n"
    )
    print(f"Wrote {prefix.with_suffix('.md')}", file=sys.stderr)

    # --- Plots ---
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import numpy as np
    except ImportError:
        print("NOTE: matplotlib not available; skipping plots", file=sys.stderr)
        return 0

    variants = [v for v in VARIANTS if any(rec[0] == v for rec in records)]
    backends = [b for b in BACKEND_ORDER if any(rec[1] == b for rec in records)]

    # Grouped bars: runtime and final terms
    fig, (ax_rt, ax_ft) = plt.subplots(1, 2, figsize=(13, 4.5))
    width = 0.8 / len(backends)
    x = np.arange(len(variants))
    for bi, backend in enumerate(backends):
        runtimes, finals = [], []
        for variant in variants:
            rec = next(
                (r for v, b, r in records if v == variant and b == backend), None
            )
            runtimes.append(rec["runtime_sec"] if rec else 0)
            finals.append(rec["final_terms"] if rec else 0)
        offset = (bi - (len(backends) - 1) / 2) * width
        ax_rt.bar(x + offset, runtimes, width, label=backend, color=BACKEND_COLOR.get(backend))
        ax_ft.bar(x + offset, finals, width, label=backend, color=BACKEND_COLOR.get(backend))
    for ax, title, ylabel in (
        (ax_rt, "Runtime by truncation variant", "Runtime (s)"),
        (ax_ft, "Final term count by truncation variant", "Final Pauli terms"),
    ):
        ax.set_xticks(x)
        ax.set_xticklabels(variants)
        ax.set_yscale("log")
        ax.set_title(title)
        ax.set_ylabel(ylabel)
        ax.legend(fontsize=8)
    fig.suptitle(knob_note, fontsize=9)
    fig.tight_layout()
    fig.savefig(prefix.with_suffix(".png"), dpi=150)
    print(f"Wrote {prefix.with_suffix('.png')}", file=sys.stderr)

    # Per-gate term growth, one panel per variant. Variants whose only
    # backends expose no per-gate counts (rust: opaque engine) are skipped.
    variants = [
        v for v in variants
        if any(
            rec[0] == v and rec[2].get("metadata", {}).get("terms_history")
            for rec in records
        )
    ]
    ncols = min(3, len(variants))
    nrows = (len(variants) + ncols - 1) // ncols
    fig, axes = plt.subplots(nrows, ncols, figsize=(5.5 * ncols, 4 * nrows), squeeze=False)
    for vi, variant in enumerate(variants):
        ax = axes[vi // ncols][vi % ncols]
        circuit_size = None
        for v, backend, r in records:
            if v != variant:
                continue
            history = r.get("metadata", {}).get("terms_history")
            if not history:
                continue  # rust: engine is opaque, no per-gate counts
            circuit_size = len(history)
            lw, ls = BACKEND_STYLE.get(backend, (1.5, "-"))
            ax.plot(
                range(1, len(history) + 1), history,
                label=backend, color=BACKEND_COLOR.get(backend),
                linewidth=lw, linestyle=ls, alpha=0.9,
            )
        if nlayers and circuit_size and circuit_size % nlayers == 0:
            per_layer = circuit_size // nlayers
            for boundary in range(per_layer, circuit_size, per_layer):
                ax.axvline(boundary, color="gray", lw=0.5, alpha=0.4)
        ax.set_yscale("log")
        ax.set_title(variant)
        ax.set_xlabel("Gate (Heisenberg order)")
        ax.set_ylabel("Pauli terms")
        ax.legend(fontsize=8)
    for vi in range(len(variants), nrows * ncols):
        axes[vi // ncols][vi % ncols].axis("off")
    fig.suptitle(
        f"Pauli term growth per gate — layer boundaries in gray ({knob_note})",
        fontsize=10,
    )
    fig.tight_layout()
    growth_path = prefix.parent / (prefix.name + "_growth.png")
    fig.savefig(growth_path, dpi=150)
    print(f"Wrote {growth_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
