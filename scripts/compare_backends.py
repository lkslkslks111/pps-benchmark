#!/usr/bin/env python3
"""compare_backends.py — cross-backend comparison table and plots.

Reads single-run BenchmarkResult JSON files (one per backend) for the same
task, then emits:
  1. A Markdown comparison table (stdout and <out-prefix>.md)
  2. Bar charts for runtime / throughput / peak terms (<out-prefix>.png,
     skipped when matplotlib is unavailable)

Usage:
  python3 scripts/compare_backends.py results/medium_*.json
  python3 scripts/compare_backends.py --out-prefix results/comparison_medium results/medium_*.json
"""

import argparse
import json
import sys
from pathlib import Path

BASELINE_BACKEND = "julia_pauliprop"

LANGUAGE = {
    "julia_pauliprop": "Julia",
    "rust_pauliprop": "Rust",
    "cpp_pauliengine": "C++",
    "cuda_cupauliprop": "CUDA",
    "python_cuquantum": "Python",
}


def load_results(paths):
    results = []
    for path in paths:
        with open(path) as f:
            data = json.load(f)
        if "backend" not in data or "runtime_sec" not in data:
            print(f"WARNING: {path} is not a BenchmarkResult JSON; skipped", file=sys.stderr)
            continue
        data["_path"] = str(path)
        results.append(data)
    return results


def engine_label(result):
    backend = result["backend"]
    label = LANGUAGE.get(backend, "?")
    if backend == "cpp_pauliengine":
        version = result.get("metadata", {}).get("pauliengine_version", "")
        if version == "python_fallback":
            label += " (py fallback)"
    return label


def truncation_label(result):
    applied = result.get("metadata", {}).get("truncation_applied")
    if not applied:
        threshold = result.get("metadata", {}).get("truncation_threshold")
        return f"threshold={threshold:g}" if threshold is not None else "?"
    parts = []
    if applied.get("coefficient_threshold") is not None:
        parts.append(f"coeff={applied['coefficient_threshold']:g}")
    for key, short in (
        ("max_terms", "topK"),
        ("pauli_weight_cutoff", "weight"),
        ("max_freq", "freq"),
        ("max_weight", "lowesa_w"),
    ):
        if applied.get(key) is not None:
            parts.append(f"{short}={applied[key]}")
    return f"{applied.get('method', '?')} ({', '.join(parts)})" if parts else applied.get("method", "?")


def fmt(value, spec=".3g", missing="—"):
    return format(value, spec) if value is not None else missing


def build_table(results):
    baseline = next((r for r in results if r["backend"] == BASELINE_BACKEND), None)
    base_runtime = baseline["runtime_sec"] if baseline else None

    header = (
        "| Backend | Language | Truncation | Runtime (s) | Speedup vs Julia | "
        "Throughput (terms/s) | Final terms | Peak terms | Memory (MB) | Abs. error |"
    )
    rule = "|" + "---|" * 10
    rows = [header, rule]
    for r in sorted(results, key=lambda r: r["runtime_sec"]):
        speedup = (
            fmt(base_runtime / r["runtime_sec"], ".2f") + "x"
            if base_runtime and r["runtime_sec"] > 0
            else "—"
        )
        rows.append(
            "| {backend} | {lang} | {trunc} | {runtime} | {speedup} | {tput} | "
            "{final} | {peak} | {mem} | {err} |".format(
                backend=r["backend"],
                lang=engine_label(r),
                trunc=truncation_label(r),
                runtime=fmt(r["runtime_sec"], ".4g"),
                speedup=speedup,
                tput=fmt(r.get("throughput_terms_per_sec")),
                final=r["final_terms"],
                peak=fmt(r.get("peak_terms"), "d"),
                mem=fmt(r["memory_bytes"] / 1e6, ".1f"),
                err=fmt(r.get("absolute_error"), ".2e"),
            )
        )
    return "\n".join(rows)


def plot(results, out_png):
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("NOTE: matplotlib not available; skipping plots", file=sys.stderr)
        return False

    results = sorted(results, key=lambda r: r["runtime_sec"])
    names = [f"{r['backend']}\n({engine_label(r)})" for r in results]

    fig, axes = plt.subplots(1, 3, figsize=(14, 4.5))

    axes[0].bar(names, [r["runtime_sec"] for r in results], color="steelblue")
    axes[0].set_ylabel("Runtime (s)")
    axes[0].set_title("Runtime (lower is better)")
    axes[0].set_yscale("log")

    tput = [(r.get("throughput_terms_per_sec") or 0) for r in results]
    axes[1].bar(names, tput, color="seagreen")
    axes[1].set_ylabel("Pauli terms / s")
    axes[1].set_title("Throughput (higher is better)")

    peaks = [(r.get("peak_terms") or 0) for r in results]
    axes[2].bar(names, peaks, color="indianred")
    axes[2].set_ylabel("Peak Pauli terms")
    axes[2].set_title("Peak term count")

    task_id = results[0].get("task_id", "")
    fig.suptitle(f"Backend comparison — {task_id}")
    for ax in axes:
        ax.tick_params(axis="x", labelsize=8)
    fig.tight_layout()
    fig.savefig(out_png, dpi=150)
    print(f"Wrote {out_png}")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", nargs="+", help="BenchmarkResult JSON files (one per backend)")
    parser.add_argument(
        "--out-prefix",
        default=None,
        help="Write <prefix>.md and <prefix>.png (default: print table only)",
    )
    args = parser.parse_args()

    results = load_results(args.results)
    if not results:
        print("ERROR: no valid result files", file=sys.stderr)
        return 1

    task_ids = {r.get("task_id") for r in results}
    if len(task_ids) > 1:
        print(f"WARNING: mixing task_ids: {sorted(task_ids)}", file=sys.stderr)

    table = build_table(results)
    print(table)

    if args.out_prefix:
        prefix = Path(args.out_prefix)
        prefix.parent.mkdir(parents=True, exist_ok=True)
        md_path = prefix.with_suffix(".md")
        md_path.write_text(f"# Backend comparison — {sorted(task_ids)[0]}\n\n{table}\n")
        print(f"Wrote {md_path}", file=sys.stderr)
        plot(results, prefix.with_suffix(".png"))

    return 0


if __name__ == "__main__":
    sys.exit(main())
