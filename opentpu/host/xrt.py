"""XRT transport for the U200 Vitis RTL kernel.

`pyxrt` 2.18 does not expose `xrt::ip` (arbitrary control registers) or `xrt::bo`, so this
transport goes through `libotpu_xrt.so` (opentpu/host/xrt_shim.cpp, built with the same XRT):

    XrtTransport("OtpuCoreKernel.xclbin")   # two 2 GiB BOs in memory group 1 (DDR[1])
    Board(XrtTransport(...))

It implements the `XdmaTransport` interface (`reg_read/write`, `mem_read/write`, `poll`) and
inherits `poll`. Each channel's BO is allocated in the memory bank group the xclbin's
CONNECTIVITY gives its m_axi argument (`xrt::kernel::group_id(arg)` semantics): the fp11 build
maps both `Dram0`/`Dram1` to DDR[1] (group 1, group 1), a build with `--connectivity.sp
...:DDR[0]`/`DDR[1]` gives (0, 1). The BOs' device addresses go to the kernel's base registers
(0x300/0x304 for channel 0, 0x308/0x30C for channel 1).

Only v++-built xclbins are ever loaded here: the memory topology in a hand-patched xclbin can
program the shell's address translation to something unintended ("--connectivity.sp at build
time", never post-build edits).
"""
from __future__ import annotations

import ctypes
import os
import re
import subprocess
from pathlib import Path

import numpy as np

from .board import BEAT, XdmaTransport

_LIB = Path(__file__).with_name("libotpu_xrt.so")


