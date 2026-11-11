#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Aref Ghoreishi
"""Golden-model checker for one NoC simulation run.

usage: check.py OUT_PREFIX [--data DIR] [--topology NOC1|NOC2] [--regress DIR] [--quiet]

Predicts every packet the endpoints must receive from the input files and the
routing tables, then compares it with what noc_sweep_tb logged:
  requests   master -> slave           (24 for the baseline set)
  responses  slave  -> master          (24)
  forwards   master -> other master    (6)
Each packet is matched on endpoint, source, requester, hop count, check byte and
payload. It also cross-checks the masters' own logs (same packets, same receive
cycles, latency = recv - send >= hops).

--regress DIR compares the replies with the original ModelSim logs
DIR/P{2,4,6,8}_<NoC1|NoC2>_FIFO1.txt. Those were produced by the original slaves,
which processed all 8 bytes regardless of valid_size. Every hop count must match;
payload and check byte must match wherever the original and the current
(valid_size-conforming) slave give the same result, and are golden-checked
elsewhere.

Exit status 0 only if everything matches.
"""
import argparse
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import route_trace  # noqa: E402

MASTERS = route_trace.MASTERS
SLAVES = route_trace.SLAVES
REPLY_TO = route_trace.REPLY_TO
OTHER = route_trace.OTHER
CATEGORIES = ("requests", "responses", "forwards")
FORWARD_EVERY = 4
GOLDEN_NAME = {"NOC1": "NoC1", "NOC2": "NoC2"}


def forwards_after(n):
    """True if 1-based request number n is followed by a forward to the other master."""
    return n % FORWARD_EVERY == 0


def to_hex(data):
    """Payload bytes (byte 0 first) as the VHDL to_hstring of the 64-bit field."""
    return "".join(f"{b:02X}" for b in reversed(data))


def master_payload(data, size):
    """What the master sends: bytes from valid_size on are zero."""
    return list(data[:size]) + [0] * (8 - size)


def slave_op(addr, data, size):
    """Slave model: only the first valid_size bytes are processed, padding is zero."""
    v = list(data[:size])
    pad = [0] * (8 - size)
    if addr == 2:
        return sorted(v) + pad, 0
    if addr == 6:
        return sorted(v, reverse=True) + pad, 0
    if addr == 4:
        p = 0
        for b in v:
            p ^= b
        return v + pad, p
    if addr == 8:
        return v + pad, sum(v) % 256
    raise ValueError(addr)


def slave_op_original(addr, data):
    """The original coursework slaves: all 8 bytes, valid_size ignored."""
    return slave_op(addr, data, 8)


def read_requests(data_dir, master):
    reqs = []
    for line in Path(data_dir, f"P{master}_data.txt").read_text().splitlines():
        f = line.split()
        if f:
            reqs.append((int(f[0]), int(f[1]), [int(x) for x in f[2:10]]))
    return reqs


def category(ep, src):
    if ep in SLAVES:
        return "requests"
    return "responses" if src in SLAVES else "forwards"


def expected(data_dir, tables):
    """Counter of (endpoint, src, requester, hops, check, data)."""
    exp = Counter()
    hops = lambda a, b: len(route_trace.path(tables, a, b))  # noqa: E731
    for m in MASTERS:
        for i, (dst, size, data) in enumerate(read_requests(data_dir, m)):
            payload = master_payload(data, size)
            h_req = hops(m, dst)
            exp[(dst, m, m, h_req, "00", to_hex(payload))] += 1
            out, chk = slave_op(dst, payload, size)
            r = REPLY_TO[dst]
            exp[(r, dst, m, h_req + hops(dst, r), f"{chk:02X}", to_hex(out))] += 1
            if forwards_after(i + 1):
                o = OTHER[m]
                exp[(o, m, m, hops(m, o), "00", to_hex(payload))] += 1
    return exp


