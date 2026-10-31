#!/usr/bin/env python3
"""Run a heavy Qwen workload N times on a given image and report pass/fail, the measured clock and
the die temperature -- the comparison fp13 (WNS +0.015 ns) and fp14 (133.33 MHz) need.

    tools/stress_2bank.py --xclbin X.xclbin --runs 10 [--reps 51 --tokens 64]
"""
from __future__ import annotations

import argparse
import os
import threading
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# temp4 = the FPGA die (the one that matters), temp1 = PCB TOP FRONT (what this tool used to
# read, which hid the junction temperature), temp6-9 = DIMM0-3
TEMP = sorted(Path("/sys/bus/pci/devices").glob("0000:01:00.0/hwmon/hwmon*/temp4_input"))
PCB  = sorted(Path("/sys/bus/pci/devices").glob("0000:01:00.0/hwmon/hwmon*/temp1_input"))
DIMM = sorted(Path("/sys/bus/pci/devices").glob("0000:01:00.0/hwmon/hwmon*/temp6_input"))


def pcb_raw() -> int:
    for p in PCB:
        try:
            return int(p.read_text().strip())
        except OSError:
            pass
    return 0


def temp_raw() -> int:
    for p in TEMP:
        try:
            return int(p.read_text().strip())
        except OSError:
            pass
    return 0


def temp_c() -> str:
    for p in TEMP:
        try:
            return f"{int(p.read_text().strip()) / 1000:.0f}C"
        except OSError:
            pass
    return "?"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--xclbin", required=True)
    ap.add_argument("--runs", type=int, default=10)
    ap.add_argument("--reps", type=int, default=51)
    ap.add_argument("--tokens", type=int, default=64)
    ap.add_argument("--max-temp", type=float, default=85.0,
                    help="abort before the next run if the FPGA is hotter than this (C)")
    a = ap.parse_args()
    prompt = "The quick brown fox jumps over the lazy dog. " * a.reps
    env = dict(os.environ, OTPU_XCLBIN=a.xclbin)
    bad = 0
    for i in range(1, a.runs + 1):
        if temp_raw() / 1000.0 > a.max_temp:
            print(f"stopping: FPGA at {temp_raw() / 1000:.0f}C > {a.max_temp:.0f}C "
                  f"(the card is passively cooled; see docs/u200.md)")
            bad += a.runs - i + 1
            break
        t0 = time.time()
        peak = [0]

        def watch() -> None:                     # the FPGA temperature while the run is going
            while not done[0]:
                peak[0] = max(peak[0], temp_raw())
                time.sleep(1.0)

        done = [False]
        th = threading.Thread(target=watch, daemon=True)
        th.start()
        r = subprocess.run([sys.executable, "-m", "opentpu.host.chat", "--model", "qwen3",
                            "--backend", "board", "--greedy", "--max-new", str(a.tokens),
                            "--plain", "--prompt", prompt],
                           cwd=ROOT, env=env, capture_output=True, text=True, timeout=1800)
        done[0] = True
        th.join(timeout=2)
        out = r.stdout + r.stderr
        err = ("AXI_ERR" in out) or ("RuntimeError" in out) or r.returncode != 0
        bad += err
        line = next((l for l in out.splitlines() if "decode" in l and "tok/s" in l), "")
        print(f"[{i}/{a.runs}] {'FAIL' if err else 'ok  '} peak {peak[0] / 1000:.0f}C "
              f"(pcb {pcb_raw() / 1000:.0f}C now {temp_c()}) {time.time() - t0:5.1f}s  "
              f"{line.strip()[:120]}", flush=True)
        if err:
            for l in out.splitlines():
                if "AXI_ERR" in l or "RuntimeError" in l:
                    print("        " + l.strip()[:160], flush=True)
    print(f"\n{a.runs - bad}/{a.runs} clean")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
