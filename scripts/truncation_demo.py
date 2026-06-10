# -*- coding: utf-8 -*-
"""
Truncation Demo Animation (growth with branch pruning)
------------------------------------------------------
- Reuses tree generation/layout from plot.py
- During layer-wise growth, part of newborn branches are truncated
- Truncated branches are shown in red/gray and stop expanding
- The final visible tree becomes progressively sparse
"""

import colorsys
import random
from math import ceil
from typing import Dict, List, Optional, Set, Tuple

import matplotlib.pyplot as plt
import numpy as np
from matplotlib.animation import FuncAnimation, PillowWriter
from matplotlib.collections import LineCollection

from plot import Node, build_demo_tree


DEFAULT_NODE_COLOR = "#2e86de"
KEPT_EDGE_COLOR = "#5d86e8"
PRUNED_EDGE_COLOR = "#b4bcc9"
PRUNED_NODE_COLOR = "#c45858"


def _depth_linear_prob(
    depth: int,
    max_depth: int,
    p_start: float,
    p_end: float,
) -> float:
    if max_depth <= 1:
        return p_end
    t = (depth - 1) / (max_depth - 1)
    return p_start + (p_end - p_start) * t


def simulate_layer_truncation(
    nodes: Dict[int, Node],
    seed: int,
    prune_prob_start: float = 0.12,
    prune_prob_end: float = 0.42,
    rescue_until_depth: int = 2,
    min_keep_ratio: float = 0.35,
) -> Tuple[
    List[int],
    Dict[int, List[int]],
    Dict[int, List[int]],
    Dict[int, List[int]],
    Dict[int, float],
]:
    """
    Simulate branch truncation at each depth.
    Returns per-step candidate/kept/pruned node ids plus prune probability.
    """
    if not nodes:
        return [], {}, {}, {}, {}

    rng = random.Random(seed + 991)
    root_id = 0
    real_L = max(n.depth for n in nodes.values())

    by_depth: Dict[int, List[int]] = {}
    for nid, n in nodes.items():
        by_depth.setdefault(n.depth, []).append(nid)

    step_depths: List[int] = []
    candidates_by_step: Dict[int, List[int]] = {}
    kept_by_step: Dict[int, List[int]] = {}
    pruned_by_step: Dict[int, List[int]] = {}
    prune_prob_by_step: Dict[int, float] = {}

    alive: Set[int] = {root_id}
    for depth in range(1, real_L + 1):
        if not alive:
            break

        layer_ids = by_depth.get(depth, [])
        if not layer_ids:
            continue

        candidates = [
            nid
            for nid in layer_ids
            if nodes[nid].parent is not None and nodes[nid].parent in alive
        ]
        if not candidates:
            continue

        p = _depth_linear_prob(
            depth=depth,
            max_depth=real_L,
            p_start=prune_prob_start,
            p_end=prune_prob_end,
        )
        kept: List[int] = []
        pruned: List[int] = []
        for nid in candidates:
            if rng.random() < p:
                pruned.append(nid)
            else:
                kept.append(nid)

        # Keep at least part of each layer so truncation is visible but not too aggressive.
        min_keep = max(0, ceil(len(candidates) * min_keep_ratio))
        if depth <= rescue_until_depth:
            min_keep = max(1, min_keep)
        min_keep = min(min_keep, len(candidates))
        if len(kept) < min_keep and pruned:
            rng.shuffle(pruned)
            need = min_keep - len(kept)
            recovered = pruned[:need]
            kept.extend(recovered)
            pruned = pruned[need:]

        step_depths.append(depth)
        candidates_by_step[depth] = candidates
        kept_by_step[depth] = kept
        pruned_by_step[depth] = pruned
        prune_prob_by_step[depth] = p
        alive = set(kept)

    return step_depths, candidates_by_step, kept_by_step, pruned_by_step, prune_prob_by_step