class XrtTransport(XdmaTransport):
    # The shell's DDR4 MIG runs with ECC and the check bits are random after a power cycle: a read
    # of a 64-byte beat that was never written is an *uncorrectable* error, which the MIG answers
    # with SLVERR -- the kernel's AXI bridge then reports RRESP != OKAY (STATUS AXI_ERR) and the run
    # dies. So the transport scrubs its own BOs (zeros) when it allocates them, once per process:
    # the BOs are new memory every time, so the design's SCRATCH "once per configuration" mark is
    # not enough. See docs/u200.md.
    ecc = True              # Board.scrub() then sees DRAM_INIT and does not scrub again
    scrubbed = False        # this process's BOs are zeros (scrub() in __init__)
    bases_are_bo = True     # `bases` holds BO device addresses here, not channel addresses:
                            # set_window/_win_addr convert with them, and Board.info() must
                            # not replace them with channel_map() (it does that for XDMA)
    threaded = False        # BO sync is cheap; no worker threads
    streams = False
    host_idle = 0.0
    batched = False
    keeps_state = True
    run_h2c = 1 << 20

    def __init__(self, xclbin: str, kernel: str = "OtpuCoreKernel",
                 ch_bytes: int = 2 << 30, group: int = 1, devname: str | None = None):
        gib = os.environ.get("OTPU_CH_GIB")   # a bigger BO a channel (a resident expert pool)
        if gib:
            ch_bytes = int(float(gib) * (1 << 30))
        self._lib = ctypes.CDLL(os.environ.get("OTPU_XRT_SHIM", str(_LIB)))
        L = self._lib
        L.otpu_xrt_open.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p,
                                    ctypes.c_int]
        L.otpu_xrt_open.restype = ctypes.c_void_p
        L.otpu_xrt_close.argtypes = [ctypes.c_void_p]
        L.otpu_xrt_read.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        L.otpu_xrt_read.restype = ctypes.c_uint32
        L.otpu_xrt_write.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32]
        L.otpu_xrt_bo.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
        L.otpu_xrt_bo.restype = ctypes.c_void_p
        L.otpu_xrt_bo_addr.argtypes = [ctypes.c_void_p]
        L.otpu_xrt_bo_addr.restype = ctypes.c_uint64
        L.otpu_xrt_bo_write.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
                                        ctypes.c_size_t]
        L.otpu_xrt_bo_write.restype = ctypes.c_int
        L.otpu_xrt_bo_read.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
                                       ctypes.c_size_t]
        L.otpu_xrt_bo_read.restype = ctypes.c_int
        L.otpu_xrt_bo_sync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        L.otpu_xrt_bo_sync.restype = ctypes.c_int
        L.otpu_xrt_bo_sync_range.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_size_t,
                                             ctypes.c_size_t]
        L.otpu_xrt_bo_sync_range.restype = ctypes.c_int

        err = ctypes.create_string_buffer(512)
        self._h = L.otpu_xrt_open(xclbin.encode(), kernel.encode(), err, len(err))
        if not self._h:
            raise RuntimeError(f"xrt open {xclbin}: {err.value.decode(errors='replace')}")
        self.bo = []
        # The BO's memory bank group per channel: the xclbin's CONNECTIVITY (what
        # xrt::kernel::group_id(arg) returns), so the BO lands in the bank the master is wired to.
        # OTPU_XRT_BO_GROUPS="<g0>,<g1>" overrides it; the constructor's `group` is the fallback.
        grp = _xclbin_bank_groups(xclbin, group)
        if os.environ.get("OTPU_XRT_BO_GROUPS"):
            grp = [int(g) for g in os.environ["OTPU_XRT_BO_GROUPS"].split(",")]
        if len(grp) not in (2, 4):
            raise RuntimeError("OTPU_XRT_BO_GROUPS wants 2 or 4 group ids, e.g. 0,1 or 0,1,2,3")
        self.nch, self.grp = len(grp), grp
        for ch in range(self.nch):
            b = L.otpu_xrt_bo(self._h, ch_bytes, grp[ch])
            if not b:
                self.close()
                raise RuntimeError(f"xrt BO allocation failed (group {grp[ch]})")
            self.bo.append(b)
        self.bases = [L.otpu_xrt_bo_addr(b) for b in self.bo]
        self.ch_bytes = ch_bytes
        self._scrub()
        for ch in range(self.nch):
            a = self.bases[ch]
            self.reg_write(0x300 + 8 * ch, a & 0xFFFFFFFF)
            self.reg_write(0x300 + 8 * ch + 4, a >> 32)
            self.set_window(ch, 0)      # no window: a previous process's pool pages are gone,
                                        # and its window would redirect this run's slots there
        self.core_khz = _xclbin_clock_khz(xclbin)
        self.devname = devname
        self.dev = f"/dev/{devname}" if devname else None
        self._otpu_lock = None

    def _scrub(self) -> None:
        """Zeros over every channel's BO: without it a read of a beat never written since the card
        was powered is an uncorrectable ECC error (see the class comment). Ends with
        SCRATCH = DRAM_INIT, the design's "this configuration is scrubbed" mark, so Board.scrub()
        does not repeat it. OTPU_XRT_NO_SCRUB=1 skips it (a register-only tool, or a rerun in the
        same process)."""
        if os.environ.get("OTPU_XRT_NO_SCRUB"):
            return
        z = np.zeros(64 << 20, np.uint8)
        for ch in range(self.nch):
            for off in range(0, self.ch_bytes, len(z)):
                n = min(len(z), self.ch_bytes - off)
                if self._lib.otpu_xrt_bo_write(self.bo[ch], z.ctypes.data, n, off) != 0:
                    raise RuntimeError(f"xrt BO scrub failed (channel {ch}, offset {off:#x})")
            if self._lib.otpu_xrt_bo_sync(self.bo[ch], 1) != 0:
                raise RuntimeError(f"xrt BO scrub sync failed (channel {ch})")
        from .regs import DRAM_INIT, R_SCRATCH
        self.reg_write(R_SCRATCH, DRAM_INIT)
        self.scrubbed = True

    # ---- control registers (the board's map at 0x00..) ----
    def reg_read(self, off: int) -> int:
        if not self._h:
            raise RuntimeError("xrt transport is closed")
        return int(self._lib.otpu_xrt_read(self._h, off))

    # ---- the pool window (docs/u200.md 3c): a beat of the channel's top 1 GiB names
    # `win` instead, so expert slots may live past the 4 GiB a slice addresses. win[ch] is the
    # AXI base of the window (a multiple of 1 GiB, 0 for none); POOL_LO/POOL_HI delimit the
    # channel-relative byte offsets the hardware redirects.
    POOL_LO = 0x4000_0000     # addr[30]: the upper 1 GiB of each channel's 2 GiB space
    POOL_HI = 0x8000_0000     # (addr[31] selects the channel: CH_LOG2 = 31)

    def set_window(self, ch: int, off: int) -> None:
        """Point channel ch's pool window at `off`: an offset in its own BO, or an absolute AXI
        address (a pool page, which lives in a BO of its own). 4 KiB aligned -- a coalesced AXI
        burst stays inside one 4 KiB page of the channel's space and the window adds its base to
        those addresses, so an unaligned window would make a burst cross a page; the hardware
        itself takes any 64-byte multiple (docs/u200.md). 0: no window."""
        if off % 4096:
            raise ValueError(f"window {off:#x}: not a multiple of 4 KiB")
        a = off if off >= self.bases[ch] else (self.bases[ch] + off if off else 0)
        self.reg_write(0x320 + 8 * ch, a & 0xFFFFFFFF)
        self.reg_write(0x320 + 8 * ch + 4, a >> 32)
        self._win = getattr(self, "_win", [0] * self.nch)
        self._win[ch] = a

    # ---- the resident expert pool (docs/u200.md 3c): the card addresses 4 GiB a
    # slice, so the top 1 GiB of a channel's space is the *pool window*: a beat there is sent to
    # `win` instead, and a pool is several BOs a channel, each holding whole 1 GiB window pages.
    def alloc_pool(self, pages: int, page: int = 1 << 30, bo: int = 2 << 30,
                   chans=None) -> None:
        """Reserve `pages` window pages a channel, in `bo`-byte buffers of the channel's group.
        A page is what set_window() can point a channel at; pages are pool_page(ch, i).
        `chans`: the channels to give pages (default: all; a resident pool on an S=1 image
        wants 0 and 1 only -- channels 2 and 3 of the kernel top belong to slice 1)."""
        if page % (1 << 30) or bo % page or pages < 0:
            raise ValueError(f"pages {pages} of {page:#x} in {bo:#x}-byte BOs")
        self._pool = dict(getattr(self, "_pool", {}))
        per = bo // page
        for ch in range(self.nch) if chans is None else chans:
            out = self._pool.setdefault(ch, [])
            for k in range(0, pages - len(out), per):
                b = self._lib.otpu_xrt_bo(self._h, bo, self.grp[ch])
                if not b:
                    raise RuntimeError(f"pool BO allocation failed (group {self.grp[ch]})")
                base = self._lib.otpu_xrt_bo_addr(b)
                self.bo.append(b)                 # freed with the rest
                # (BO, the page's AXI base, the page's byte offset inside that BO): a BO
                # holds several pages, so a page's own offset must be added to every access
                out.extend((b, base + i * page, i * page, bo) for i in range(per))

    def pool_bo(self, size: int, chans=None) -> int:
        """One pool BO of `size` bytes on each of `chans`, at the same page index in every
        channel's pool (that index is what pool_write/pool_read take). A pool BO is one page of
        its whole size -- what a resident pool wants, where a "page" is not a 1 GiB window page
        but the bytes a BO holds. 1 GiB multiples (what xrt::bo allocates here)."""
        self._pool = dict(getattr(self, "_pool", {}))
        if size <= 0 or size % (1 << 30):
            raise ValueError(f"a pool BO of {size:#x} bytes (1 GiB multiples)")
        chans = list(range(self.nch)) if chans is None else list(chans)
        i = len(self._pool.setdefault(chans[0], []))
        for ch in chans:
            if len(self._pool.setdefault(ch, [])) != i:
                raise RuntimeError(f"channel {ch} has {len(self._pool[ch])} pool pages, not {i}")
        got = []
        for ch in chans:
            b = self._lib.otpu_xrt_bo(self._h, size, self.grp[ch])
            if not b:
                raise RuntimeError(f"pool BO allocation failed (group {self.grp[ch]})")
            got.append((ch, b, self._lib.otpu_xrt_bo_addr(b)))
        for ch, b, base in got:
            self.bo.append(b)                 # freed with the rest
            self._pool[ch].append((b, base, 0, size))
        return i

    def pool_page(self, ch: int, i: int) -> int:
        """Page i's AXI base (byte address): what set_window() takes."""
        return self._pool[ch][i][1]

    def _pool_bo(self, ch: int, i: int) -> tuple:
        """(the BO holding page i of channel ch, the page's byte offset inside it)."""
        try:
            b, base, off, size = self._pool[ch][i]
        except (AttributeError, KeyError, IndexError) as e:
            raise KeyError(f"channel {ch} page {i} is not allocated") from e
        return b, off

    def pool_write(self, ch: int, i: int, off: int, data: np.ndarray) -> None:
        """Write into page i at its own offset, whatever window the channel currently names."""
        b, po = self._pool_bo(ch, i)
        off += po
        a = np.ascontiguousarray(data, np.uint8).reshape(-1)
        if self._lib.otpu_xrt_bo_write(b, a.ctypes.data, len(a), off) != 0:
            raise RuntimeError("pool BO write failed")
        if self._lib.otpu_xrt_bo_sync_range(b, 1, len(a), off) != 0:
            raise RuntimeError("pool BO sync(to device) failed")

    def pool_read(self, ch: int, i: int, off: int, n: int) -> np.ndarray:
        """n bytes of page i at its own offset, whatever window the channel currently names."""
        b, po = self._pool_bo(ch, i)
        off += po
        buf = np.empty(n, np.uint8)
        if self._lib.otpu_xrt_bo_sync_range(b, 0, n, off) != 0:
            raise RuntimeError("pool BO sync(from device) failed")
        if self._lib.otpu_xrt_bo_read(b, buf.ctypes.data, n, off) != 0:
            raise RuntimeError("pool BO read failed")
        return buf

    def _win_addr(self, ch: int, off: int, n: int) -> tuple:
        """(the BO an access at channel offset off goes to, its byte offset in it): the window's
        page -- a pool BO of the channel's own (`alloc_pool`, `pool_bo`) -- when off is in the
        pool region and a window is set for ch, else the channel's BO."""
        w = (getattr(self, "_win", None) or [0] * self.nch)[ch]
        if w and self.POOL_LO <= off < self.POOL_HI and off + n <= self.POOL_HI:
            a = w + off - self.POOL_LO
            for b, base, po, size in (getattr(self, "_pool", None) or {}).get(ch, []):
                if base - po <= a and a + n <= base - po + size:
                    return b, a - (base - po)
            raise KeyError(f"window {w:#x} + {off - self.POOL_LO:#x} (channel {ch}) is in no "
                           f"pool BO")
        return self.bo[ch], off

    def reg_write(self, off: int, val: int) -> None:
        if not self._h:
            raise RuntimeError("xrt transport is closed")
        self._lib.otpu_xrt_write(self._h, off, val & 0xFFFFFFFF)

    # ---- channel memory (BO-relative logical offsets; the kernel adds the BO base) ----
    def mem_write(self, ch: int, off: int, data: np.ndarray) -> None:
        a = np.ascontiguousarray(data, np.uint8).reshape(-1)
        if len(a) == 0:
            return
        if off % BEAT or len(a) % BEAT:      # widen to whole beats (host-side RMW)
            o0 = off // BEAT * BEAT
            o1 = -(-(off + len(a)) // BEAT) * BEAT
            buf = self.mem_read(ch, o0, o1 - o0)
            buf[off - o0:off - o0 + len(a)] = a
            a, off = buf, o0
        bo, off = self._win_addr(ch, off, len(a))
        if self._lib.otpu_xrt_bo_write(bo, a.ctypes.data, len(a), off) != 0:
            raise RuntimeError("xrt BO write failed")
        if self._lib.otpu_xrt_bo_sync_range(bo, 1, len(a), off) != 0:
            raise RuntimeError("xrt BO sync(to device) failed")

    def mem_read(self, ch: int, off: int, n: int,
                 out: np.ndarray | None = None) -> np.ndarray:
        bo, off = self._win_addr(ch, off, n)
        buf = np.empty(n, np.uint8) if out is None else out
        if self._lib.otpu_xrt_bo_sync_range(bo, 0, n, off) != 0:
            raise RuntimeError("xrt BO sync(from device) failed")
        if self._lib.otpu_xrt_bo_read(bo, buf.ctypes.data, n, off) != 0:
            raise RuntimeError("xrt BO read failed")
        return buf

    def flush(self) -> None:
        pass

    def close(self) -> None:
        if getattr(self, "_h", None):
            self._lib.otpu_xrt_close(self._h)
            self._h = None
        self.bo = []

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass


def _xclbin_bank_groups(xclbin: str, default: int = 1) -> list[int]:
    """The memory bank group of each channel's m_axi argument, from the xclbin's CONNECTIVITY
    (the same value `xrt::kernel::group_id(arg_index)` returns); one per channel, so 2 for S=1
    and 4 for S=2. Falls back to a 2-channel default if the section cannot be read."""
    import json
    import tempfile

    try:
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "conn.json"
            r = subprocess.run(["xclbinutil", "--quiet", "--force", "--dump-section",
                                f"CONNECTIVITY:JSON:{out}", "--input", xclbin],
                               capture_output=True, text=True, timeout=60)
            if r.returncode or not out.exists():
                return [default, default]
            conn = json.loads(out.read_text())["connectivity"]["m_connection"]
            # one entry per m_axi arg (2 for S=1, 4 for S=2); arg_index is the kernel's arg id
            idx = sorted({int(c["arg_index"]) for c in conn})
            grp = [default] * len(idx)
            for c in conn:
                a = int(c["arg_index"])
                if 0 <= a < len(grp):
                    grp[a] = int(c["mem_data_index"])
            return grp if len(grp) in (2, 4) else [default, default]
    except Exception:
        return [default, default]


def _xclbin_clock_khz(xclbin: str) -> int | None:
    """The kernel DATA clock the xclbin actually runs at (Vitis may have auto-scaled the
    requested frequency when timing failed; e.g. 150 -> 101.1 MHz)."""
    try:
        r = subprocess.run(["xclbinutil", "--info", "--input", xclbin],
                           capture_output=True, text=True, timeout=60)
        sec = r.stdout.split("Scalable Clocks", 1)
        if len(sec) == 2:
            m = re.search(r"Frequency:\s*([0-9.]+)\s*MHz", sec[1])
            if m:
                return int(round(float(m.group(1)) * 1000))
    except Exception:
        pass
    return None
