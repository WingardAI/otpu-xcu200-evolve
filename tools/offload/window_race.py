"""Card gate, ~1 s, no model and no fill: is the window register read at every beat?

The smallest question the resident layout can ask the card: is the window's value read
*when each beat is fetched*, or once when the run starts?  Fill layer 0's slot 0 with a pattern,
layer 1's with another, start a program that reads 64 x 4 KiB from the pool and stores each block
to its own DRAM address, and move the window to layer 1 after a delay -- then see which layer
each block came from.

Why this exists (docs/u200.md): the resident layout moves a channel's window per
layer from the host, and the card's DMA takes the register **as each beat is fetched**, so a
window written while a run is in flight lands in the middle of that run's reads. A run's reads
must therefore be fenced on a `served` mark written *after* the window (`moe_ffn`'s window fence);
this tool is the on-card check that the semantics are as assumed -- the ISA simulator cannot see
it, because there the host is called synchronously at a WAITW, never concurrently with a DMA.

    python3 tools/offload/window_race.py      # 5 delays, one second the lot
"""
import os, time, sys
import numpy as np
from opentpu import isa as I
from opentpu.host.xrt import XrtTransport
from opentpu.host.board import Board, split
from opentpu.host.offload import Layout, ResidentPool

L = Layout.resident(0x1000_0000, 256, 8, 40, 1712128)
t = XrtTransport(os.environ["OTPU_XCLBIN"])
b = Board(t, check=False)
pool = ResidentPool(L, t, bo=2 << 30)
SRC = 0x3C0000
OUT = 0x100000
N = 1024                                   # words a block (4 KiB)
BLOCKS = 64
pat = {j: np.frombuffer(bytes([0x11 * (j + 1)]) * (BLOCKS * N * 4), np.uint8).copy()
       for j in (0, 1)}
pat[0] = (np.arange(BLOCKS * N * 4, dtype=np.uint32) % 251).astype(np.uint8).tobytes()
pat[1] = (np.arange(BLOCKS * N * 4, dtype=np.uint32) % 241 + 3).astype(np.uint8).tobytes()
pat[0] = np.frombuffer(pat[0], np.uint8)
pat[1] = np.frombuffer(pat[1], np.uint8)

def fill(j):
    i, off = pool.layer_at[j]
    buf = np.zeros(L.pitch, np.uint8)
    buf[:BLOCKS * N * 4] = pat[j][:BLOCKS * N * 4]
    for ch, coff, part in split(L.slots[0][0], buf, pool.chash):
        t.pool_write(ch, i, off + coff - L.slots[0][0] // 2, part)
for j in (0, 1):
    fill(j)
print(f"filled layers 0/1 slot 0 ({BLOCKS * N * 4} B each)", flush=True)

prog = []
for k in range(BLOCKS):
    prog += [I.ld(L.slots[0][0] + k * N * 4, 0, N), I.st(OUT + k * N * 4, 0, N)]
prog.append(I.halt())

for delay in (0.0, 10e-6, 100e-6, 1e-3, 10e-3):
    pool.set_layer(0)
    b.load(SRC, prog)
    b.start()
    if delay:
        time.sleep(delay)
    pool.set_layer(1)                      # what serve() does one request later
    b.wait()
    got = np.asarray(b.read(OUT, BLOCKS * N * 4), np.uint8)
    layers = []
    for k in range(BLOCKS):
        blk = got[k * N * 4:(k + 1) * N * 4]
        if blk.tobytes() == pat[0][k * N * 4:(k + 1) * N * 4].tobytes():
            layers.append(0)
        elif blk.tobytes() == pat[1][k * N * 4:(k + 1) * N * 4].tobytes():
            layers.append(1)
        else:
            layers.append(-1)
    run0 = layers[0] if layers[0] >= 0 else None
    n0, n1, bad = layers.count(0), layers.count(1), layers.count(-1)
    first1 = layers.index(1) if 1 in layers else None
    print(f"  delay {delay * 1e6:8.1f} us: layer0 {n0:3d} layer1 {n1:3d} mixed/bad {bad:3d}"
          f"  first layer-1 block {first1}", flush=True)
t.close()
