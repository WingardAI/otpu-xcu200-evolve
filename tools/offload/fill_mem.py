# New in the XCU200 port (WingardAI, 2026) for openTPU,
# https://github.com/FeSens/openTPU (Apache-2.0). See NOTICE.

"""Off-card/card accounting probe for the resident fill: the pool's BOs and the fill, with the
cgroup's own memory.stat and PSI sampled beside it (docs/u200.md).

    OTPU_CH_GIB=2 OTPU_XRT_BO_GROUPS=0,1 python3 tools/offload/fill_mem.py [--layers N]

Prints one line every 2 s: the user slice's anon / file / kernel bytes, its swap, MemAvailable
and the memory PSI, so that a run the desktop's systemd-oomd kills can be read afterwards.
"""
from __future__ import annotations

import argparse
import os
import sys
import threading
import time

import numpy as np

HERE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CG = "/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service"


def stat() -> dict:
    out = {}
    try:
        with open(f"{CG}/memory.stat") as f:
            for line in f:
                k, _, v = line.partition(" ")
                if k in ("anon", "file", "kernel", "slab", "swapcached", "pagetables"):
                    out[k] = int(v) / 2**30
        for k, name in (("memory.current", "cur"), ("memory.swap.current", "swap"),
                        ("memory.peak", "peak")):
            with open(f"{CG}/{k}") as f:
                out[name] = int(f.read()) / 2**30
        with open(f"{CG}/memory.pressure") as f:
            for part in f.readline().split():
                if part.startswith("avg60="):
                    out["psi60"] = float(part[6:])
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    out["avail"] = int(line.split()[1]) / 2**20
    except OSError:
        pass
    return out


def watch(stop: threading.Event, every: float = 2.0) -> None:
    while not stop.wait(every):
        s = stat()
        print(f"  [{time.strftime('%H:%M:%S')}] anon {s.get('anon', 0):5.1f} "
              f"file {s.get('file', 0):5.1f} kern {s.get('kernel', 0):4.1f} "
              f"cur {s.get('cur', 0):5.1f} swap {s.get('swap', 0):5.1f} "
              f"peak {s.get('peak', 0):5.1f} avail {s.get('avail', 0):4.0f} "
              f"psi60 {s.get('psi60', 0):5.1f}%", flush=True)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--layers", type=int, default=40)
    ap.add_argument("--bo", type=int, default=2 << 30)
    ap.add_argument("--slot", type=int, default=1712128)
    ap.add_argument("--pool", default="models/Qwen3.5-35B-A3B/pool-mx1-fp4.bin")
    a = ap.parse_args(argv)
    sys.path.insert(0, HERE)
    from opentpu.host.offload import DirectPoolFile, Layout, ResidentPool
    from opentpu.host.xrt import XrtTransport

    stop = threading.Event()
    th = threading.Thread(target=watch, args=(stop,), daemon=True)
    th.start()
    print("opening the transport (channel BOs + scrub)", flush=True)
    t = XrtTransport("boards/u200-vitis/build/OtpuCoreKernel_fp24_189mhz_window.xclbin")
    lay = Layout.resident(0x1000_0000, 256, 8, a.layers, a.slot)
    print(f"allocating the pool: {ResidentPool.plan_sizes(lay, a.bo)}", flush=True)
    pool = ResidentPool(lay, t, bo=a.bo)
    print(f"pool up: {pool.pages} BOs a channel, {pool.bytes * 2 / 2**30:.1f} GiB both", flush=True)
    d = DirectPoolFile(a.pool, a.slot, True)
    t0 = time.time()
    n = pool.fill(d.get, every=2, log=lambda m: print(f"{m}  [{time.time() - t0:.0f}s]",
                                                      flush=True))
    print(f"filled {n / 1e9:.2f} GB in {time.time() - t0:.0f}s", flush=True)
    stop.set()
    th.join(2)
    t.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