LINE_RE = re.compile(r"cycle=\s*(-?\d+) src=([01]{4}) dst=([01]{4}) resp=([01]{4}) "
                     r"hops=\s*(\d+) ts=\s*(-?\d+) check=([0-9A-F]{2}) data=([0-9A-F]{16})")
MLOG_RE = re.compile(r"^([01]{4}) ([01]{4}) (-?\d+) (\d+) (-?\d+) (\d+) ([0-9A-F]{2}) ([0-9A-F]{16})$")
LOG_RE = re.compile(r"source:\s*([01]{4})\s*,\s*(?:data|packet):\s*([0-9A-F]{16})\s*,\s*"
                    r"check_sum:\s*([0-9A-F]{2})\s*,\s*hop(?: count)?\s*:\s*(\d+)")


def observed(prefix):
    obs = Counter()
    for ep in MASTERS + SLAVES:
        p = Path(f"{prefix}o_P{ep}.txt")
        if not p.exists():
            continue
        for line in p.read_text().splitlines():
            m = LINE_RE.search(line)
            if m:
                obs[(ep, int(m.group(2), 2), int(m.group(4), 2), int(m.group(5)),
                     m.group(7), m.group(8))] += 1
    return obs


def per_category(counter):
    c = Counter()
    for k, n in counter.items():
        c[category(k[0], k[1])] += n
    return c


def master_logs(prefix):
    """Cross-check the masters' logs against the testbench transfer logs.
    Returns (lines checked, list of errors)."""
    errors, n = [], 0
    for m in MASTERS:
        p = Path(f"{prefix}o_P{m}.txt")
        if not p.exists():
            continue
        tb = Counter()
        for line in p.read_text().splitlines():
            g = LINE_RE.search(line)
            if g:
                kind = "responses" if int(g.group(2), 2) in SLAVES else "host"
                tb[(kind, g.group(4), g.group(2), int(g.group(6)), int(g.group(1)),
                    int(g.group(5)), g.group(7), g.group(8))] += 1
        logged = Counter()
        for kind in ("responses", "host"):
            f = Path(f"{prefix}P{m}_{kind}.txt")
            if not f.exists():
                errors.append(f"{f} missing")
                continue
            for line in f.read_text().splitlines():
                if line.startswith("#") or not line.strip():
                    continue
                g = MLOG_RE.match(line.strip())
                if not g:
                    errors.append(f"{f}: bad line {line!r}")
                    continue
                req, rsp, send, recv, lat, hops, chk, data = g.groups()
                send, recv, lat, hops = int(send), int(recv), int(lat), int(hops)
                n += 1
                if lat != recv - send:
                    errors.append(f"{f}: latency {lat} != {recv} - {send}")
                if lat < hops:
                    errors.append(f"{f}: latency {lat} < hops {hops}")
                logged[(kind, req, rsp, send, recv, hops, chk, data)] += 1
        if logged != tb:
            errors.append(f"P{m} logs disagree with the testbench: "
                          f"{sum((tb - logged).values())} not logged, "
                          f"{sum((logged - tb).values())} extra or misfiled")
    return n, errors


