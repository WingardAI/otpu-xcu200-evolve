#!/usr/bin/env python3
"""Sweep sim/verilator/tb_2ch_axi.sv (two DDR controllers behind two otpu_mem_ch + otpu_axi_dram)
over controller timings, looking for the mem_ch contract violation the fp13 card image showed:
read data on both ports in one cycle, or a beat with no read outstanding.

    tools/repro_2ch_axi.py            # the default sweep (~4 min)
    tools/repro_2ch_axi.py --quick    # a few combos
    tools/repro_2ch_axi.py --submit   # one combo: --lat0 8 --gap0 0 --lat1 40 --gap1 2 ...
"""
from __future__ import annotations

import argparse
import itertools
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TB = "sim/verilator/tb_2ch_axi.sv"
SRC = ["sim/verilator/axi_mem_model.sv", "rtl/mem/otpu_axi_dram.sv",
       "rtl/shell/otpu_mem_ch.sv", "rtl/shell/otpu_afifo.sv"]


def run(tmp: Path, combo: dict, scen: str) -> tuple[str, str]:
    params = [f"-Ptb_2ch_axi.{k}={v}" for k, v in combo.items()]
    exe = tmp / "tb"
    cmd = ["iverilog", "-g2012", *params, "-o", str(exe), TB, *SRC]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        return "COMPILE-FAIL", r.stderr[-2000:]
    r = subprocess.run(["vvp", str(exe), f"+scen={scen}", "+seed=7"], cwd=ROOT,
                       capture_output=True, text=True, timeout=900)
    out = r.stdout + r.stderr
    if "VIOLATION" in out:
        return "VIOLATION", out
    if "\nFAIL" in out:
        return "FAIL", out
    if "PASS: two channels" in out:
        return "PASS", out
    return "UNKNOWN", out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--scen", default="all")
    a = ap.parse_args()

    if not shutil.which("iverilog") or not shutil.which("vvp"):
        print("iverilog/vvp not installed")
        return 2

    if a.quick:
        combos = [dict(RLAT0=8, RGAP0=0, WLAT0=4, RLAT1=40, RGAP1=2, WLAT1=16, RJIT=0),
                  dict(RLAT0=8, RGAP0=0, WLAT0=4, RLAT1=300, RGAP1=8, WLAT1=64, RJIT=16)]
    else:
        # the two controllers span: same timings, and very different (one fast, one deep/gappy).
        # RJIT models a DDR4 controller whose latency depends on bank/page state.
        combos = [dict(RLAT0=r0, RGAP0=g0, WLAT0=w0, RLAT1=r1, RGAP1=g1, WLAT1=w1, RJIT=j)
                  for (r0, g0), (r1, g1), j, (w0, w1) in itertools.product(
                      [(8, 0), (40, 2)], [(8, 0), (40, 2), (120, 4), (300, 8)],
                      [0, 16], [(4, 16), (64, 64)])]

    bad = 0
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        for i, c in enumerate(combos, 1):
            st, out = run(tmp, c, a.scen)
            tag = " ".join(f"{k}={v}" for k, v in c.items())
            print(f"[{i}/{len(combos)}] {st:9s} {tag}", flush=True)
            if st != "PASS":
                bad += 1
                (tmp / f"fail{i}.log").write_text(out)
                for line in out.splitlines():
                    if "VIOLATION" in line or line.startswith("FAIL") or "FAIL:" in line:
                        print("        " + line.strip(), flush=True)
                keep = ROOT / "docs/reports/repro_2ch"
                keep.mkdir(parents=True, exist_ok=True)
                (keep / f"fail{i}.log").write_text(f"{tag}\n{out}")
        print(f"\n{len(combos) - bad}/{len(combos)} PASS, {bad} failing")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
