# -*- coding: utf-8 -*-
"""
Pauli Propagation Demo Animation (layer-wise growth)
---------------------------------------------------
- x axis is layer index (right -> left)
- root label: P = Z ⊗ Z ⊗ Z ⊗ Z ⊗ Z
- gates can be mixed per Pauli string in each layer
- node color encodes Pauli string
- nodes in the same layer appear together
- camera auto-zooms during growth
"""

from dataclasses import dataclass, field
import colorsys
import random
from typing import Dict, List, Optional, Tuple

import matplotlib.pyplot as plt
import numpy as np
from matplotlib.animation import FuncAnimation, PillowWriter
from matplotlib.collections import LineCollection


DEFAULT_NODE_COLOR = "#2e86de"


@dataclass
class Node:
    id: int
    parent: Optional[int]
    parents: List[int] = field(default_factory=list)
    children: List[int] = field(default_factory=list)
    depth: int = 0
    x: float = 0.0
    y: float = 0.0
    basis: str = "Z"
    pauli_str: str = ""
    birth_step: int = 0


def mutate_pauli_string(s: str, rng: random.Random) -> str:
    """Small random mutation for demo only (not strict physical rule)."""
    if not s:
        return s
    i = rng.randrange(len(s))
    choices = ["I", "X", "Y", "Z"]
    new_char = rng.choice([c for c in choices if c != s[i].upper()])
    return s[:i] + new_char + s[i + 1 :]


def choose_other_basis(parent_basis: str, rng: random.Random) -> str:
    pool = [b for b in ["I", "X", "Y", "Z"] if b != parent_basis]
    return rng.choice(pool)


def stable_string_score(s: str) -> int:
    score = 0
    for i, ch in enumerate(s):
        score = (score * 131 + ord(ch) + i) % 1_000_000_007
    return score


def choose_gate_for_pauli_string(pauli_str: str, depth: int, seed: int) -> str:
    score = stable_string_score(pauli_str) + depth * 97 + seed * 53
    return "R" if (score % 2 == 0) else "C"