def regression(golden_dir, data_dir, tables, obs, topology):
    """Compare replies with the original ModelSim logs. Returns (ok, message)."""
    name = GOLDEN_NAME[topology]
    logged = Counter()
    for s in SLAVES:
        for line in Path(golden_dir, f"P{s}_{name}_FIFO1.txt").read_text().splitlines():
            m = LOG_RE.search(line)
            if m:
                logged[(s, int(m.group(1), 2), m.group(2), m.group(3), int(m.group(4)))] += 1
    original, pairs = Counter(), Counter()
    for mst in MASTERS:
        for dst, size, data in read_requests(data_dir, mst):
            hops = (len(route_trace.path(tables, mst, dst)) +
                    len(route_trace.path(tables, dst, REPLY_TO[dst])))
            out, chk = slave_op_original(dst, data)
            okey = (dst, mst, to_hex(out), f"{chk:02X}", hops)
            original[okey] += 1
            out2, chk2 = slave_op(dst, master_payload(data, size), size)
            pairs[(okey, (dst, mst, to_hex(out2), f"{chk2:02X}", hops))] += 1
    errors = []
    if logged != original:
        errors.append(f"ModelSim logs disagree with the original slave model: "
                      f"{sum((logged - original).values())} unexplained lines")
    identical = changed = bad = 0
    for (okey, ckey), n in pairs.items():
        s, mst, data, chk, hops = ckey
        hit = min(n, obs[(REPLY_TO[s], s, mst, hops, chk, data)])
        if okey == ckey:
            identical += hit
        else:
            changed += hit
        bad += n - hit
    total = sum(pairs.values())
    if bad:
        errors.append(f"{bad} replies differ from the reference")
    msg = (f"regression {name}: {identical}/{total} identical to ModelSim log, "
           f"{changed}/{total} changed by the valid_size fix (golden-checked), "
           f"hop counts {identical + changed}/{total}")
    return not errors, msg + "".join(f"\n  {e}" for e in errors)


def evaluate(prefix, data_dir, topology="NOC1", golden_dir=None):
    """Check one run. Returns a dict; 'ok' is True only if everything matches."""
    tables = route_trace.load_tables(topology)
    exp = expected(data_dir, tables)
    obs = observed(prefix)
    hit, missing, extra = exp & obs, exp - obs, obs - exp

    summary = {}
    summ = Path(f"{prefix}summary.txt")
    if summ.exists():
        summary = {k: int(v) for k, v in re.findall(r"(\w+)=(-?\d+)", summ.read_text())}
    stuck = summary.get("stuck_fifos", 0)
    verdict = "PASS" if not missing and not extra else ("HANG" if stuck else "LOSS")

    nlog, log_errors = master_logs(prefix)
    res = {
        "verdict": verdict, "expected": sum(exp.values()), "delivered": sum(hit.values()),
        "missing": missing, "extra": extra, "stuck": stuck,
        "per_category": {c: (per_category(hit)[c], per_category(exp)[c]) for c in CATEGORIES},
        "log_lines": nlog, "log_errors": log_errors, "summary": summary,
    }
    res["ok"] = verdict == "PASS" and not log_errors
    if golden_dir:
        ok, msg = regression(golden_dir, data_dir, tables, obs, topology)
        res["regression"] = msg
        res["ok"] = res["ok"] and ok
    return res


def describe(res, prefix):
    cats = " ".join(f"{c}={h}/{e}" for c, (h, e) in res["per_category"].items())
    return (f"{res['verdict']} {res['delivered']}/{res['expected']} [{cats}] "
            f"missing={sum(res['missing'].values())} unexpected={sum(res['extra'].values())} "
            f"stuck_fifos={res['stuck']}  {prefix}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("prefix")
    ap.add_argument("--data", default="data/baseline")
    ap.add_argument("--topology", default="NOC1", choices=route_trace.TOPOLOGIES)
    ap.add_argument("--regress", metavar="GOLDEN_DIR")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    res = evaluate(a.prefix, a.data, a.topology, a.regress)
    print(describe(res, a.prefix))
    if not a.quiet:
        for k, n in sorted(res["missing"].items()):
            print(f"  missing  x{n} {category(k[0], k[1]):9} at P{k[0]}: src=P{k[1]} resp=P{k[2]} "
                  f"hops={k[3]} check={k[4]} data={k[5]}")
        for k, n in sorted(res["extra"].items()):
            print(f"  unexpect x{n} {category(k[0], k[1]):9} at P{k[0]}: src=P{k[1]} resp=P{k[2]} "
                  f"hops={k[3]} check={k[4]} data={k[5]}")
    if res["log_errors"]:
        print(f"master logs: {len(res['log_errors'])} errors")
        for e in res["log_errors"][:10]:
            print(f"  {e}")
    elif not a.quiet:
        print(f"master logs: {res['log_lines']} lines consistent with the testbench")
    if "regression" in res:
        print(res["regression"])
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
