# New in the XCU200 port (WingardAI, 2026) for openTPU,
# https://github.com/FeSens/openTPU (Apache-2.0). See NOTICE.

"""Simulated switching activity of the U200 core kernel (the power proxy): an idle window (the
machine halted, nothing to do) and a busy window (the demo program running), each as a VCD, plus
the per-block value-change counts.

    .venv/bin/python tools/power_activity.py --out /tmp/pw [--target u200-vitis] [--cycles 60]

The VCDs feed Vivado's power analysis: read_vcd -strip_path tb_board/u_board <file>, report_power
(tools/power_core.tcl). The counts answer the other half of the question -- whether anything runs
while the machine is idle -- per hierarchy scope: a block with ~0 changes at idle is effectively
clock-gated, one that keeps toggling burns dynamic power for nothing.

Builds the board model with Verilator --trace (OTPU_VFLAGS), so it does not share a build with the
normal simulation (rtlsim.build_dir keys on VFLAGS)."""
from __future__ import annotations

import argparse
import collections
import re
import sys
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))


def parse_vcd(path: Path, t0: int = -1, t1: int = 1 << 62
              ) -> tuple[dict[str, str], dict[str, int], dict[str, int]]:
    """(id -> hierarchical name, name -> value changes, scope -> value changes) of a VCD, the
    changes counted only between times t0 and t1 (Verilator writes the whole run)."""
    names: dict[str, str] = {}
    changes: collections.Counter = collections.Counter()
    scopes: collections.Counter = collections.Counter()
    scope: list[str] = []
    owners: dict[str, list[str]] = {}
    decl = re.compile(r"\$var\s+\S+\s+\d+\s+(\S+)\s+(\S+)")
    now = -1
    with open(path) as f:
        in_header = True
        for line in f:
            if in_header:
                t = line.split()
                if not t:
                    continue
                if t[0] == "$scope":
                    scope.append(t[2])
                elif t[0] == "$upscope":
                    if scope:
                        scope.pop()
                elif t[0] == "$var":
                    m = decl.search(line)
                    if m:
                        ident, name = m.group(1), m.group(2)
                        names[ident] = ".".join(scope + [name])
                        owners[ident] = list(scope)
                elif t[0] == "$enddefinitions":
                    in_header = False
                continue
            s = line.strip()
            if not s or s[0] == "$":
                continue
            if s[0] == "#":
                now = int(s[1:])
                continue
            if now < t0 or now > t1:
                continue
            ident = s.split()[-1] if s[0] in "bB" else s[1:]
            if ident in names:
                changes[names[ident]] += 1
                for i in range(1, len(owners[ident]) + 1):
                    scopes[".".join(owners[ident][:i])] += 1
    return names, dict(changes), dict(scopes)


def dense_program() -> list:
    """A matmul-heavy program (the shape of a decode step's MLP, not the demo's one-of-each): the
    weights and activations stay in TMEM/DRAM, the MXU runs back to back, so the window has the
    datapath activity that costs the power. 48 MM ops of 2 rows x 256 columns over 16 K-blocks."""
    from opentpu import isa as I
    from opentpu.host.checks import W8, SC, DATA, OUT
    prog = [I.ld(DATA, 0, 1024)]
    for k in range(48):
        prog.append(I.mm(W8, SC, 4096, 16, 2, 256, 16, 2, 0, 8))
        prog.append(I.vop(I.V_MUL, 2048, 0, 0, 4, 256, 256, 256, 0, I.B_SCALAR, 0.5))
    prog.append(I.halt())
    return prog