def build_demo_tree(
    L: int,
    gate_schedule: List[str],
    root_pauli_str: str = "ZZZZZ",
    split_prob_R: float = 0.70,
    max_nodes: int = 120,
    seed: int = 7,
    merge_same_nodes: bool = True,
    mixed_gates_per_layer: bool = True,
    layer_x_spacing: float = 1.15,
    vertical_gap_base: float = 1.80,
) -> Dict[int, Node]:
    """Build demo graph. With merge enabled it becomes a layered DAG."""
    if len(gate_schedule) < L:
        raise ValueError(
            f"gate_schedule length is insufficient: need >= {L}, got {len(gate_schedule)}"
        )

    rng = random.Random(seed)
    nodes: Dict[int, Node] = {}
    next_id = 0

    root_basis = root_pauli_str[0].upper() if root_pauli_str else "Z"
    root = Node(
        id=next_id,
        parent=None,
        parents=[],
        depth=0,
        basis=root_basis,
        pauli_str=root_pauli_str.upper(),
        birth_step=0,
    )
    nodes[root.id] = root
    next_id += 1

    frontier = [root.id]

    for depth in range(L):
        layer_base_gate = gate_schedule[depth].upper()
        if layer_base_gate not in {"R", "C"}:
            raise ValueError(f"Unknown gate type '{layer_base_gate}', only supports 'R' and 'C'")

        next_frontier: List[int] = []
        next_frontier_set = set()
        layer_merge_map: Dict[Tuple[str, str], int] = {}
        layer_gate_by_pauli: Dict[str, str] = {}

        if mixed_gates_per_layer:
            layer_pauli_strings = sorted({nodes[pid].pauli_str for pid in frontier})
            for pstr in layer_pauli_strings:
                layer_gate_by_pauli[pstr] = choose_gate_for_pauli_string(
                    pauli_str=pstr,
                    depth=depth,
                    seed=seed,
                )
            # Force diversity when the layer has multiple Pauli strings.
            if len(layer_pauli_strings) >= 2 and len(set(layer_gate_by_pauli.values())) == 1:
                flip_key = layer_pauli_strings[-1]
                layer_gate_by_pauli[flip_key] = "C" if layer_gate_by_pauli[flip_key] == "R" else "R"

        for pid in frontier:
            parent = nodes[pid]
            gate = layer_gate_by_pauli.get(parent.pauli_str, layer_base_gate)

            if gate == "C":
                nchild = 1
            elif gate == "R":
                nchild = 2 if (rng.random() < split_prob_R) else 1

            if nchild == 1:
                child_basis_list = [parent.basis]
            else:
                child_basis_list = [parent.basis, choose_other_basis(parent.basis, rng)]

            for k in range(nchild):
                pauli_child = parent.pauli_str
                if nchild == 2 and k == 1:
                    pauli_child = mutate_pauli_string(pauli_child, rng)

                merge_key = (child_basis_list[k], pauli_child)
                cid = layer_merge_map.get(merge_key) if merge_same_nodes else None

                if cid is None:
                    if len(nodes) >= max_nodes:
                        continue
                    cid = next_id
                    next_id += 1
                    child = Node(
                        id=cid,
                        parent=pid,
                        parents=[pid],
                        depth=depth + 1,
                        basis=child_basis_list[k],
                        pauli_str=pauli_child,
                        birth_step=depth + 1,
                    )
                    nodes[cid] = child
                    if merge_same_nodes:
                        layer_merge_map[merge_key] = cid
                else:
                    child = nodes[cid]
                    if pid not in child.parents:
                        child.parents.append(pid)
                    if child.parent is None:
                        child.parent = pid

                if cid not in nodes[pid].children:
                    nodes[pid].children.append(cid)

                if cid not in next_frontier_set:
                    next_frontier_set.add(cid)
                    next_frontier.append(cid)

        frontier = next_frontier
        if not frontier:
            break

    real_L = max(n.depth for n in nodes.values())

    for n in nodes.values():
        n.x = (real_L - n.depth) * layer_x_spacing

    # Layered layout for DAG: place each node near average y of its parents.
    by_depth: Dict[int, List[int]] = {}
    for nid, node in nodes.items():
        by_depth.setdefault(node.depth, []).append(nid)
    max_layer_nodes = max((len(ids) for ids in by_depth.values()), default=1)
    extra_gap = max(0, max_layer_nodes - 10) * 0.06
    vertical_gap = min(3.20, vertical_gap_base + extra_gap)
    nodes[root.id].y = 0.0

    for d in range(1, real_L + 1):
        ids = by_depth.get(d, [])
        if not ids:
            continue

        desired_y: Dict[int, float] = {}
        for nid in ids:
            parent_ids = nodes[nid].parents
            if parent_ids:
                desired_y[nid] = sum(nodes[pid].y for pid in parent_ids) / len(parent_ids)
            else:
                desired_y[nid] = 0.0

        ordered = sorted(ids, key=lambda nid: (desired_y[nid], nid))
        placed_y: Dict[int, float] = {}

        for i, nid in enumerate(ordered):
            y = desired_y[nid]
            if i > 0:
                prev_nid = ordered[i - 1]
                y = max(y, placed_y[prev_nid] + vertical_gap)
            placed_y[nid] = y

        for i in range(len(ordered) - 2, -1, -1):
            nid = ordered[i]
            next_nid = ordered[i + 1]
            upper_bound = placed_y[next_nid] - vertical_gap
            if placed_y[nid] > upper_bound:
                placed_y[nid] = upper_bound

        for nid in ordered:
            nodes[nid].y = placed_y[nid]

    all_y = [n.y for n in nodes.values()]
    center_y = (min(all_y) + max(all_y)) / 2.0 if all_y else 0.0
    for n in nodes.values():
        n.y -= center_y

    return nodes


