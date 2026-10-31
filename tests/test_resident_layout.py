"""The resident layout (docs/u200.md): every layer's slots at the same address,
the window each layer's page is reached through, and the fill that puts the experts there.

`FakePool` is the card's side at the level the fill and the window move use: a BO gets a device
address in its channel's bank (a bump allocator after the channel's own BO), and a read in the
pool region goes to the window's page -- `beat_at`'s channel split and the window's `win +
(offset - POOL_LO)` as rtl/mem/otpu_axi_dram.sv does it, so a wrong page, a wrong offset or a
wrong split shows up as different bytes.
"""
from collections import OrderedDict
from types import SimpleNamespace

import numpy as np
import pytest

from opentpu.host.board import beat_at, join, split
from opentpu.host.offload import POOL0, Layout, ResidentPool
from opentpu.host.xrt import XrtTransport

E, K, SLOT = 8, 2, 256          # a small pool: 8 experts a layer of 256-byte slots


class FakePool:
    """XrtTransport's pool API over host arrays, with the card's window semantics."""

    POOL_LO, POOL_HI = 0x4000_0000, 0x8000_0000
    nch = 2

    def __init__(self, base: int = 0x4000_0000_00, stride: int = 0x10_0000_0000,
                 ch_bytes: int = 2 << 30):
        self.bases = [base + c * stride for c in range(self.nch)]
        self.next = [b + ch_bytes for b in self.bases]      # after the channel's own BO
        self._pool: dict = {}
        self._win = [0] * self.nch
        self.bo: list = []
        self.writes = 0

    # ---- XrtTransport's pool API
    def alloc_pool(self, pages: int, page: int, bo: int, chans=None) -> None:
        assert page % 4096 == 0 and bo % page == 0
        for ch in (range(self.nch) if chans is None else chans):
            out = self._pool.setdefault(ch, [])
            for _ in range(0, pages - len(out), bo // page):
                buf = np.zeros(bo, np.uint8)
                self.bo.append(buf)
                out.extend((buf, self.next[ch] + i * page, i * page)
                           for i in range(bo // page))
                self.next[ch] += bo

    def pool_bo(self, size: int, chans=None) -> int:
        assert size % 4096 == 0
        chans = list(range(self.nch)) if chans is None else list(chans)
        i = len(self._pool.setdefault(chans[0], []))
        for ch in chans:
            assert len(self._pool.setdefault(ch, [])) == i
            self._pool[ch].append((np.zeros(size, np.uint8), self.next[ch], 0))
            self.bo.append(self._pool[ch][-1][0])
            self.next[ch] += size
        return i

    def pool_page(self, ch: int, i: int) -> int:
        return self._pool[ch][i][1]

    def pool_write(self, ch: int, i: int, off: int, data: np.ndarray) -> None:
        buf, _, po = self._pool[ch][i]
        buf[po + off:po + off + len(data)] = data
        self.writes += 1

    def pool_read(self, ch: int, i: int, off: int, n: int) -> np.ndarray:
        buf, _, po = self._pool[ch][i]
        return buf[po + off:po + off + n].copy()

    def set_window(self, ch: int, off: int) -> None:
        assert off % 4096 == 0, f"window {off:#x} is not 4 KiB aligned"
        self._win[ch] = off

    # ---- the card's read: a pool-region offset under the window
    def mem_read(self, ch: int, off: int, n: int) -> np.ndarray:
        w = self._win[ch]
        if not w or not self.POOL_LO <= off < self.POOL_HI:
            raise KeyError(f"channel {ch} offset {off:#x}: not in the window ({w:#x})")
        a = w + off - self.POOL_LO
        for buf, base, po in self._pool[ch]:
            if base <= a and a + n <= base + len(buf):
                return buf[po + a - base:po + a - base + n].copy()
        raise KeyError(f"channel {ch} address {a:#x}: outside every BO")


def _pool(g: int) -> bytes:
    """A record that says which expert it is, everywhere in it."""
    return (np.arange(SLOT // 4, dtype=np.uint32) * np.uint32(g + 1)).astype(np.uint32).tobytes()


def test_resident_geometry():
    lay = Layout.resident(0x1000_0000, E, K, 5, SLOT)
    assert lay.windowed and lay.layers == 5 and lay.slot_bounds[0] == POOL0
    assert {a for a, _ in lay.slots} == {POOL0}             # every layer, one address
    assert all(n == E for _, n in lay.slots)
    assert lay.slot_bounds == (POOL0, POOL0 + (E - 1) * lay.pitch)
    assert lay.layer_channel == -(-(E * lay.pitch // 2) // 4096) * 4096
    assert lay.layer_channel % 4096 == 0                    # a window may point at it
    assert lay.dir > lay.answer > lay.served > lay.mbox     # the words below the pool
    assert lay.end < POOL0                                  # the pool is not image DRAM
    with pytest.raises(ValueError):                         # the words would enter the pool
        Layout.resident(POOL0 - 4096, E, K, 1000, SLOT)
    with pytest.raises(ValueError):                         # no room for the words at all
        Layout.resident(POOL0 - 2 * 64, E, K, 5, SLOT)


def test_pool_plan_pages_fit_the_layers():
    """2 layers a page: 5 layers take 3 pages."""
    lc = Layout.resident(0x1000_0000, E, K, 5, SLOT).layer_channel
    pool = ResidentPool(Layout.resident(0x1000_0000, E, K, 5, SLOT), FakePool(), bo=2 * lc)
    assert pool.pages == 3
    assert [n for n in pool.page_layer] == [2, 2, 1]
    assert pool.layer_at == [(0, 0), (0, lc), (1, 0), (1, lc), (2, 0)]
    for j in range(5):                                      # a window points inside its BO
        for ch in (0, 1):
            w = pool.window(ch, j)
            i, off = pool.layer_at[j]
            assert w == pool.t.pool_page(ch, i) + off
            assert w % 4096 == 0


def test_plan_sizes_of_the_35b_pool():
    """The real Qwen3.5-35B-A3B pool (fp4, 40 layers x 256 experts of 1,712,192 B): 9 GiB a
    channel in 2 GiB BOs, 91% of those bytes holding experts -- 18 GiB both channels, which fits
    the two 16 GiB banks beside the image."""
    lay = Layout.resident(0x1000_0000, 256, 8, 40, 1712192)
    plan = ResidentPool.plan_sizes(lay, 2 << 30)
    assert [n for _, n in plan] == [9, 9, 9, 9, 4]
    assert [s for s, _ in plan] == [2 << 30] * 4 + [1 << 30]
    assert sum(s for s, _ in plan) == 9 << 30
    assert 40 * lay.layer_channel / (9 << 30) > 0.90
    assert 9 * (1 << 30) + (2 << 30) < 16 << 30            # a 16 GiB bank with the image's BO
    # a slot too big for any of it
    with pytest.raises(ValueError):
        ResidentPool.plan_sizes(Layout.resident(0x1000_0000, 256, 8, 40, 1 << 24), 2 << 30)


def test_pool_fill_and_the_windows_carry_every_expert():
    """fill writes each expert into its layer's page; under layer j's window the card reads
    that layer's record back at the same slot address -- the whole mechanism but the register."""
    tr = FakePool()
    lay = Layout.resident(0x1000_0000, E, K, 3, SLOT)
    pool = ResidentPool(lay, tr, bo=2 * 4096)               # (two layers a page)
    assert pool.pages == 2 and pool.page_layer == [2, 1]
    assert pool.fill(_pool) == 3 * lay.layer_bytes          # a run a channel a layer
    assert pool.check(_pool, experts=[(j, e) for j in range(3) for e in (0, E - 1)]) == 6
    # every slot address is the same for every layer; what differs is the page behind it
    seen = []
    for j in range(3):
        pool.set_layer(j)
        ch, off = beat_at(POOL0, chash=True)
        want = _pool(j * E + 0)
        got = join([tr.mem_read(c, POOL0 // 2, SLOT // 2) for c in (0, 1)], POOL0, chash=True)
        assert got.tobytes() == want, f"layer {j} expert 0"
        seen.append(tr._win[0])
    assert len(set(seen)) == 3                              # three different pages
    assert seen == sorted(seen)                             # in the layout's order


def test_pool_directory_is_all_present():
    lay = Layout.resident(0x1000_0000, E, K, 3, SLOT)
    d = ResidentPool(lay, FakePool(), bo=4 * 4096).directory()
    assert d.shape == (3 * E, 2)
    assert (d[:, 1] == np.float32(1.0).view(np.uint32)).all()
    want = lay.slots[0][0] + np.arange(E) * lay.pitch
    for j in range(3):                                      # every layer: the same slot
        assert (d[j * E:(j + 1) * E, 0] == want).all()


def test_fill_writes_the_layer_as_one_run_a_channel():
    """fill hands a channel one contiguous run a layer (the split of the layer's span), so a
    slot's beats land where the card's windows put them: the runs join back to every record,
    with and without the channel hash."""
    for chash in (False, True):
        tr = FakePool()
        lay = Layout.resident(0x1000_0000, E, K, 2, SLOT)
        pool = ResidentPool(lay, tr, bo=4 << 30, chash=chash)
        pool.fill(lambda g: _pool(g))
        assert tr.writes == 2 * lay.layers                  # a run a channel a layer
        span = [p for _, _, p in split(POOL0, np.zeros(lay.layer_bytes, np.uint8), chash)]
        assert [len(p) for p in span] == [lay.layer_bytes // 2] * 2
        for j in (0, 1):
            pool.set_layer(j)
            for e in (0, 3, E - 1):
                addr = POOL0 + e * lay.pitch
                parts = [np.frombuffer(bytes(tr.mem_read(ch, POOL0 // 2 + off, n)), np.uint8)
                         for ch, off, n in pool.offsets(e)]
                joined = join(parts, addr, chash)
                assert joined[:lay.slot_bytes].tobytes() == _pool(j * E + e)


def test_the_window_register_is_4k_aligned_not_1gib():
    """A layer's window is not a whole GiB (it is a multiple of 4 KiB), which is what the
    hardware needs: a coalesced burst stays inside one 4 KiB page."""
    class Stub(XrtTransport):
        def __init__(self):
            self.nch, self.bases = 2, [0x4000_0000_00, 0x5000_0000_00]
            self._win, self.regs = [0, 0], {}

        def reg_write(self, off: int, val: int) -> None:
            self.regs[off] = val & 0xFFFFFFFF

    t = Stub()
    t.set_window(1, 0x5000_C01000)                          # 4 KiB aligned: taken
    assert t.regs[0x328] == 0xC01000 and t.regs[0x32C] == 0x50
    with pytest.raises(ValueError):
        t.set_window(0, 0x4000_000800)                      # 2 KiB off: refused
    t.set_window(0, 0)                                      # no window
    assert t.regs[0x320] == 0 and t.regs[0x324] == 0


def test_split_matches_split_and_the_offsets_are_in_the_layer():
    lay = Layout.resident(0x1000_0000, E, K, 2, SLOT)
    pool = ResidentPool(lay, FakePool(), bo=4 << 30)
    for e in range(E):
        runs = pool.offsets(e)
        assert sum(n for _, _, n in runs) == lay.pitch
        assert [ch for ch, _, _ in runs] == [0, 1]
        assert runs[0][1] == runs[1][1] == beat_at(POOL0 + e * lay.pitch)[1] - POOL0 // 2
        assert 0 <= runs[0][1] and runs[0][1] + runs[0][2] <= lay.layer_channel
    assert len({pool.offsets(e)[0][1] for e in range(E)}) == E     # one run a slot a channel
    assert split(POOL0, np.zeros(SLOT, np.uint8), False)[0][1] == POOL0 // 2


def test_serve_points_the_window_at_its_own_layer():
    """The card reads a request's slots *after* it posts the request, and the poll thread's
    serve() runs concurrently with those reads, so the window must name the request's own layer
    (and `served`, written after the call, is the fence the card reads before the slots --
    moe_ffn's window fence). A lead of one layer moved the window out from under the reads
    (docs/u200.md, tools/offload/window_race.py)."""
    from opentpu.host.offload import ExpertServer, Layout

    L = Layout.resident(0x1000_0000, 4, 2, 3, 128 * 37)
    mem = SimpleNamespace(written=[], write=lambda a, b: mem.written.append((a, bytes(b))),
                          read=lambda a, n: bytes(n), flush=lambda: None)
    srv = ExpertServer(mem, L, lambda g: b"\0" * L.slot_bytes)
    seen = []

    class Win:
        """A ResidentPool's one side effect: the window register (set_layer) -- and the layer
        the card would then read."""
        def set_layer(self, j):
            seen.append(j)

    srv.resident = Win()
    for j in range(L.layers):
        srv.lru[j] = OrderedDict((j * L.E + e, L.slots[0][0] + e * L.pitch)
                                 for e in range(L.E))
        srv.free[j] = []
        srv.serve([j * L.E + 1, j * L.E + 3])
    assert seen == list(range(L.layers)), seen
