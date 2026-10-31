# New in the XCU200 port (WingardAI, 2026) for openTPU,
# https://github.com/FeSens/openTPU (Apache-2.0). See NOTICE.

"""Probe the resident pool's window pages, one page at a time (docs/u200.md).

The `pool` selftest stage failed on the card and could not say which page broke: this tool
tests every page separately and, because a failed run latches STATUS AXI_ERR (sticky until the
bitstream is reconfigured), **reconfigures between failures** (`xbutil program` of a *different*
image, then the window image again -- XRT does not reprogram for the image already loaded) and
carries on with the next page. One invocation therefore maps the whole boundary.

For each page it reports

  * the page's AXI base and how far it sits into its bank and into its BO,
  * whether the host reads back what it wrote into the page (`pool_read`),
  * whether the card, under the window, reads the same beat back,
  * whether the card, under the window, *writes* the page (and the host reads that back).

    python3 tools/offload/pool_probe.py                       # fp24, 4 pages, 2 GiB BOs
    python3 tools/offload/pool_probe.py --pages 6 --bo 2G     # 3 BOs a channel: +2/+4/+6 GiB
    python3 tools/offload/pool_probe.py --pages 4 --bo 1G     # one page a BO: +2/+3/+4/+5 GiB
    python3 tools/offload/pool_probe.py --ch 1 --offset 0     # one channel, one offset
    python3 tools/offload/pool_probe.py --direct --pages 6    # no window at all: 2..7 GiB into
                                                             # a big channel BO (OTPU_CH_GIB)
    python3 tools/offload/pool_probe.py --resident             # the resident layout at full
                                                             # scale: its BOs, layer windows,
                                                             # and a synthetic fill (fast)

`--direct` isolates the shell from the window: with a channel BO that reaches past the pool
floor and `win == 0`, the design maps a pool-region beat to `base + beat << 6`, i.e. straight
into the BO at 2 GiB + k, which is where the window would have pointed it.

Recovery needs `xbutil` on PATH (source /opt/xilinx/xrt/setup.sh) and a *different* kernel image
to load in between (`--reset-xclbin`; default: the S=1 fp18 build). `--no-reset` stops at the
first failure instead, for a run that must not reconfigure.
"""
from __future__ import annotations

import argparse
import re
import time
import subprocess
import sys
import traceback

import numpy as np

from opentpu import isa as I
from opentpu.host import regs as R
from opentpu.host.board import BEAT, Board, beat_at

FP24 = "boards/u200-vitis/build/OtpuCoreKernel_fp24_189mhz_window.xclbin"
FP18 = "boards/u200-vitis/build/OtpuCoreKernel_fp18_200mhz_2ddr.xclbin"
PAGE = 1 << 30
BANK = 16 << 30                      # a U200 DDR4 bank (MEM_TOPOLOGY: 0x40/0x50/0x60/0x70_..)
SRC, OUT, PROG = 0x20000, 0x30000, 0x3C0000     # ordinary DRAM: a word, a result, the program


def size(s: str) -> int:
    """'2G', '1024M', '0x4000_0000' -> bytes."""
    mult = {"k": 1 << 10, "m": 1 << 20, "g": 1 << 30}
    s = str(s).strip().lower().replace("_", "")
    if s and s[-1] in mult:
        return int(float(s[:-1]) * mult[s[-1]])
    return int(s, 0) if s.startswith("0x") else int(s)


def pool_logical(ch: int, inwin: int, board) -> int:
    """The 32-bit logical DRAM address whose beat lands on channel `ch` at channel offset
    POOL_LO + `inwin` (the byte the window page maps it to). The two beats of a chunk differ
    only in the channel hash, so a +64 shift picks the other channel and keeps the offset."""
    a = 0x8000_0000 + 2 * inwin
    for cand in (a, a + BEAT):
        c, off = beat_at(cand, chash=getattr(board, "chash", True))
        if c == ch and off == 0x4000_0000 + inwin:
            return cand
    raise RuntimeError(f"no logical address for channel {ch} at page offset {inwin:#x}")


def bdf() -> str | None:
    """The card's Bus:Device.Function as xbutil prints it."""
    try:
        r = subprocess.run(["xbutil", "examine"], capture_output=True, text=True, timeout=120)
        m = re.search(r"\[(0000:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7])\]", r.stdout)
        return m.group(1) if m else None
    except Exception:                                        # noqa: BLE001
        return None


