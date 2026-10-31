#!/usr/bin/env python3
"""Where the area goes on the U200: per SLR, and per part (the routed utilization reports).

    tools/area_report.py [--slr RPT] [--hier RPT] [--svg OUT]

Reads Vitis' `impl_1_slr_util_routed.rpt` (per-SLR used/available; the counts below are exact for
the build named in the report) and the hierarchical utilization report (per-part totals): prints
ASCII charts and writes an SVG.
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RES = ["LUT", "FF", "LUTRAM", "RAMB36", "URAM", "DSP"]
CAP = {"LUT": 1_182_240 // 3, "FF": 2_364_480 // 3, "LUTRAM": 591_840 // 3,
       "RAMB36": 720, "URAM": 320, "DSP": 2_280}      # per SLR


def parse_slr(p: Path) -> tuple[dict, dict]:
    """{slr: {res: used}}, {res: available per SLR}"""
    used: dict[str, dict[str, int]] = {}
    avail: dict[str, int] = {}
    txt = p.read_text()
    for ln in txt.splitlines():
        f = [x.strip() for x in ln.strip().strip("|").split("|")]
        if len(f) < 7:
            continue
        name = f[0]
        try:
            vals = [int(f[i]) for i in (1, 2, 3)]
            pct = [float(f[i]) for i in (4, 5, 6)]
        except ValueError:
            continue
        if name in ("CLB LUTs", "CLB Registers", "URAM", "DSPs"):
            res = {"CLB LUTs": "LUT", "CLB Registers": "FF", "DSPs": "DSP"}.get(name, name)
            for i, slr in enumerate(("SLR0", "SLR1", "SLR2")):
                used.setdefault(slr, {})[res] = vals[i]
                if pct[i] > 0:
                    avail[res] = round(vals[i] / (pct[i] / 100.0))
        elif name == "RAMB36/FIFO":
            for i, slr in enumerate(("SLR0", "SLR1", "SLR2")):
                used.setdefault(slr, {})["RAMB36"] = vals[i]
                if pct[i] > 0:
                    avail["RAMB36"] = round(vals[i] / (pct[i] / 100.0))
        elif name == "LUT as Memory":
            for i, slr in enumerate(("SLR0", "SLR1", "SLR2")):
                used.setdefault(slr, {})["LUTRAM"] = vals[i]
                if pct[i] > 0:
                    avail["LUTRAM"] = round(vals[i] / (pct[i] / 100.0))
    return used, avail


def parse_hier(p: Path) -> list[tuple[str, int, int, int, int, int, str]]:
    """[(instance, LUT, FF, RAMB36, URAM, DSP, PR attribute)] in report order"""
    out = []
    for ln in p.read_text().splitlines():
        if not ln.startswith("|"):
            continue
        f = [x.strip() for x in ln.strip().strip("|").split("|")]
        if len(f) < 13:
            continue
        try:
            lut, ff, r36, uram, dsp = (int(f[4]), int(f[8]), int(f[9]), int(f[11]), int(f[12]))
        except ValueError:
            continue
        out.append((f[0], lut, ff, r36, uram, dsp, f[2]))
    return out


def bar(frac: float, width: int = 28) -> str:
    n = max(0, min(width, round(frac * width)))
    return "#" * n + "." * (width - n)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--slr", default=str(ROOT / "_x/reports/link/imp/impl_1_slr_util_routed.rpt"))
    ap.add_argument("--hier", default="/tmp/fp18_diag_util_hier.rpt")
    ap.add_argument("--svg", default=str(ROOT / "docs/reports/fp18/area_by_slr.svg"))
    ap.add_argument("--build", default="fp18 @ 200 MHz (TMEM_WORDS 32768, 2 DDR controllers)")
    a = ap.parse_args()

    used, avail = parse_slr(Path(a.slr))
    hier = {i: (lut, ff, r36, uram, dsp) for i, lut, ff, r36, uram, dsp, _ in parse_hier(Path(a.hier))}

    print(f"Alveo U200 (xcu200-fsgd2104), 3 SLRs -- {a.build}")
    print("bar = used / capacity of that SLR (exact counts from the routed report)\n")
    groups = [("LUT", "FF", "LUTRAM"), ("RAMB36", "URAM", "DSP")]
    for grp in groups:
        heads = "".join(f"{f'{r} {CAP[r]:,}/SLR':<34s}" for r in grp)
        print(heads)
        for slr in ("SLR0", "SLR1", "SLR2"):
            line = ""
            for r in grp:
                u = used.get(slr, {}).get(r, 0)
                frac = u / CAP[r]
                nb = round(frac * 15)
                fill, empty = "\u2588" * nb, "\u2591" * (15 - nb)
                line += f"{slr} {fill}{empty} {100*frac:4.1f}% {u:>7,d}/{CAP[r]:<8,d}"
                line += "  "
            print(line.rstrip())
        print()
    print("\n  what sits where (pblocks for ours; the shell spreads over SLR0/SLR1 and all of SLR2):")
    print("  SLR0  u_board (slice: MXU/VPU/QUANT/ACT/TMEM 192 RAMB36/48 URAM) + the 2 native-bus")
    print("        tx slices; also the flow-placed Vitis memory subsystem and part of the shell")
    print("  SLR1  otpu_mem_ch x2 + otpu_axi_dram x2 + dram_base + reset syncs + 2 rx slices,")
    print("        the memory subsystem's AXI/DDR side, and the shell (XDMA + 4 DDR4 MIGs)")
    print("  SLR2  shell / kernel-port pipeline residue only (0.8 % LUT)")

    print("\n  exact per-part totals (post-route, every instantiated part):")
    print(f"  {'part':30s} {'LUT':>9s} {'FF':>9s} {'RAMB36':>7s} {'URAM':>5s} {'DSP':>5s}  region")
    tot = hier.get("level0_wrapper", (1, 1, 1, 1, 1))
    parts = [("shell (blp, static)", "blp"), ("kernel-port pipe (static)", "ii_level0_pipe"),
             ("ours: OtpuCoreKernel_1", "OtpuCoreKernel_1"),
             ("Vitis memory subsystem", "memory_subsystem"),
             ("interrupt ctrl + AXI clocks", "ict_axi_data_h2c_01")]
    for label, key in parts:
        v = hier.get(key, (0, 0, 0, 0, 0))
        reg = "static" if key in ("blp", "ii_level0_pipe") else "reconfig"
        print(f"  {label:30s} {v[0]:9,d} {v[1]:9,d} {v[2]:7d} {v[3]:5d} {v[4]:5d}  {reg}")
    print(f"  {'total':30s} {tot[0]:9,d} {tot[1]:9,d} {tot[2]:7d} {tot[3]:5d} {tot[4]:5d}")

    print("\n  the design's LUTs, by part (share of 326,722):")
    for label, key in parts:
        v = hier.get(key, (0, 0, 0, 0, 0))
        print(f"  {label:30s} {bar(v[0]/tot[0], 40)} {100*v[0]/tot[0]:5.1f} %")
    rest = tot[0] - sum(hier.get(k, (0, 0, 0, 0, 0))[0] for _, k in parts)
    print(f"  {'other reconfig blocks':30s} {bar(rest/tot[0], 40)} {100*rest/tot[0]:5.1f} %")

    print("\n  inside our kernel (exact from the RTL parameters, where the arrays are big enough to")
    print("  matter; the kernel totals are 125,269 LUT / 129,206 FF / 189 RAMB36 / 48 URAM / 727 DSP):")
    print("  TMEM (6 copies x 8 banks x 4 RAMB36, 32K words)      192 RAMB36   -> SLR0")
    print("  MXU (systolic array + epilogue)                        727 DSP      -> SLR0")
    print("  write-data FIFOs of the 2 AXI bridges (2 x 16 x 576)   36,864 FF    -> SLR1")
    print("  mem_ch x2 (u_of/u_aq/u_ad/u_xq/u_xd + control)         LUTRAM/BRAM/FF -> SLR1")
    print("  slice logic (seq, VPU, quant, ACT RAM, trace, ctrl)    the rest     -> SLR0")

    print("\n  what is provably exact about the kernel's own split:")
    print("    URAM  48 of the SLR0's 48 are ours (the kernel has 48; the shell's 20 are in SLR1)")
    print("    DSP  727 of SLR0's 730 are ours (the MXU; the other 3 are the memory subsystem's)")
    print("    RAMB36  SLR0 250 = ours 189 (the TMEM) + 61 of the memory subsystem's 97;")
    print("            SLR1 238 = the shell's 202 (four DDR4 MIGs) + the other 36")
    print("    LUT/FF per part per SLR: needs `report_utilization -pblocks` on the routed")
    print("    checkpoint, which v++ deletes -- constraints/core_diag.tcl now asks for it")
    print("    (OTPU_DIAG=<prefix>), so the next build records pblock_util.rpt.")

    # ------------------------------------------------------------------ SVG
    out = Path(a.svg)
    out.parent.mkdir(parents=True, exist_ok=True)
    W, H = 1180, 760
    rows = []
    y = 150
    colors = {"LUT": "#2f81f7", "FF": "#3fb950", "LUTRAM": "#a371f7", "RAMB36": "#d29922",
              "URAM": "#db61a2", "DSP": "#f85149"}
    for slr in ("SLR0", "SLR1", "SLR2"):
        rows.append(f'<text x="24" y="{y}" class="lbl">{slr}</text>')
        yy = y - 16
        for r in RES:
            u = used.get(slr, {}).get(r, 0)
            av = CAP[r]
            frac = u / av
            rows.append(f'<text x="80" y="{yy+12}" class="sm">{r}</text>')
            rows.append(f'<rect x="150" y="{yy}" width="{900*frac:.1f}" height="14" fill="{colors[r]}" rx="2"/>')
            rows.append(f'<rect x="150" y="{yy}" width="900" height="14" fill="none" stroke="#30363d"/>')
            rows.append(f'<text x="1060" y="{yy+12}" class="sm">{u:,} / {av:,}  ({100*frac:.0f} %)</text>')
            yy += 20
        y += 6 * 20 + 34
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
<style>
 .t {{font:600 22px system-ui,sans-serif;fill:#e6edf3}} .s {{font:400 13px system-ui,sans-serif;fill:#8b949e}}
 .lbl {{font:700 16px system-ui,sans-serif;fill:#e6edf3}} .sm {{font:400 12px ui-monospace,monospace;fill:#c9d1d9}}
</style>
<rect width="{W}" height="{H}" fill="#0d1117"/>
<text x="24" y="42" class="t">Alveo U200 area by SLR — {a.build}</text>
<text x="24" y="66" class="s">post-route, from impl_1_slr_util_routed.rpt and the hierarchical utilization report; bar = used fraction of that SLR's resource</text>
{chr(10).join(rows)}
</svg>'''
    out.write_text(svg)
    print(f"\n  SVG: {out.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
