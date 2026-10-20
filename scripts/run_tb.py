#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Aref Ghoreishi
"""Run one GHDL testbench and decide PASS/FAIL strictly.

usage: run_tb.py UNIT [-gNAME=VALUE ...] [--pass TOKEN] [--expect-errors N]
                      [--expect-fail TEXT] [--log FILE]

PASS needs all of: exit status 0, the testbench's own TOKEN line (default
"<UNIT upper-case> PASS"), and exactly N error reports from the simulation
(default 0). With --expect-fail the run must instead stop with a non-zero exit
status and print TEXT. The one-line result goes to stdout; the full simulator
output to --log (default build/logs/<unit>.log).
"""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ERROR_RE = re.compile(r"\((?:report|assertion) (?:error|failure)\)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("unit")
    ap.add_argument("generics", nargs="*", help="-gNAME=VALUE overrides")
    ap.add_argument("--pass", dest="token")
    ap.add_argument("--expect-errors", type=int, default=0)
    ap.add_argument("--expect-fail")
    ap.add_argument("--log")
    ap.add_argument("--ghdl", default=os.environ.get("GHDL", "ghdl"))
    ap.add_argument("--workdir", default="build/work")
    a, extra = ap.parse_known_args()
    generics = a.generics + extra

    token = a.token or f"{a.unit.upper()} PASS"
    label = " ".join([a.unit] + [g[2:] for g in generics])
    log = Path(a.log or f"build/logs/{a.unit}{''.join('_' + g[2:].replace('=', '-').replace('/', '_') for g in generics)}.log")
    log.parent.mkdir(parents=True, exist_ok=True)

    cmd = [a.ghdl, "--elab-run", "--std=08", f"--workdir={a.workdir}", a.unit] + generics
    proc = subprocess.run(cmd, capture_output=True, text=True)
    out = proc.stdout + proc.stderr
    log.write_text(out)
    errors = len(ERROR_RE.findall(out))

    if a.expect_fail:
        ok = proc.returncode != 0 and a.expect_fail in out
        why = f"stopped with exit {proc.returncode}: {a.expect_fail}" if ok else \
              f"expected a stop with '{a.expect_fail}', got exit {proc.returncode}"
    else:
        passed = re.search(re.escape(token) + r".*", out)
        ok = proc.returncode == 0 and passed is not None and errors == a.expect_errors
        if ok:
            why = passed.group(0).strip()
            if a.expect_errors:
                why += f" ({errors} planted errors reported, as expected)"
        else:
            first = next((l for l in out.splitlines() if ERROR_RE.search(l)), "")
            why = (f"exit {proc.returncode}, {errors} error reports (expected {a.expect_errors}), "
                   f"'{token}' {'found' if passed else 'missing'}; see {log}"
                   + (f"\n      first error: {first.strip()}" if first else ""))
    print(f"{'PASS' if ok else 'FAIL'}  {label:46} {why}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