class Probe:
    def __init__(self, a):
        self.a = a
        self.reset_n = 0
        self.failures = []
        self.chans = None

    def open(self):
        """A transport on the window image: opening loads it, which is the reconfiguration."""
        from opentpu.host.xrt import XrtTransport
        self.t = XrtTransport(self.a.xclbin)
        self.board = Board(self.t, check=False)

    def pages(self) -> None:
        """Give the current transport its pool pages (new BOs after every open)."""
        t = self.t
        if not self.a.pages:
            return
        t.alloc_pool(self.a.pages, PAGE, self.a.bo, chans=self.chans)
        gib = sum(len(v) for v in t._pool.values()) * PAGE / (1 << 30)
        print(f"pool           {gib:.0f} GiB of pages over channels {self.chans}, "
              f"{self.a.bo // PAGE} a BO (+ {t.nch * t.ch_bytes / (1 << 30):.0f} GiB"
              " channel BOs, host-shadowed)")
        for ch in self.chans:
            print(f"channel {ch}      {len(t._pool[ch])} pages: "
                  + ", ".join(f"{t.pool_page(ch, i):#x}" for i in range(len(t._pool[ch]))))

    def arm(self) -> None:
        """A transport with its pool pages, on a configuration that carries no latched error: a
        previous run's AXI_ERR blocks every later transaction until the bitstream is reloaded."""
        self.open()
        if self.chans is None:                     # the transport knows: 4, or as OTPU_XRT_BO_GROUPS
            self.chans = list(range(self.t.nch))
        self.pages()
        st = self.t.reg_read(R.R_STATUS)
        if st & R.ST_AXI_ERR:
            print(f"STATUS {st:#x} (AXI_ERR) is latched from an earlier run: reconfiguring")
            self.reconfigure()

    def reconfigure(self) -> bool:
        """Clear the latched AXI_ERR: load a *different* image, then reopen on the window one."""
        self.t.close()
        b = self.a.bdf or bdf()
        if not b:
            print("         cannot find the card's BDF for xbutil program")
            return False
        r = subprocess.run(["xbutil", "program", "-d", b, "-u", self.a.reset_xclbin],
                           capture_output=True, text=True, timeout=600)
        if r.returncode or "succeeded" not in r.stdout:
            print(f"         xbutil program {self.a.reset_xclbin} failed: "
                  f"{r.stdout.strip().splitlines()[-1] if r.stdout else r.stderr.strip()}")
            return False
        self.reset_n += 1
        self.open()
        self.pages()
        return True

    def scrub(self, ch: int) -> None:
        """Zeros over every pool page of `ch` in 64 MiB pieces: a beat never written since the
        card was powered reads as an uncorrectable ECC word (the MIG answers SLVERR), so a
        pool BO must be initialised before anything reads it -- docs/u200.md."""
        t = self.t
        z = np.zeros(min(64 << 20, PAGE), np.uint8)
        t0 = time.time()
        for i in range(len(t._pool[ch])):
            off = 0
            while off < PAGE:
                n = min(len(z), PAGE - off)
                t.pool_write(ch, i, off, z[:n])
                off += n
        print(f"scrub          {len(t._pool[ch])} GiB of pages on channel {ch} in "
              f"{time.time() - t0:.1f}s")

    @staticmethod
    def value(i: int, j: int) -> tuple:
        """(what the page must hold as a read, what the card's write must leave) for test point
        (i, j): exact small fp32s, distinct per point."""
        v = np.float32(i * 16 + j + 1) + np.float32(0.5)
        return np.float32(float(v)), np.float32(float(v) + 32.0)

    def direct(self, ch: int, k: int) -> bool:
        """Card read/write at 2 GiB + k GiB of the channel BO with **no window**: the same
        address the window pointed at, reached by plain `base + beat << 6`."""
        t, b, a = self.t, self.board, self.a
        floor = a.floor
        print(f"  offset {(floor + k * PAGE) / (1 << 30):.2f} GiB  (no window)", end="")
        for j, o in enumerate(a.offset):
            off = floor + k * PAGE + o
            if off + BEAT > t.ch_bytes:
                print(f"\n    +{o:#x}: past the channel BO ({t.ch_bytes:#x})")
                return True
            logical = 2 * off                          # channel offset = logical / 2 (identity:
                                                       # win == 0 maps every beat to base+off)
            c, coff = beat_at(logical, chash=getattr(b, "chash", True))
            if c != ch:
                logical += BEAT
                c, coff = beat_at(logical, chash=getattr(b, "chash", True))
            assert c == ch and coff == off, f"{logical:#x} -> {c} {coff:#x}, want {ch} {off:#x}"
            v, w = self.value(k, j)
            got, want = {}, {"host": float(v), "read": float(v), "write": float(w)}
            try:
                t.mem_write(ch, off, np.array([v], np.float32).view(np.uint8))
                got["host"] = float(np.frombuffer(t.mem_read(ch, off, 4), np.float32)[0])
                b.load(PROG, [I.ld(logical, 0, 1), I.st(OUT, 0, 1), I.halt()])
                b.run(timeout=10.0)
                got["read"] = float(np.frombuffer(b.read(OUT, 4), np.float32)[0])
                b.write(SRC, np.array([w], np.float32).view(np.uint8))
                b.load(PROG, [I.ld(SRC, 0, 1), I.st(logical, 0, 1), I.halt()])
                b.run(timeout=10.0)
                got["write"] = float(np.frombuffer(t.mem_read(ch, off, 4), np.float32)[0])
            except Exception as e:                     # noqa: BLE001
                said = ", ".join(f"{n} {got[n]:g}" for n in ("host", "read", "write")
                                 if n in got)
                print(f"\n    +{o:#x} want {float(v):g}: {said + ', ' if said else ''}"
                      f"{type(e).__name__}: {e}")
                if a.verbose:
                    traceback.print_exc(limit=3)
                return False
            said = ", ".join(f"{n} {'ok' if got[n] == want[n] else f'{got[n]:g}'}"
                             for n in ("host", "read", "write"))
            print(f"\n    +{o:#x} want {float(v):g}: {said}", end="")
        print()
        return True

    def resident(self) -> bool:
        """The resident layout (docs/u200.md) at the model's own scale: a
        ResidentPool's BOs, a synthetic record for a few experts of the first and the last layer
        filled through `pool_write`, then the *card* reading them under each layer's window --
        the same path the engine's runs take, without the 17.5 GB fill."""
        from opentpu.host.offload import Layout, ResidentPool
        t, b, a = self.t, self.board, self.a
        L = Layout.resident(0x1000_0000, a.experts, a.k, a.layers, a.slot)
        pool = ResidentPool(L, t, bo=a.bo, chash=getattr(b, "chash", True))
        print(f"layout         pool {L.slot_bounds[0]:#x}..{L.slot_bounds[1]:#x}, "
              f"layer {L.layer_bytes / 2**20:.1f} MiB logical / {L.layer_channel / 2**20:.1f} MiB "
              f"a channel, {L.layers} layers")
        gib = pool.bytes * len(self.chans) / (1 << 30)
        print(f"plan           {pool.pages} BOs a channel "
              f"{[f'{x / (1 << 30):.0f}G' for x in pool.sizes]} = {gib:.1f} GiB both channels")
        rec = {}
        for j in (0, L.layers - 1):
            for e in (0, a.experts - 1):
                rec[j, e] = (np.arange(a.slot, dtype=np.uint8) * np.uint8(
                    (j * a.experts + e) % 251 + 1)).tobytes()
        # the fill, per expert: the record's bytes at its slot (the whole pitch, tags zero)
        for (j, e), want in rec.items():
            i, off = pool.layer_at[j]
            from opentpu.host.board import split
            buf = np.zeros(L.pitch, np.uint8)
            buf[:a.slot] = np.frombuffer(want, np.uint8)
            for ch, coff, part in split(L.slots[0][0] + e * L.pitch, buf, pool.chash):
                t.pool_write(ch, i, off + coff - L.slots[0][0] // 2, part)
        ok = True
        n = min(a.words, a.slot // 4, 4096)          # (TMEM is 64K words; DRAM at OUT is fine)
        span = n * 4
        for (j, e), want in rec.items():
            pool.set_layer(j)
            for o in (0, a.slot - span):
                addr = L.slots[0][0] + e * L.pitch + o
                b.load(PROG, [I.ld(addr, 0, n), I.st(OUT, 0, n), I.halt()])
                b.run(timeout=10.0)
                got = np.asarray(b.read(OUT, span), np.uint8)
                good = got.tobytes() == want[o:o + span]
                ch, coff = beat_at(addr, chash=getattr(b, "chash", True))
                host = t.mem_read(ch, coff, span)      # (the host's window-aware read)
                print(f"  layer {j:2d} expert {e:3d} +{o:#x} {span // 1024} KiB: card "
                      f"{'ok' if good else 'DIFFER'}  window {pool.window(0, j):#x}"
                      f"  ch {ch} host {'ok' if host.tobytes() == want[o:o + span] else 'DIFFER'}")
                if not good:
                    print(f"      want {want[o:o + 16].hex()}  card {got[:16].tobytes().hex()}"
                          f"  host {host[:16].tobytes().hex()}")
                ok = ok and good
        return ok

    def page(self, ch: int, i: int) -> bool:
        """Test one page: host echo, then the card's read and write through the window. A card
        step that fails latches AXI_ERR, so the page stops there and the caller reconfigures."""
        t, b, a = self.t, self.board, self.a
        base = t.pool_page(ch, i)
        bank0 = t.bases[ch] & ~(BANK - 1)              # the bank this channel's BO lives in
        print(f"  page {i}   {base:#x}  bank+{(base - bank0) / (1 << 30):.2f} GiB"
              f"  group {t.grp[ch]}")
        for k, o in enumerate(a.offset):
            if o + BEAT > PAGE:
                print(f"    offset {o:#x}: past the page")
                return False
            logical = pool_logical(ch, o, b)
            v, w = self.value(i, k)
            got, want = {}, {"host": float(v), "read": float(v), "write": float(w)}
            try:
                t.pool_write(ch, i, o, np.array([v], np.float32).view(np.uint8))
                got["host"] = float(np.frombuffer(t.pool_read(ch, i, o, 4), np.float32)[0])
                t.set_window(ch, base)                 # 2. the card reads the page
                # (0x320/0x324 are write-only in the kernel top: they read back DEADBEEF)
                b.load(PROG, [I.ld(logical, 0, 1), I.st(OUT, 0, 1), I.halt()])
                b.run(timeout=10.0)
                got["read"] = float(np.frombuffer(b.read(OUT, 4), np.float32)[0])
                b.write(SRC, np.array([w], np.float32).view(np.uint8))
                b.load(PROG, [I.ld(SRC, 0, 1), I.st(logical, 0, 1), I.halt()])
                b.run(timeout=10.0)                   # 3. the card writes the page
                got["write"] = float(np.frombuffer(t.pool_read(ch, i, o, 4), np.float32)[0])
            except Exception as e:                     # noqa: BLE001
                said = ", ".join(f"{n} {got[n]:g}" for n in ("host", "read", "write")
                                 if n in got)
                print(f"    offset {o:#x} want {float(v):g}: {said + ', ' if said else ''}"
                      f"{type(e).__name__}: {e}")
                if a.verbose:
                    traceback.print_exc(limit=3)
                return False
            finally:
                t.set_window(ch, 0)
            said = ", ".join(f"{n} {'ok' if got[n] == want[n] else f'{got[n]:g}'}"
                             for n in ("host", "read", "write"))
            print(f"    offset {o:#x} want {float(v):g}: {said}")
            if any(got.get(n) != want[n] for n in want):
                print(f"         card page {i}: first mismatch at offset {o:#x}")
                return False
        return True

    def run(self) -> int:
        a = self.a
        self.chans = None if a.ch is None else [a.ch]
        if a.direct or a.resident:
            a.pages = 0
        print(f"xclbin         {a.xclbin}")
        self.arm()
        t = self.t
        chans = self.chans
        print(f"clock          {t.core_khz / 1000:.1f} MHz" if t.core_khz else "clock    n/a")
        print(f"channel BO     {t.ch_bytes:#x} bytes, groups {t.grp}")
        print(f"channel bases  " + ", ".join(f"{c}:{base:#x}" for c, base in enumerate(t.bases)))
        try:
            for ch in chans:
                print()
                if a.scrub:
                    self.scrub(ch)
                if a.resident:
                    if self.resident():
                        continue
                    self.failures.append((ch, "resident", 0))
                    if not a.reset or not self.reconfigure():
                        print("         stopping (no reconfigure)")
                        return 1
                    continue
                if a.direct:
                    for k in range(a.gib):
                        if a.floor + k * PAGE + max(a.offset) + BEAT > t.ch_bytes:
                            print(f"  offset {(a.floor + k * PAGE) / (1 << 30):.2f} GiB: past "
                                  f"the channel BO ({t.ch_bytes:#x}) -- stopping the sweep")
                            break
                        if self.direct(ch, k):
                            continue
                        self.failures.append((ch, f"{(a.floor + k * PAGE) / (1 << 30):.2f} GiB",
                                              t.bases[ch] + a.floor + k * PAGE))
                        print(f"         STATUS {t.reg_read(R.R_STATUS):#x}")
                        if not a.reset or not self.reconfigure():
                            print("         stopping (no reconfigure)")
                            return 1
                    continue
                for i in range(len(t._pool[ch])):
                    t = self.t
                    if self.page(ch, i):
                        continue
                    self.failures.append((ch, i, t.pool_page(ch, i)))
                    st = t.reg_read(R.R_STATUS)
                    print(f"         STATUS {st:#x}"
                          + (" (AXI_ERR)" if st & R.ST_AXI_ERR else ""))
                    if not a.reset or not self.reconfigure():
                        print("         stopping (no reconfigure)")
                        return 1
        finally:
            t.close()
        if self.failures:
            print(f"\nfailing pages ({self.reset_n} reconfigurations):")
            for ch, i, base in self.failures:
                print(f"  channel {ch} page/offset {i} at {base:#x}")
            return 1
        print("\nALL PAGES PASS")
        return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="pool_probe", description=__doc__.split("\n")[0])
    ap.add_argument("--xclbin", default=FP24, help="the window bitstream (default: fp24)")
    ap.add_argument("--pages", type=int, default=4, help="window pages a channel (default 4)")
    ap.add_argument("--bo", type=size, default="2G", help="pool BO size (default 2G)")
    ap.add_argument("--ch", type=int, default=None, help="one channel (default: all)")
    ap.add_argument("--offset", type=size, action="append", default=None,
                    help="a data offset inside a page (repeatable; default 0 and page - 128)")
    ap.add_argument("--reset-xclbin", default=FP18,
                    help="the image to load between failures (a *different* one)")
    ap.add_argument("--bdf", default=None, help="the card's BDF (default: from xbutil examine)")
    ap.add_argument("--scrub", action="store_true",
                    help="zero every pool page before testing (ECC on never-written beats)")
    ap.add_argument("--resident", action="store_true",
                    help="the resident layout at the model's scale (--layers/--experts/--slot)")
    ap.add_argument("--layers", type=int, default=40, help="--resident: MoE layers")
    ap.add_argument("--experts", type=int, default=256, help="--resident: experts a layer")
    ap.add_argument("--slot", type=int, default=1712128, help="--resident: slot bytes (fp4 35B)")
    ap.add_argument("--words", type=int, default=1024,
                    help="--resident: words read back at each point (default 1024 = 4 KiB)")
    ap.add_argument("--k", type=int, default=8, help="--resident: ids a request (top-k)")
    ap.add_argument("--direct", action="store_true",
                    help="no window: read/write 2 GiB + k GiB of the channel BO (needs "
                         "OTPU_CH_GIB > 2; set OTPU_XRT_BO_GROUPS=0,1 to halve the RAM)")
    ap.add_argument("--gib", type=int, default=6, help="--direct: how many GiB to test")
    ap.add_argument("--floor", type=size, default="2G",
                    help="--direct: the first channel offset to test (default 2G, the pool "
                         "floor; 1G reaches a 2 GiB channel BO's upper half)")
    ap.add_argument("--no-reset", action="store_true", help="stop at the first failing page")
    ap.add_argument("--verbose", action="store_true", help="print tracebacks")
    a = ap.parse_args(argv)
    a.offset = a.offset or [0, PAGE - 128]
    a.reset = not a.no_reset
    return Probe(a).run()


if __name__ == "__main__":
    sys.exit(main())