def create_truncation_animation(
    L: int = 9,
    gate_schedule: Optional[List[str]] = None,
    root_pauli_str: str = "ZZZZZ",
    seed: int = 12,
    split_prob_R: float = 0.85,
    max_nodes: int = 120,
    mixed_gates_per_layer: bool = True,
    layer_x_spacing: float = 1.15,
    vertical_gap_base: float = 1.80,
    prune_prob_start: float = 0.12,
    prune_prob_end: float = 0.42,
    rescue_until_depth: int = 2,
    min_keep_ratio: float = 0.35,
    frames_per_layer: int = 14,
    hold_frames: int = 36,
    interval_ms: int = 95,
    node_size: int = 650,
    save_path: Optional[str] = None,
):
    if gate_schedule is None:
        gate_schedule = list("RCRRCRRCR")[:L]

    nodes = build_demo_tree(
        L=L,
        gate_schedule=gate_schedule,
        root_pauli_str=root_pauli_str,
        split_prob_R=split_prob_R,
        max_nodes=max_nodes,
        seed=seed,
        merge_same_nodes=False,  # keep a strict tree for clear truncation semantics
        mixed_gates_per_layer=mixed_gates_per_layer,
        layer_x_spacing=layer_x_spacing,
        vertical_gap_base=vertical_gap_base,
    )
    root_id = 0
    root = nodes[root_id]
    real_L = max(n.depth for n in nodes.values())

    (
        step_depths,
        candidates_by_step,
        kept_by_step,
        pruned_by_step,
        prune_prob_by_step,
    ) = simulate_layer_truncation(
        nodes=nodes,
        seed=seed,
        prune_prob_start=prune_prob_start,
        prune_prob_end=prune_prob_end,
        rescue_until_depth=rescue_until_depth,
        min_keep_ratio=min_keep_ratio,
    )
    if not step_depths:
        raise ValueError("No growth steps available for truncation animation.")

    kept_global: Set[int] = {root_id}
    pruned_global: Set[int] = set()
    for d in step_depths:
        kept_global.update(kept_by_step[d])
        pruned_global.update(pruned_by_step[d])

    shown_before_steps: List[Set[int]] = []
    shown_acc: Set[int] = {root_id}
    for d in step_depths:
        shown_before_steps.append(set(shown_acc))
        shown_acc.update(candidates_by_step[d])
    shown_final = set(shown_acc)

    kept_before_steps: List[Set[int]] = []
    kept_acc: Set[int] = {root_id}
    for d in step_depths:
        kept_before_steps.append(set(kept_acc))
        kept_acc.update(kept_by_step[d])
    kept_final = set(kept_acc)
    final_frontier = set(kept_by_step[step_depths[-1]])

    node_pos = {nid: (n.x, n.y) for nid, n in nodes.items()}

    unique_pauli_strings = sorted({n.pauli_str for n in nodes.values()})
    pauli_colors = {}
    total_colors = max(1, len(unique_pauli_strings))
    for i, s in enumerate(unique_pauli_strings):
        pauli_colors[s] = colorsys.hsv_to_rgb(i / total_colors, 0.45, 0.82)
    node_color = {nid: pauli_colors.get(n.pauli_str, DEFAULT_NODE_COLOR) for nid, n in nodes.items()}

    total_growth_frames = len(step_depths) * frames_per_layer
    total_frames = total_growth_frames + hold_frames

    fig, ax = plt.subplots(figsize=(12, 8), dpi=120)
    fig.patch.set_facecolor("#f6f7fb")
    ax.set_facecolor("#f6f7fb")
    ax.grid(alpha=0.08, linewidth=0.6)
    ax.set_xlabel("Layer index (decreases from L to 0 toward the left)", fontsize=11)
    ax.set_ylabel("Branch index", fontsize=11)
    ax.set_yticks([])
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    xticks = [k * layer_x_spacing for k in range(real_L + 1)]
    ax.set_xticks(xticks)
    ax.set_xticklabels([str(k) for k in range(real_L + 1)])

    xs = [n.x for n in nodes.values()]
    current_xlim = [max(xs) + 1.6, max(xs) + 2.6]
    current_ylim = [-2.0, 2.0]
    base_x_span = abs(current_xlim[0] - current_xlim[1])
    base_y_span = abs(current_ylim[1] - current_ylim[0])
    max_seen_x_span = base_x_span
    max_seen_y_span = base_y_span

    kept_edges = LineCollection([], colors=KEPT_EDGE_COLOR, linewidths=1.35, alpha=0.97, zorder=2)
    pruned_edges = LineCollection([], colors=PRUNED_EDGE_COLOR, linewidths=1.15, alpha=0.90, zorder=1)
    growing_edges = LineCollection([], colors=KEPT_EDGE_COLOR, linewidths=1.55, alpha=1.0, zorder=4)
    ax.add_collection(pruned_edges)
    ax.add_collection(kept_edges)
    ax.add_collection(growing_edges)

    kept_nodes = ax.scatter([], [], s=[], color=DEFAULT_NODE_COLOR, edgecolors="white", linewidths=0.6, zorder=5)
    pruned_nodes = ax.scatter([], [], s=[], color=PRUNED_EDGE_COLOR, edgecolors="white", linewidths=0.5, alpha=0.85, zorder=3)
    growing_nodes = ax.scatter([], [], s=[], color=DEFAULT_NODE_COLOR, edgecolors="white", linewidths=0.7, alpha=0.95, zorder=6)
    pruned_marks = ax.scatter([], [], s=[], marker="x", color=PRUNED_NODE_COLOR, linewidths=1.4, alpha=0.95, zorder=7)

    root_text = ax.text(
        root.x,
        root.y - 1.0,
        r"$P = Z \otimes Z \otimes Z \otimes Z \otimes Z$",
        ha="center",
        va="top",
        fontsize=12,
        color="#222",
        zorder=8,
    )
    info_text = ax.text(
        0.01,
        0.98,
        "",
        transform=ax.transAxes,
        ha="left",
        va="top",
        fontsize=10.5,
        color="#333",
        zorder=8,
    )

    def interp(a: float, b: float, t: float) -> float:
        return a + (b - a) * t

    def target_axes_for_visible(visible_ids: Set[int]):
        if not visible_ids:
            visible_ids = {root_id}
        vx = [node_pos[i][0] for i in visible_ids]
        vy = [node_pos[i][1] for i in visible_ids]
        xmin, xmax = min(vx), max(vx)
        ymin, ymax = min(vy), max(vy)
        wx = max(4.0, xmax - xmin)
        wy = max(4.0, ymax - ymin)
        mx = 0.15 * wx + 0.9
        my = 0.18 * wy + 1.0
        return [xmax + mx, xmin - mx], [ymin - my, ymax + my]

    def _node_offsets(ids: List[int]) -> np.ndarray:
        if not ids:
            return np.empty((0, 2), dtype=float)
        return np.array([node_pos[nid] for nid in ids], dtype=float)

    def update(frame: int):
        nonlocal current_xlim, current_ylim, max_seen_x_span, max_seen_y_span

        if frame < total_growth_frames:
            step_idx = frame // frames_per_layer
            sub = (frame % frames_per_layer) / max(1, frames_per_layer - 1)
            depth = step_depths[step_idx]
            candidates = candidates_by_step[depth]
            kept_now = set(kept_by_step[depth])
            pruned_now = set(pruned_by_step[depth])
            shown_ids = shown_before_steps[step_idx]
            kept_ids = kept_before_steps[step_idx]
            prune_prob = prune_prob_by_step[depth]
            target_visible = set(shown_ids) | set(candidates)
        else:
            sub = 1.0
            depth = None
            candidates = []
            kept_now = set()
            pruned_now = set()
            shown_ids = set(shown_final)
            kept_ids = set(kept_final)
            prune_prob = prune_prob_by_step[step_depths[-1]]
            target_visible = set(shown_ids)

        tx, ty = target_axes_for_visible(target_visible)
        smooth = 0.20 if frame > 0 else 1.0
        current_xlim = [interp(current_xlim[0], tx[0], smooth), interp(current_xlim[1], tx[1], smooth)]
        current_ylim = [interp(current_ylim[0], ty[0], smooth), interp(current_ylim[1], ty[1], smooth)]
        ax.set_xlim(current_xlim[0], current_xlim[1])
        ax.set_ylim(current_ylim[0], current_ylim[1])

        span_x = abs(current_xlim[0] - current_xlim[1])
        span_y = abs(current_ylim[1] - current_ylim[0])
        max_seen_x_span = max(max_seen_x_span, span_x)
        max_seen_y_span = max(max_seen_y_span, span_y)
        zoom_ratio = max(max_seen_x_span / max(base_x_span, 1e-9), max_seen_y_span / max(base_y_span, 1e-9))
        node_zoom = max(0.28, zoom_ratio ** -0.62)

        kept_segments = []
        pruned_segments = []
        for nid in shown_ids:
            if nid == root_id:
                continue
            pid = nodes[nid].parent
            if pid is None:
                continue
            segment = [node_pos[pid], node_pos[nid]]
            if nid in pruned_global:
                pruned_segments.append(segment)
            else:
                kept_segments.append(segment)
        kept_edges.set_segments(kept_segments)
        pruned_edges.set_segments(pruned_segments)

        grow_segments = []
        grow_colors = []
        for nid in candidates:
            pid = nodes[nid].parent
            if pid is None:
                continue
            x0, y0 = node_pos[pid]
            x1, y1 = node_pos[nid]
            xm, ym = interp(x0, x1, sub), interp(y0, y1, sub)
            grow_segments.append([(x0, y0), (xm, ym)])
            if nid in pruned_now:
                grow_colors.append((0.77, 0.35, 0.35, 1.0))
            else:
                grow_colors.append((0.36, 0.53, 0.91, 1.0))
        growing_edges.set_segments(grow_segments)
        growing_edges.set_color(grow_colors if grow_colors else [(0.2, 0.2, 0.2, 0.0)])

        kept_hist_ids = sorted([nid for nid in shown_ids if nid in kept_global])
        kept_nodes.set_offsets(_node_offsets(kept_hist_ids))
        kept_nodes.set_color([node_color[nid] for nid in kept_hist_ids] if kept_hist_ids else [(0.2, 0.2, 0.2, 0.0)])
        kept_nodes.set_sizes(np.full(len(kept_hist_ids), node_size * node_zoom, dtype=float))

        pruned_hist_ids = sorted([nid for nid in shown_ids if nid in pruned_global])
        pruned_nodes.set_offsets(_node_offsets(pruned_hist_ids))
        pruned_nodes.set_color([(*node_color[nid], 0.35) for nid in pruned_hist_ids] if pruned_hist_ids else [(0.2, 0.2, 0.2, 0.0)])
        pruned_nodes.set_sizes(np.full(len(pruned_hist_ids), node_size * node_zoom * 0.82, dtype=float))

        if candidates:
            offsets = []
            colors = []
            for nid in candidates:
                pid = nodes[nid].parent
                if pid is None:
                    continue
                x0, y0 = node_pos[pid]
                x1, y1 = node_pos[nid]
                offsets.append((interp(x0, x1, sub), interp(y0, y1, sub)))
                colors.append(PRUNED_NODE_COLOR if nid in pruned_now else node_color[nid])
            growing_nodes.set_offsets(np.array(offsets, dtype=float))
            growing_nodes.set_color(colors)
            growing_nodes.set_sizes(np.full(len(offsets), node_size * node_zoom * (0.30 + 0.70 * sub), dtype=float))
        else:
            growing_nodes.set_offsets(np.empty((0, 2), dtype=float))
            growing_nodes.set_color([(0.2, 0.2, 0.2, 0.0)])
            growing_nodes.set_sizes(np.empty((0,), dtype=float))

        mark_ids = set(pruned_hist_ids)
        if candidates and sub >= 0.68:
            mark_ids.update(pruned_now)
        mark_sorted = sorted(mark_ids)
        pruned_marks.set_offsets(_node_offsets(mark_sorted))
        pruned_marks.set_sizes(np.full(len(mark_sorted), node_size * node_zoom * 0.24, dtype=float))

        kept_seen = len([nid for nid in shown_ids if nid in kept_global]) + len(kept_now)
        pruned_seen = len([nid for nid in shown_ids if nid in pruned_global]) + len(pruned_now)
        shown_count = len(shown_ids) + len(candidates)
        frontier_size = len(kept_now) if depth is not None else len(final_frontier)

        info_text.set_text(
            f"Truncation demo | shown: {shown_count}/{len(nodes)} | "
            f"kept: {kept_seen} | pruned: {pruned_seen} | frontier: {frontier_size}"
        )
        root_text.set_position((root.x, root.y - 1.0))

        if depth is not None:
            x_layer = real_L - depth
            ax.set_title(
                f"Pauli Truncation Demo | growing layer x={x_layer} | prune p={prune_prob:.2f}",
                fontsize=13,
                pad=10,
            )
        else:
            ax.set_title("Pauli Truncation Demo | growth finished (sparser tree)", fontsize=13, pad=10)

        return [
            kept_edges,
            pruned_edges,
            growing_edges,
            kept_nodes,
            pruned_nodes,
            growing_nodes,
            pruned_marks,
            root_text,
            info_text,
        ]

    ani = FuncAnimation(
        fig,
        update,
        frames=total_frames,
        interval=interval_ms,
        blit=False,
        repeat=True,
    )

    if save_path:
        fps = max(1, int(1000 / interval_ms))
        if save_path.lower().endswith(".gif"):
            ani.save(save_path, writer=PillowWriter(fps=fps))
        else:
            ani.save(save_path, fps=fps, dpi=140)

    return fig, ani, nodes


if __name__ == "__main__":
    from pathlib import Path

    _OUT_DIR = Path(__file__).resolve().parent.parent / "docs" / "figures"
    _OUT_DIR.mkdir(parents=True, exist_ok=True)
    fig, ani, nodes = create_truncation_animation(
        L=9,
        gate_schedule=list("RCRRCRRCR"),
        root_pauli_str="ZZZZZ",
        split_prob_R=0.85,
        max_nodes=120,
        seed=12,
        prune_prob_start=0.12,
        prune_prob_end=0.42,
        rescue_until_depth=2,
        min_keep_ratio=0.35,
        frames_per_layer=14,
        hold_frames=36,
        interval_ms=95,
        save_path=str(_OUT_DIR / "pauli_truncation_demo.gif"),
    )
    plt.show()
