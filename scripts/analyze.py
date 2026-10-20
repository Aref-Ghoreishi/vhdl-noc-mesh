#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Aref Ghoreishi
"""Summarize the sweep into results/results.csv and two figures.

usage: analyze.py [--sweep build/sweep] [--out results] [--no-plot]

Reads the runs written by scripts/sweep.py ("make sweep" first). Per run:
  avg_latency / max_latency  cycles from a request's first offer to its reply's arrival
  max_fifo                   fullest input FIFO of any switch (packets)
  s5_max_fifo / s5_forwarded fullest input FIFO of S5, packets S5 forwarded
  done_cycle                 cycle of the last delivery
  delivered / expected       golden-checked packets; hung = packets left in a FIFO
"""
import argparse
import csv
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check  # noqa: E402

TOPOLOGIES = ("NOC1", "NOC2")
LABEL = {"NOC1": "NoC1", "NOC2": "NoC2"}
DATASETS = ("baseline", "stress")
DELAYS = (1, 3, 7)
FIELDS = ("topology", "dataset", "fifo_depth", "delay", "avg_latency", "max_latency", "max_fifo",
          "s5_max_fifo", "s5_forwarded", "done_cycle", "delivered", "expected", "hung")


def run_metrics(prefix, ds, topo):
    lat = []
    for m in (1, 9):
        for line in Path(f"{prefix}P{m}_responses.txt").read_text().splitlines():
            if line.strip() and not line.startswith("#"):
                lat.append(int(line.split()[4]))
    occ = {int(k): ([int(x) for x in v.split()], int(f)) for k, v, f in re.findall(
        r"max_occupancy S(\d) :((?: \d+){5}) forwarded : (\d+)", Path(f"{prefix}summary.txt").read_text())}
    res = check.evaluate(prefix, f"data/{ds}/", topo)
    return {
        "avg_latency": round(sum(lat) / len(lat), 1), "max_latency": max(lat),
        "max_fifo": max(max(v[0]) for v in occ.values()),
        "s5_max_fifo": max(occ[5][0]), "s5_forwarded": occ[5][1],
        "done_cycle": res["summary"].get("last_arrival", 0),
        "delivered": res["delivered"], "expected": res["expected"],
        "hung": "yes" if res["stuck"] else "no", "ok": res["ok"],
    }


def plot(rows, out):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    color = {"NOC1": "#2a78d6", "NOC2": "#eb6834"}
    style = {"stress": "-", "baseline": "--"}
    ink, ink2, grid = "#0b0b0b", "#52514e", "#e4e3df"
    get = {(r["topology"], r["dataset"], r["fifo_depth"], r["delay"]): r for r in rows}
    depths = sorted({r["fifo_depth"] for r in rows})

    def frame(ax, ylabel, title):
        ax.set_title(title, fontsize=10, color=ink, loc="left")
        ax.set_xlabel("FIFO depth (packets)", fontsize=9, color=ink2)
        ax.set_ylabel(ylabel, fontsize=9, color=ink2)
        ax.set_xticks(depths)
        ax.grid(axis="y", color=grid, linewidth=0.8)
        ax.tick_params(colors=ink2, labelsize=8, length=0)
        for side in ("top", "right", "left"):
            ax.spines[side].set_visible(False)
        ax.spines["bottom"].set_color(grid)
        ax.legend(frameon=False, fontsize=8)

    fig, ax = plt.subplots(figsize=(6, 3.5), dpi=120)
    for ds in ("stress", "baseline"):
        for topo in TOPOLOGIES:
            ys = [get[(topo, ds, d, 7)]["avg_latency"] for d in depths]
            ax.plot(depths, ys, style[ds], color=color[topo], linewidth=2, marker="o", markersize=4,
                    label=f"{LABEL[topo]} {ds}")
    ax.set_ylim(0, None)
    frame(ax, "avg reply latency (cycles)", "Reply latency vs FIFO depth (switch delay 7)")
    fig.tight_layout()
    fig.savefig(out / "latency_vs_depth.png")
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(6, 3.5), dpi=120)
    ax.plot(depths, depths, color=grid, linewidth=6, solid_capstyle="round", label="FIFO full")
    for topo in TOPOLOGIES:
        ys = [get[(topo, "stress", d, 7)]["s5_max_fifo"] for d in depths]
        ax.plot(depths, ys, color=color[topo], linewidth=2, marker="o", markersize=4,
                label=LABEL[topo])
    ax.set_ylim(0, None)
    frame(ax, "S5 max FIFO occupancy (packets)", "S5 occupancy vs FIFO depth (stress, delay 7)")
    fig.tight_layout()
    fig.savefig(out / "s5_occupancy.png")
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sweep", default="build/sweep")
    ap.add_argument("--out", default="results")
    ap.add_argument("--no-plot", action="store_true")
    a = ap.parse_args()

    rows, bad = [], 0
    for topo in TOPOLOGIES:
        for ds in DATASETS:
            for depth in range(1, 9):
                for delay in DELAYS:
                    prefix = f"{a.sweep}/{topo}/{ds}/d{depth}_t{delay}_"
                    if not Path(f"{prefix}summary.txt").exists():
                        print(f"missing {prefix}summary.txt (run 'make sweep' first)")
                        return 1
                    m = run_metrics(prefix, ds, topo)
                    bad += not m.pop("ok")
                    rows.append({"topology": topo, "dataset": ds, "fifo_depth": depth, "delay": delay, **m})

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "results.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS, lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {out / 'results.csv'} ({len(rows)} runs, {bad} failed a check)")
    if not a.no_plot:
        plot(rows, out)
        print(f"wrote {out / 'latency_vs_depth.png'}, {out / 's5_occupancy.png'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
