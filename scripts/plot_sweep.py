#!/usr/bin/env python3
"""plot_sweep.py — visualize parameter-sweep results across backends.

Reads BenchmarkSweepResult JSON files (one per backend, same config) and emits
a two-panel figure:
  left  — expectation value vs swept angle, one curve per backend
          (plus the reference curve when the sweep carries one)
  right — per-point runtime vs angle (log scale). The Julia surrogate
          evaluates a prebuilt path graph per angle, while external engines
          re-propagate the full circuit, so the gap is the build-once /
          evaluate-many advantage.

Usage:
  python3 scripts/plot_sweep.py results/sweep_medium_*.json \
      --out-prefix results/sweep_medium
"""

import argparse
import json
import sys
from pathlib import Path

BACKEND_COLOR = {
    "julia_pauliprop": "tab:purple",
    "rust_pauliprop": "tab:orange",
    "cpp_pauliengine": "tab:blue",
    "cuda_cupauliprop": "tab:green",
}
BACKEND_STYLE = {
    "julia_pauliprop": (3.0, "-"),
    "rust_pauliprop": (2.0, "--"),
    "cpp_pauliengine": (2.0, "-."),
    "cuda_cupauliprop": (2.0, ":"),
}


def load_sweeps(paths):
    sweeps = []
    for path in paths:
        with open(path) as f:
            data = json.load(f)
        if "results" not in data or "backend" not in data:
            print(f"WARNING: {path} is not a sweep result JSON; skipped", file=sys.stderr)
            continue
        sweeps.append(data)
    return sweeps


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sweeps", nargs="+", help="BenchmarkSweepResult JSON files")
    parser.add_argument("--out-prefix", default="results/sweep_plot")
    args = parser.parse_args()

    sweeps = load_sweeps(args.sweeps)
    if not sweeps:
        print("ERROR: no valid sweep files", file=sys.stderr)
        return 1

    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("ERROR: matplotlib is required for plot_sweep.py", file=sys.stderr)
        return 1

    fig, (ax_exp, ax_rt) = plt.subplots(1, 2, figsize=(13, 5))

    reference_drawn = False
    for sweep in sweeps:
        backend = sweep["backend"]
        points = sweep["results"]
        angles = [p["angle"] for p in points]
        expectations = [p["expectation"] for p in points]
        runtimes = [p["runtime_sec"] for p in points]
        lw, ls = BACKEND_STYLE.get(backend, (1.5, "-"))
        color = BACKEND_COLOR.get(backend)

        total_rt = sum(runtimes)
        build = sweep.get("metadata", {}).get("build_time_sec")
        label = f"{backend} ({total_rt:.2f}s"
        label += f" + {build:.2f}s build)" if build is not None else ")"

        ax_exp.plot(angles, expectations, color=color, linewidth=lw, linestyle=ls,
                    marker="o", markersize=3.5, label=label, alpha=0.9)
        ax_rt.plot(angles, runtimes, color=color, linewidth=lw, linestyle=ls,
                   marker="o", markersize=3.5, label=backend, alpha=0.9)

        if not reference_drawn:
            refs = [p.get("reference") for p in points]
            if all(r is not None for r in refs):
                ax_exp.plot(angles, refs, color="black", linewidth=1.0,
                            linestyle="-", alpha=0.6, label="reference", zorder=1)
                reference_drawn = True

    meta = sweeps[0].get("metadata", {})
    observable = meta.get("observable", "?")
    nq = meta.get("nqubits", "?")
    task_id = sweeps[0].get("task_id", "")

    ax_exp.set_xlabel(r"Swept angle $\theta$")
    ax_exp.set_ylabel(rf"$\langle {observable} \rangle$")
    ax_exp.set_title(f"Expectation vs angle — {nq} qubits")
    ax_exp.legend(fontsize=8)
    ax_exp.grid(alpha=0.25)

    ax_rt.set_xlabel(r"Swept angle $\theta$")
    ax_rt.set_ylabel("Per-point runtime (s)")
    ax_rt.set_yscale("log")
    ax_rt.set_title("Per-point cost: surrogate eval vs re-propagation")
    ax_rt.legend(fontsize=8)
    ax_rt.grid(alpha=0.25)

    fig.suptitle(task_id, fontsize=10)
    fig.tight_layout()

    prefix = Path(args.out_prefix)
    prefix.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(prefix.with_suffix(".png"), dpi=150)
    print(f"Wrote {prefix.with_suffix('.png')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
