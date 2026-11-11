#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Aref Ghoreishi
"""Routing-table path verification for the NoC topologies.

Reads the routing tables straight from rtl/noc_pkg.vhd, follows every traffic
flow of the system hop by hop and checks that it reaches its destination with
no loop, no dead end and no hop into a missing switch. NoC1 must also use S3
and S7, which is what distinguishes it from NoC2.

usage: route_trace.py [--topology NOC1|NOC2|all] [--pkg FILE] [--markdown]
Exit status 1 if any check fails.
"""
import argparse
import re
import sys
from collections import Counter
from pathlib import Path

PORT = {"PORT_N": 0, "PORT_E": 1, "PORT_S": 2, "PORT_W": 3, "PORT_L": 4}
PORT_NAME = "NESWL"
LOCAL = 4
MASTERS = (1, 9)
SLAVES = (2, 4, 6, 8)
REPLY_TO = {2: 9, 4: 9, 6: 1, 8: 1}
OTHER = {1: 9, 9: 1}
# switches that exist in each topology
SWITCHES = {"NOC1": tuple(range(1, 10)), "NOC2": (1, 2, 4, 5, 6, 8, 9)}
TOPOLOGIES = tuple(SWITCHES)

DEFAULT_PKG = Path(__file__).resolve().parent.parent / "rtl" / "noc_pkg.vhd"


def flows():
    """Every (source, destination) pair the traffic uses, with a label."""
    out = []
    for m in MASTERS:
        for s in SLAVES:
            out.append((m, s, "request"))
    for s in SLAVES:
        out.append((s, REPLY_TO[s], "reply"))
    for m in MASTERS:
        out.append((m, OTHER[m], "forward"))
    return out


def parse_tables(pkg_text, topology):
    """{switch: {dest: port}} for the switches of 'topology'."""
    tables = {}
    pat = re.compile(rf"constant\s+{topology}_S(\d)\s*:\s*route_table_t\s*:=\s*\((.*?)\);",
                     re.S | re.I)
    for m in pat.finditer(pkg_text):
        entries = {int(d): PORT[p.upper()]
                   for d, p in re.findall(r"(\d+)\s*=>\s*(PORT_[NESWL])", m.group(2), re.I)}
        tables[int(m.group(1))] = entries
    return {k: v for k, v in tables.items() if k in SWITCHES[topology]}


def load_tables(topology, pkg=DEFAULT_PKG):
    return parse_tables(Path(pkg).read_text(encoding="utf-8"), topology)


def neighbour(sw, port):
    r, c = divmod(sw - 1, 3)
    dr, dc = {0: (-1, 0), 1: (0, 1), 2: (1, 0), 3: (0, -1)}[port]
    r, c = r + dr, c + dc
    if not (0 <= r < 3 and 0 <= c < 3):
        return None
    return r * 3 + c + 1


def path(tables, src, dst):
    """Switches visited from the source's switch to the destination's (inclusive).
    Raises RuntimeError on a loop, a dead end or a hop off the topology."""
    sw, seen = src, [src]
    while True:
        port = tables[sw].get(dst, LOCAL)
        if port == LOCAL:
            if sw != dst:
                raise RuntimeError(f"dead end: S{sw} delivers dest {dst} locally ({seen})")
            return seen
        nxt = neighbour(sw, port)
        if nxt is None:
            raise RuntimeError(f"S{sw} routes dest {dst} off the mesh ({seen})")
        if nxt not in tables:
            raise RuntimeError(f"S{sw} routes dest {dst} into missing switch S{nxt} ({seen})")
        if nxt in seen:
            raise RuntimeError(f"loop for dest {dst}: {seen + [nxt]}")
        seen.append(nxt)
        sw = nxt


def trace(topology, pkg=DEFAULT_PKG):
    """Returns (rows, load, errors): rows = (label, src, dst, path or None)."""
    tables = load_tables(topology, pkg)
    errors, rows, load = [], [], Counter()
    missing = set(SWITCHES[topology]) - set(tables)
    if missing:
        errors.append(f"{topology}: no routing table for " + ", ".join(f"S{k}" for k in sorted(missing)))
        return rows, load, errors
    for src, dst, label in flows():
        try:
            p = path(tables, src, dst)
            rows.append((label, src, dst, p))
            load.update(p)
        except RuntimeError as e:
            rows.append((label, src, dst, None))
            errors.append(f"{topology} P{src}->P{dst}: {e}")
    if topology == "NOC1":
        for k in (3, 7):
            if load[k] == 0:
                errors.append(f"NOC1 never routes through S{k}")
    else:
        for k in set(range(1, 10)) - set(SWITCHES[topology]):
            if load[k]:
                errors.append(f"{topology} routes through removed switch S{k}")
    return rows, load, errors


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--topology", default="all", choices=TOPOLOGIES + ("all",))
    ap.add_argument("--pkg", default=str(DEFAULT_PKG))
    ap.add_argument("--markdown", action="store_true", help="print Markdown tables")
    a = ap.parse_args()

    failed = False
    for topo in (TOPOLOGIES if a.topology == "all" else (a.topology,)):
        rows, load, errors = trace(topo, a.pkg)
        if a.markdown:
            tables = load_tables(topo, a.pkg)
            print(f"#### {topo}\n")
            print("Routing table: output port for each destination address "
                  "(N, E, S, W, or L = local).\n")
            print("| switch | " + " | ".join(f"→{d}" for d in range(1, 10)) + " |")
            print("|---|" + ":---:|" * 9)
            for k in SWITCHES[topo]:
                print(f"| S{k} | " + " | ".join(PORT_NAME[tables[k].get(d, LOCAL)]
                                               for d in range(1, 10)) + " |")
            print("\nPath of every flow:\n")
            print("| flow | from | to | path | switches |")
            print("|---|---|---|---|---|")
            for label, s, d, p in rows:
                txt = " → ".join(f"S{k}" for k in p) if p else "**FAILED**"
                print(f"| {label} | P{s} | P{d} | {txt} | {len(p) if p else '-'} |")
            print("\nFlows through each switch: " +
                  ", ".join(f"S{k} {load[k]}" for k in SWITCHES[topo]) + "\n")
        else:
            print(f"== {topo}")
            for label, s, d, p in rows:
                txt = "-".join(f"S{k}" for k in p) if p else "FAILED"
                print(f"  {label:8} P{s}->P{d}: {txt}")
            print("  flows per switch: " + " ".join(f"S{k}={load[k]}" for k in SWITCHES[topo]))
        for e in errors:
            print(f"  ERROR {e}")
        status = "FAIL" if errors else "PASS"
        print(f"ROUTE_TRACE {status} {topo}: {len(rows) - len(errors)}/{len(flows())} flows reach "
              f"their destination" + ("" if errors else ", no loops, no dead ends"))
        failed |= bool(errors)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
