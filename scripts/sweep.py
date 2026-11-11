#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Aref Ghoreishi
"""Run the FIFO depth x switch delay grid and check every run.

usage: sweep.py [--topologies NOC1,NOC2] [--datasets baseline,stress]
                [--depths 1-8] [--delays 0-7] [--jobs N] [--out build/sweep]

Each run is tb/system/noc_sweep_tb with its own output prefix
<out>/<topology>/<dataset>/d<depth>_t<delay>_ and is judged by check.evaluate
plus the testbench's own verdict (exit status, no error reports). Prints one
grid per topology and data set; exit status 1 if any run fails.
"""
import argparse
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check  # noqa: E402

ERROR_RE = re.compile(r"\((?:report|assertion) (?:error|failure)\)")


def span(text):
    """'1-8' or '1,2,4,8' -> list of ints."""
    out = []
    for part in text.split(","):
        if "-" in part:
            lo, hi = part.split("-")
            out.extend(range(int(lo), int(hi) + 1))
        else:
            out.append(int(part))
    return out


def run_one(args, topo, ds, depth, delay):
    prefix = f"{args.out}/{topo}/{ds}/d{depth}_t{delay}_"
    Path(prefix).parent.mkdir(parents=True, exist_ok=True)
    data_dir = f"data/{ds}/"
    cmd = [args.ghdl, "--elab-run", "--std=08", f"--workdir={args.workdir}", "noc_sweep_tb",
           f"-gDEPTH={depth}", f"-gDELAY={delay}", f"-gCYCLES={args.cycles}",
           f"-gOUT_PREFIX={prefix}", f"-gDATA_DIR={data_dir}", f"-gTOPOLOGY={topo}"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    out = proc.stdout + proc.stderr
    Path(f"{prefix}sim.log").write_text(out)
    res = check.evaluate(prefix, data_dir, topo)
    sim_errors = [l for l in out.splitlines() if ERROR_RE.search(l)]
    tb_pass = proc.returncode == 0 and "NOC_SWEEP_TB PASS" in out
    res["sim_errors"] = sim_errors
    res["ok"] = res["ok"] and tb_pass and not sim_errors
    return (topo, ds, depth, delay), res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--topologies", default="NOC1,NOC2")
    ap.add_argument("--datasets", default="baseline,stress")
    ap.add_argument("--depths", default="1-8")
    ap.add_argument("--delays", default="0-7")
    ap.add_argument("--cycles", type=int, default=20000)
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 2)
    ap.add_argument("--out", default="build/sweep")
    ap.add_argument("--workdir", default="build/work")
    ap.add_argument("--ghdl", default=os.environ.get("GHDL", "ghdl"))
    args = ap.parse_args()

    topos = args.topologies.split(",")
    datasets = args.datasets.split(",")
    depths, delays = span(args.depths), span(args.delays)
    jobs = [(t, ds, d, dl) for t in topos for ds in datasets for d in depths for dl in delays]

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = dict(pool.map(lambda j: run_one(args, *j), jobs))

    failed = 0
    for t in topos:
        for ds in datasets:
            first = results[(t, ds, depths[0], delays[0])]
            exp = " ".join(f"{c}={e}" for c, (_, e) in first["per_category"].items())
            print(f"== {t} / {ds}: expected {first['expected']} ({exp}); "
                  f"rows = FIFO depth, columns = delay {delays[0]}..{delays[-1]}")
            for d in depths:
                cells = []
                for dl in delays:
                    r = results[(t, ds, d, dl)]
                    v = r["verdict"] if r["ok"] or r["verdict"] != "PASS" else "FAIL"
                    cells.append(f"{v} {r['delivered']:>3}/{r['expected']}")
                    if not r["ok"]:
                        failed += 1
                print(f"  depth {d}: " + "  ".join(cells))
    for key, r in sorted(results.items()):
        if not r["ok"]:
            print(f"FAILED {key}: {check.describe(r, '')}")
            for e in (r["log_errors"] + r["sim_errors"])[:3]:
                print(f"    {e}")
    total = len(jobs)
    print(f"SWEEP {'PASS' if not failed else 'FAIL'}: {total - failed}/{total} runs pass")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