def create_pauli_propagation_animation_layerwise(
    L: int = 9,
    gate_schedule: Optional[List[str]] = None,
    root_pauli_str: str = "ZZZZZ",
    seed: int = 12,
    split_prob_R: float = 0.75,
    max_nodes: int = 80,
    interval_ms: int = 120,
    frames_per_layer: int = 12,
    hold_frames: int = 30,
    node_size: int = 850,
    merge_same_nodes: bool = True,
    mixed_gates_per_layer: bool = True,
    layer_x_spacing: float = 1.15,
    vertical_gap_base: float = 1.80,
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
        merge_same_nodes=merge_same_nodes,
        mixed_gates_per_layer=mixed_gates_per_layer,
        layer_x_spacing=layer_x_spacing,
        vertical_gap_base=vertical_gap_base,
    )

    root_id = 0
    root = nodes[root_id]
    real_L = max(n.depth for n in nodes.values())

    layers: Dict[int, List[int]] = {}
    for nid, n in nodes.items():
        layers.setdefault(n.birth_step, []).append(nid)

    grow_steps = sorted([k for k in layers.keys() if k >= 1])
    num_grow_layers = len(grow_steps)
    unique_pauli_strings = sorted({n.pauli_str for n in nodes.values()})
    pauli_colors = {}
    total_colors = max(1, len(unique_pauli_strings))
    for i, s in enumerate(unique_pauli_strings):
        h = i / total_colors
        sat = 0.45
        val = 0.82
        pauli_colors[s] = colorsys.hsv_to_rgb(h, sat, val)

    xs = [n.x for n in nodes.values()]

    fig, ax = plt.subplots(figsize=(12, 8), dpi=120)
    fig.patch.set_facecolor("#f6f7fb")
    ax.set_facecolor("#f6f7fb")

    x_margin0 = 1.2
    current_xlim = [max(xs) + x_margin0 + 0.5, max(xs) + x_margin0 + 1.5]
    current_ylim = [-2.0, 2.0]
    base_x_span = abs(current_xlim[0] - current_xlim[1])
    base_y_span = abs(current_ylim[1] - current_ylim[0])
    max_seen_x_span = base_x_span
    max_seen_y_span = base_y_span
    current_node_zoom = 1.0

    total_growth_frames = num_grow_layers * frames_per_layer
    total_frames = total_growth_frames + hold_frames

    xticks = [k * layer_x_spacing for k in range(real_L + 1)]

    def interp(a, b, t):
        return a + (b - a) * t

    def target_axes_for_visible(visible_ids: set):
        vx = [nodes[i].x for i in visible_ids]
        vy = [nodes[i].y for i in visible_ids]
        xmin, xmax = min(vx), max(vx)
        ymin, ymax = min(vy), max(vy)

        wx = max(4.0, xmax - xmin)
        wy = max(4.0, ymax - ymin)
        mx = 0.15 * wx + 0.9
        my = 0.18 * wy + 1.0

        return [xmax + mx, xmin - mx], [ymin - my, ymax + my]

    def parent_ids_of(child: Node) -> List[int]:
        if child.parents:
            return child.parents
        if child.parent is not None:
            return [child.parent]
        return []

    # Precompute static node attributes used every frame.
    node_pos = {nid: (n.x, n.y) for nid, n in nodes.items()}
    node_color = {nid: pauli_colors.get(n.pauli_str, DEFAULT_NODE_COLOR) for nid, n in nodes.items()}
    parent_map = {nid: parent_ids_of(n) for nid, n in nodes.items()}
    parent_anchor_map = {}
    for nid, n in nodes.items():
        pids = parent_map[nid]
        if not pids:
            parent_anchor_map[nid] = node_pos[nid]
            continue
        px = sum(node_pos[pid][0] for pid in pids) / len(pids)
        py = sum(node_pos[pid][1] for pid in pids) / len(pids)
        parent_anchor_map[nid] = (px, py)

    # Precompute shown-node sets per growth step.
    shown_before_steps: List[set] = []
    accumulated = {root_id}
    for step in range(num_grow_layers):
        shown_before_steps.append(set(accumulated))
        for nid in layers[grow_steps[step]]:
            accumulated.add(nid)

    ax.set_facecolor("#f6f7fb")
    ax.grid(alpha=0.08, linewidth=0.6)
    ax.set_xlabel("Layer index (decreases from L to 0 toward the left)", fontsize=11)
    ax.set_ylabel("Branch index", fontsize=11)
    ax.set_xticks(xticks)
    ax.set_xticklabels([str(k) for k in range(real_L + 1)])
    ax.set_yticks([])
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    completed_edges = LineCollection([], colors="#5d86e8", linewidths=1.35, alpha=0.95, zorder=2)
    growing_edges = LineCollection([], colors="#5d86e8", linewidths=1.55, alpha=1.0, zorder=3)
    ax.add_collection(completed_edges)
    ax.add_collection(growing_edges)

    shown_scatter = ax.scatter(
        [],
        [],
        s=[],
        color=DEFAULT_NODE_COLOR,
        edgecolors="white",
        linewidths=0.6,
        alpha=1.0,
        zorder=5,
    )
    growing_scatter = ax.scatter(
        [],
        [],
        s=[],
        color=DEFAULT_NODE_COLOR,
        edgecolors="white",
        linewidths=0.6,
        alpha=0.92,
        zorder=6,
    )

    root_text = ax.text(
        root.x,
        root.y - 1.00,
        r"$O = Z \otimes Z \otimes Z \otimes Z \otimes Z$",
        ha="center",
        va="top",
        fontsize=12,
        color="#222",
        zorder=7,
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
        zorder=7,
    )

    def update(frame: int):
        nonlocal current_xlim, current_ylim, max_seen_x_span, max_seen_y_span, current_node_zoom

        if frame < total_growth_frames and num_grow_layers > 0:
            step_index = frame // frames_per_layer
            sub = (frame % frames_per_layer) / max(1, frames_per_layer - 1)
            current_birth_step = grow_steps[step_index]
            growing_ids = layers[current_birth_step]
            shown_ids = shown_before_steps[step_index]
            target_visible = set(shown_ids) | set(growing_ids)
        else:
            sub = 1.0
            current_birth_step = None
            growing_ids = []
            shown_ids = set(nodes.keys())
            target_visible = shown_ids

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
        zoom_ratio = max(
            max_seen_x_span / max(base_x_span, 1e-9),
            max_seen_y_span / max(base_y_span, 1e-9),
        )
        current_node_zoom = max(0.26, zoom_ratio ** -0.65)

        complete_segments = []
        for nid in shown_ids:
            if nid == root_id:
                continue
            cx, cy = node_pos[nid]
            for pid in parent_map[nid]:
                px, py = node_pos[pid]
                complete_segments.append([(px, py), (cx, cy)])
        completed_edges.set_segments(complete_segments)

        partial_segments = []
        for nid in growing_ids:
            cx, cy = node_pos[nid]
            for pid in parent_map[nid]:
                px, py = node_pos[pid]
                partial_segments.append([(px, py), (interp(px, cx, sub), interp(py, cy, sub))])
        growing_edges.set_segments(partial_segments)

        shown_sorted = sorted(shown_ids)
        if shown_sorted:
            shown_offsets = np.array([node_pos[nid] for nid in shown_sorted], dtype=float)
            shown_colors = [node_color[nid] for nid in shown_sorted]
            shown_sizes = np.full(len(shown_sorted), node_size * current_node_zoom, dtype=float)
        else:
            shown_offsets = np.empty((0, 2), dtype=float)
            shown_colors = []
            shown_sizes = np.empty((0,), dtype=float)
        shown_scatter.set_offsets(shown_offsets)
        shown_scatter.set_color(shown_colors)
        shown_scatter.set_sizes(shown_sizes)

        if growing_ids:
            growing_offsets = []
            growing_colors = []
            for nid in growing_ids:
                ax0, ay0 = parent_anchor_map[nid]
                cx, cy = node_pos[nid]
                growing_offsets.append((interp(ax0, cx, sub), interp(ay0, cy, sub)))
                growing_colors.append(node_color[nid])
            growing_offsets_arr = np.array(growing_offsets, dtype=float)
            growth_scale = 0.25 + 0.75 * sub
            growing_sizes = np.full(
                len(growing_ids), node_size * current_node_zoom * growth_scale, dtype=float
            )
        else:
            growing_offsets_arr = np.empty((0, 2), dtype=float)
            growing_colors = []
            growing_sizes = np.empty((0,), dtype=float)
        growing_scatter.set_offsets(growing_offsets_arr)
        growing_scatter.set_color(growing_colors)
        growing_scatter.set_sizes(growing_sizes)

        gate_info = "".join(g.upper() for g in gate_schedule[:real_L])
        gate_mode = "Mixed per Pauli" if mixed_gates_per_layer else "Global schedule"
        visible_count = len(shown_ids) + (0 if frame >= total_growth_frames else len(growing_ids))
        info_text.set_text(
            f"Gate mode: {gate_mode}    Base schedule: {gate_info}    "
            f"Visible nodes: {visible_count}/{len(nodes)}    Merge: {'ON' if merge_same_nodes else 'OFF'}"
        )
        root_text.set_position((root.x, root.y - 1.00))

        if current_birth_step is not None:
            gate_idx = current_birth_step - 1
            gate_now = "mixed(R/C)" if mixed_gates_per_layer else gate_schedule[gate_idx].upper()
            x_layer = real_L - current_birth_step
            ax.set_title(
                f"Pauli Propagation Demo | growing layer x={x_layer} | gate={gate_now} | layer-wise",
                fontsize=13,
                pad=10,
            )
        else:
            ax.set_title("Pauli Propagation Demo | growth finished", fontsize=13, pad=10)

        return [completed_edges, growing_edges, shown_scatter, growing_scatter, root_text, info_text]

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
    fig, ani, nodes = create_pauli_propagation_animation_layerwise(
        L=9,
        gate_schedule=list("RCRRCRRCR"),
        root_pauli_str="ZZZZZ",
        split_prob_R=0.75,
        max_nodes=80,
        seed=12,
        interval_ms=120,
        frames_per_layer=12,
        hold_frames=30,
        merge_same_nodes=True,
        mixed_gates_per_layer=True,
        save_path=str(_OUT_DIR / "pauli_propagation_layerwise.gif"),
    )
    plt.show()
