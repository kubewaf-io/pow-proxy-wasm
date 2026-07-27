#!/usr/bin/env python3
"""Render PNG charts from k6 --summary-export JSON.

Primary comparison: no challenger (baseline) vs challenger with valid clearance token.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from memory import load_run_memory, memory_mb

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

VALID_PROFILES = ("baseline", "challenge")
VALID_SCENARIOS = ("baseline-get", "challenge-issue", "clearance-get")

# Friendly labels for the main comparison
LABEL_BASELINE = "No challenger\n(baseline)"
LABEL_CLEARANCE = "Challenger +\nvalid token"

TEST_ORDER = [
    ("baseline", "baseline-get"),
    ("challenge", "clearance-get"),
    ("challenge", "challenge-issue"),
]

OVERLAY_METRICS = ("p50", "p90", "p95", "p99")
COLOR_BASELINE = "#8b9cb3"
COLOR_CLEARANCE = "#3d8bfd"
COLOR_ISSUE = "#f0883e"
OVERLAY_COLORS = (COLOR_BASELINE, COLOR_CLEARANCE, COLOR_ISSUE, "#2ea043", "#a371f7")


def load_summary(path: Path) -> dict:
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)


def metric_ms(data: dict, name: str, key: str) -> float | None:
    entry = data.get("metrics", {}).get(name)
    if not entry or key not in entry:
        return None
    return float(entry[key])


def metric_rate(data: dict, name: str) -> float | None:
    entry = data.get("metrics", {}).get(name)
    if not entry:
        return None
    if "rate" in entry:
        return float(entry["rate"])
    return None


def latency_stats(data: dict) -> dict[str, float | None]:
    dur = "http_req_duration"
    return {
        "p50": metric_ms(data, dur, "med"),
        "p90": metric_ms(data, dur, "p(90)"),
        "p95": metric_ms(data, dur, "p(95)"),
        "p99": metric_ms(data, dur, "p(99)"),
        "avg": metric_ms(data, dur, "avg"),
    }


def apply_style() -> None:
    plt.style.use("dark_background")
    plt.rcParams.update(
        {
            "figure.facecolor": "#0f1419",
            "axes.facecolor": "#1a2332",
            "axes.edgecolor": "#2d3a4f",
            "axes.labelcolor": "#8b9cb3",
            "text.color": "#e7ecf3",
            "xtick.color": "#8b9cb3",
            "ytick.color": "#8b9cb3",
            "grid.color": "#2d3a4f",
            "font.size": 10,
        }
    )


def _bar_labels(ax, bars, fmt: str = "{:.2f}") -> None:
    for bar in bars:
        h = bar.get_height()
        if h is None or h == 0:
            continue
        ax.text(
            bar.get_x() + bar.get_width() / 2,
            h,
            fmt.format(h),
            ha="center",
            va="bottom",
            fontsize=8,
            color="#e7ecf3",
        )


def render_baseline_vs_clearance(
    baseline: dict,
    clearance: dict,
    output: Path,
    *,
    baseline_label: str = LABEL_BASELINE,
    clearance_label: str = LABEL_CLEARANCE,
    title: str = "pow-proxy-wasm: no challenger vs valid token",
) -> None:
    """Side-by-side latency + throughput comparison chart."""
    apply_style()
    bl = latency_stats(baseline)
    cl = latency_stats(clearance)
    brps = metric_rate(baseline, "http_reqs") or 0.0
    crps = metric_rate(clearance, "http_reqs") or 0.0

    metrics = list(OVERLAY_METRICS)
    b_vals = [float(bl[k] or 0.0) for k in metrics]
    c_vals = [float(cl[k] or 0.0) for k in metrics]

    fig, (ax_lat, ax_rps) = plt.subplots(
        1,
        2,
        figsize=(12, 5.2),
        dpi=140,
        gridspec_kw={"width_ratios": [1.6, 1]},
    )
    fig.suptitle(title, fontsize=13, fontweight="bold", y=1.02)

    x = list(range(len(metrics)))
    width = 0.36
    bars_b = ax_lat.bar(
        [i - width / 2 for i in x],
        b_vals,
        width,
        label=baseline_label.replace("\n", " "),
        color=COLOR_BASELINE,
        edgecolor="#2d3a4f",
    )
    bars_c = ax_lat.bar(
        [i + width / 2 for i in x],
        c_vals,
        width,
        label=clearance_label.replace("\n", " "),
        color=COLOR_CLEARANCE,
        edgecolor="#2d3a4f",
    )
    ax_lat.set_xticks(x)
    ax_lat.set_xticklabels(metrics)
    ax_lat.set_ylabel("latency (ms)")
    ax_lat.set_title("HTTP latency percentiles", fontsize=11, pad=10)
    ax_lat.legend(loc="upper left", fontsize=8, framealpha=0.9)
    ax_lat.grid(axis="y", alpha=0.35)
    _bar_labels(ax_lat, bars_b)
    _bar_labels(ax_lat, bars_c)

    rps_x = [0, 1]
    rps_vals = [brps, crps]
    rps_colors = [COLOR_BASELINE, COLOR_CLEARANCE]
    rps_labels = [baseline_label, clearance_label]
    bars_r = ax_rps.bar(rps_x, rps_vals, color=rps_colors, edgecolor="#2d3a4f", width=0.55)
    ax_rps.set_xticks(rps_x)
    ax_rps.set_xticklabels(rps_labels, fontsize=9)
    ax_rps.set_ylabel("requests / second")
    ax_rps.set_title("Throughput", fontsize=11, pad=10)
    ax_rps.grid(axis="y", alpha=0.35)
    _bar_labels(ax_rps, bars_r, fmt="{:.0f}")

    # Overhead caption
    if brps > 0 and crps > 0:
        rps_delta = ((crps - brps) / brps) * 100.0
        p50_delta = (c_vals[0] - b_vals[0]) if b_vals[0] or c_vals[0] else 0.0
        caption = (
            f"Clearance vs baseline: RPS {rps_delta:+.1f}%  ·  p50 {p50_delta:+.2f} ms"
        )
        fig.text(0.5, -0.02, caption, ha="center", fontsize=9, color="#8b9cb3")

    fig.tight_layout()
    output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output, bbox_inches="tight")
    plt.close(fig)
    print(f"==> {output}")


def render_overlay(series: list[tuple[str, dict]], title: str, output: Path) -> None:
    apply_style()
    x = list(range(len(OVERLAY_METRICS)))
    fig, ax = plt.subplots(figsize=(10, 6), dpi=120)
    plotted = 0
    for i, (name, summary) in enumerate(series):
        lat = latency_stats(summary)
        values = [lat[key] for key in OVERLAY_METRICS]
        if not any(v is not None for v in values):
            continue
        y = [float(v) if v is not None else 0.0 for v in values]
        color = OVERLAY_COLORS[i % len(OVERLAY_COLORS)]
        ax.plot(x, y, marker="o", label=name, color=color, linewidth=2, markersize=5, alpha=0.9)
        plotted += 1
    if plotted == 0:
        raise ValueError("no latency data to plot")
    ax.set_xticks(x)
    ax.set_xticklabels(list(OVERLAY_METRICS))
    ax.set_ylabel("latency (ms)")
    ax.set_title(title, fontsize=12, fontweight="bold", pad=12)
    ax.legend(loc="upper left", fontsize=8, ncol=2, framealpha=0.85)
    ax.grid(axis="y", alpha=0.35)
    fig.tight_layout()
    output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output, bbox_inches="tight")
    plt.close(fig)
    print(f"==> {output}")


def render_memory_overlay(runs: list[tuple[str, Path]], title: str, output: Path) -> None:
    apply_style()
    labels = []
    rss_vals = []
    colors = []
    for i, (name, run_dir) in enumerate(runs):
        snap = load_run_memory(run_dir)
        mb = memory_mb(snap)
        labels.append(name)
        rss_vals.append(mb.get("container_peak_rss_mb") or 0.0)
        colors.append(OVERLAY_COLORS[i % len(OVERLAY_COLORS)])
    if not labels:
        raise ValueError("no memory data")
    fig, ax = plt.subplots(figsize=(10, 4.5), dpi=120)
    ax.bar(labels, rss_vals, color=colors, edgecolor="#2d3a4f")
    ax.set_ylabel("peak container RSS (MiB)")
    ax.set_title(title, fontsize=12, fontweight="bold", pad=12)
    ax.grid(axis="y", alpha=0.35)
    plt.xticks(rotation=15, ha="right")
    fig.tight_layout()
    output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output, bbox_inches="tight")
    plt.close(fig)
    print(f"==> {output}")


def parse_run_dir(path: Path) -> tuple[str, str, str] | None:
    name = path.name
    if not name.startswith("run-"):
        return None
    rest = name[4:]
    for scenario in VALID_SCENARIOS:
        suffix = f"-{scenario}"
        if not rest.endswith(suffix):
            continue
        middle = rest[: -len(suffix)]
        for profile in VALID_PROFILES:
            profile_suffix = f"-{profile}"
            if middle.endswith(profile_suffix):
                stamp = middle[: -len(profile_suffix)]
                if stamp:
                    return stamp, profile, scenario
    return None


def discover_runs(results_dir: Path) -> list[tuple[str, str, Path, dict]]:
    found: list[tuple[str, str, Path, dict]] = []
    if not results_dir.is_dir():
        return found
    for child in sorted(results_dir.iterdir()):
        if not child.is_dir():
            continue
        parsed = parse_run_dir(child)
        summary = child / "k6-summary.json"
        if not parsed or not summary.is_file():
            continue
        _, profile, scenario = parsed
        found.append((profile, scenario, child, load_summary(summary)))
    return found


def latest_by_key(runs: list[tuple[str, str, Path, dict]]) -> dict[tuple[str, str], tuple[Path, dict]]:
    latest: dict[tuple[str, str], tuple[Path, dict]] = {}
    for profile, scenario, path, summary in runs:
        latest[(profile, scenario)] = (path, summary)
    return latest


def cmd_bundle(results_dir: Path, out_dir: Path) -> int:
    runs = discover_runs(results_dir)
    if not runs:
        print(f"ERROR: no k6 summaries under {results_dir}", file=sys.stderr)
        return 1

    latest = latest_by_key(runs)
    out_dir.mkdir(parents=True, exist_ok=True)

    # Main comparison graph: no challenger vs valid clearance token
    base = latest.get(("baseline", "baseline-get"))
    clear = latest.get(("challenge", "clearance-get"))
    if base and clear:
        render_baseline_vs_clearance(
            base[1],
            clear[1],
            out_dir / "baseline-vs-clearance.png",
        )
        # Alias used by release notes / CI
        render_baseline_vs_clearance(
            base[1],
            clear[1],
            out_dir / "perf-overlay.png",
        )
    else:
        print(
            "WARN: need baseline/baseline-get and challenge/clearance-get for comparison chart",
            file=sys.stderr,
        )
        # Fallback overlay of whatever we have
        series: list[tuple[str, dict]] = []
        ordered = sorted(
            latest.keys(),
            key=lambda ps: TEST_ORDER.index(ps) if ps in TEST_ORDER else 99,
        )
        for profile, scenario in ordered:
            _, summary = latest[(profile, scenario)]
            series.append((f"{profile}/{scenario}", summary))
        if series:
            render_overlay(series, "pow-proxy-wasm k6 latency", out_dir / "perf-overlay.png")

    # Optional: include challenge-issue in a secondary overlay
    series_all: list[tuple[str, dict]] = []
    mem_runs: list[tuple[str, Path]] = []
    friendly = {
        ("baseline", "baseline-get"): "No challenger",
        ("challenge", "clearance-get"): "Valid token",
        ("challenge", "challenge-issue"): "Challenge issue (403)",
    }
    ordered = sorted(
        latest.keys(),
        key=lambda ps: TEST_ORDER.index(ps) if ps in TEST_ORDER else 99,
    )
    for key in ordered:
        path, summary = latest[key]
        label = friendly.get(key, f"{key[0]}/{key[1]}")
        series_all.append((label, summary))
        mem_runs.append((label, path))

    if len(series_all) > 2:
        render_overlay(
            series_all,
            "pow-proxy-wasm — all scenarios (latency)",
            out_dir / "perf-all-scenarios.png",
        )

    try:
        # Prefer memory for baseline + clearance only
        mem_pair = []
        if base:
            mem_pair.append(("No challenger", base[0]))
        if clear:
            mem_pair.append(("Valid token", clear[0]))
        if len(mem_pair) >= 2:
            render_memory_overlay(
                mem_pair,
                "Memory: no challenger vs valid token",
                out_dir / "memory-overlay.png",
            )
        elif mem_runs:
            render_memory_overlay(mem_runs, "pow-proxy-wasm memory", out_dir / "memory-overlay.png")
    except ValueError as exc:
        print(f"WARN: memory chart skipped: {exc}", file=sys.stderr)

    return 0


def cmd_compare(left: Path, right: Path, output: Path, left_label: str, right_label: str) -> int:
    if not left.is_file() or not right.is_file():
        print(f"ERROR: missing summary files: {left} / {right}", file=sys.stderr)
        return 1
    render_baseline_vs_clearance(
        load_summary(left),
        load_summary(right),
        output,
        baseline_label=left_label,
        clearance_label=right_label,
        title="pow-proxy-wasm: no challenger vs valid token",
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    bundle = sub.add_parser("bundle", help="Charts from results dir (baseline vs clearance)")
    bundle.add_argument("results_dir", type=Path)
    bundle.add_argument("-o", "--output-dir", type=Path, required=True)

    compare = sub.add_parser("compare", help="Direct two-summary comparison chart")
    compare.add_argument("left", type=Path, help="baseline k6-summary.json")
    compare.add_argument("right", type=Path, help="clearance k6-summary.json")
    compare.add_argument("-o", "--output", type=Path, required=True)
    compare.add_argument("--left-label", default=LABEL_BASELINE)
    compare.add_argument("--right-label", default=LABEL_CLEARANCE)

    args = parser.parse_args()
    if args.cmd == "bundle":
        return cmd_bundle(args.results_dir, args.output_dir)
    if args.cmd == "compare":
        return cmd_compare(args.left, args.right, args.output, args.left_label, args.right_label)
    return 2


if __name__ == "__main__":
    sys.exit(main())