def cut_vcd(src: Path, dst: Path, t0: int, t1: int) -> int:
    """Copy a VCD's header and only the value changes between t0 and t1 into a small VCD (Vivado
    reads the activity from it; the whole file would be hundreds of MB). Returns the changes."""
    n = 0
    header = True                 # $version .. $enddefinitions
    in_win = False                # inside [t0, t1]
    with open(src) as f, open(dst, "w") as g:
        for line in f:
            if header:
                g.write(line)                     # (the indented $scope/$var lines too)
                if line.startswith("$enddefinitions"):
                    header = False
                    g.write(f"#{t0}\n")
                continue
            if line.startswith("#"):
                t = int(line[1:])
                if t > t1:
                    break
                in_win = t >= t0
                if in_win:
                    g.write(line)
                continue
            if in_win and line[:1] in "01xzbrRfFsS":
                g.write(line)
                n += 1
    return n


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="/tmp/pw")
    ap.add_argument("--target", default="u200-vitis")
    ap.add_argument("--cycles", type=int, default=60, help="VCD window length")
    ap.add_argument("--skip", type=int, default=200, help="busy: cycles into the run to start")
    ap.add_argument("--top", type=int, default=16, help="scopes to print")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)

    from opentpu import rtlsim
    from opentpu.host.board import Board, SimTransport
    from opentpu.host import checks
    from opentpu.target import current

    old = rtlsim.VFLAGS
    rtlsim.VFLAGS = old + ["--trace"]
    try:
        for name in ("idle", "busy"):
            vcd = out / f"activity_{name}.vcd"
            if vcd.exists():
                vcd.unlink()
            t = SimTransport(native="axi", target=a.target, plusargs=[f"+vcd={vcd}"])
            b = Board(t, check=True, lock=False)
            tw = int(t.target.arch["TMEM_WORDS"])
            b.write(checks.ZERO_AT, np.zeros(4 * tw, np.uint8))
            b.write(0, checks.demo_image())
            b.load(checks.PROG_AT, dense_program() if name == "busy" else checks.demo_program())
            b.start()                                # (the batched model queues everything)
            from opentpu.host.board import R_STATUS, ST_HALTED
            if name == "idle":                       # the window is the machine after it halted:
                t.poll(R_STATUS, ST_HALTED, ST_HALTED, 600.0)
                t.wait_cycles(20)                    # the core idle, its clocks still running
            else:                                    # mid-run (the demo's busy phase)
                t.wait_cycles(a.skip)
            t.mark("win0")
            t.wait_cycles(a.cycles)
            t.mark("win1")
            if name == "busy":
                t.poll(R_STATUS, ST_HALTED, ST_HALTED, 600.0)
            t0 = time.time()
            t.reg_read(0x000)                        # the flush that runs all of it
            assert not t.results or t.results[-1] & 0x1, 'the program did not halt'
            dt = time.time() - t0
            if not vcd.exists():
                print(f"{name}: NO VCD (did the build get --trace?)")
                continue
            marks = {lab: int(tm) for lab, tm in
                     (ln.split()[1:3] for ln in t.out.splitlines() if ln.startswith("MARK "))
                     if len((lab, tm)) == 2}
            w0, w1 = marks.get("win0", 0), marks.get("win1", 1 << 62)
            names, ch, sc = parse_vcd(vcd, w0, w1)
            print(f"  window {w0}..{w1} ({(w1 - w0) / 10:.0f} clock cycles)")
            print(f"\n{name}: {dt:.1f} s, VCD {vcd.stat().st_size / 1e6:.1f} MB, "
                  f"{len(names)} signals, {sum(ch.values())} value changes")
            top = sorted(sc.items(), key=lambda kv: -kv[1])
            for k, v in top[:a.top]:
                print(f"  {v:9d}  {k}")
            (out / f"activity_{name}.scopes.txt").write_text("\n".join(f"{v} {k}" for k, v in top))
            win = out / f"activity_{name}_win.vcd"
            nc = cut_vcd(vcd, win, w0, w1)
            print(f"  window VCD {win} ({nc} changes, {win.stat().st_size / 1e6:.1f} MB)")
            (out / f"activity_{name}.signals.txt").write_text(
                "\n".join(f"{v} {k}" for k, v in sorted(ch.items(), key=lambda kv: -kv[1])))
    finally:
        rtlsim.VFLAGS = old
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
