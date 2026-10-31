"""Run one prefill twice -- the ISA simulator and the card -- with the resident layout and dump
the whole image DRAM of both, so the first differing byte says *which* buffer a resident run
gets wrong (docs/u200.md).

    python3 tools/offload/resident_diff.py isa            # /tmp/dram-isa.bin
    OTPU_XCLBIN=... python3 tools/offload/resident_diff.py card   # /tmp/dram-card.bin
    python3 tools/offload/resident_diff.py diff

Both runs use the same prompt, configuration, formats and layout, so their image DRAM must be
bit-identical after the same prefill (the pool's own bytes are verified separately).
"""
from __future__ import annotations

import os
import pickle
import sys
from pathlib import Path

import numpy as np

PROMPT = "What is the capital of France? Answer in one sentence."
MODEL = "models/Qwen3.5-35B-A3B"
POOL = "models/Qwen3.5-35B-A3B/pool-mx1-fp4.bin"
CFG = "/tmp/cfg-fp24.pkl"
CHUNK = 64 << 20


def prompt_ids() -> list:
    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(MODEL)
    t = tok.apply_chat_template([{"role": "user", "content": PROMPT}],
                                add_generation_prompt=True, tokenize=True)
    return list(t["input_ids"] if hasattr(t, "keys") else t)


def build(mode: str):
    from opentpu.host import streamed as ST
    cfg = pickle.loads(Path(CFG).read_bytes())
    backend = "isa"
    tr = None
    if mode == "card":
        from opentpu.host.board import BoardBackend, default_transport
        tr = default_transport()
        print(f"card: {type(tr).__name__}", flush=True)

        def backend(c, imgs):                       # noqa: F811
            return BoardBackend(c, imgs, transport=tr, model=Path(MODEL).name)
    experts = int(os.environ.get("OTPU_DIFF_EXPERTS", 256))
    if tr is not None and os.environ.get("OTPU_RESIDENT"):
        # The pool before the image (moe_card does the same): the build's page cache plus the
        # pool's 18 GiB of BOs is more than the host has, and the reclaim sets the desktop's
        # systemd-oomd on the session (docs/u200.md).
        from opentpu.llm import load_spec
        from opentpu.llm import moe as MO
        MO.preallocate(tr, load_spec(MODEL), cfg, "fp4", pool_file=POOL,
                       log=lambda m: print(f"  {m}", flush=True))
    eng = ST.engine(MODEL, cfg, backend, 4096, POOL, experts=experts, wformat="fp4",
                    head_format="int8", embed_host=True, hints=False, layer_major=1,
                    pooled=False, expert_major=False)
    return eng, tr


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    mode = argv[0]
    if mode == "diff":
        tag = os.environ.get("OTPU_DIFF_TAG", "res")
        a = np.fromfile(f"/tmp/dram-isa-{tag}.bin", np.uint8)
        b = np.fromfile(f"/tmp/dram-card-{tag}.bin", np.uint8)
        n = min(len(a), len(b))
        d = np.flatnonzero(a[:n] != b[:n])
        print(f"isa {len(a) / 2**20:.1f} MiB, card {len(b) / 2**20:.1f} MiB, "
              f"{len(d)} bytes differ")
        if len(d):
            print(f"first at {int(d[0]):#x} (isa {int(a[d[0]]):#x} card {int(b[d[0]]):#x}), "
                  f"last at {int(d[-1]):#x}")
            lo = int(d[0]) // 4096 * 4096
            print(f"  region {lo:#x}..{lo + 4096:#x}:")
            for k in range(0, 64, 16):
                print(f"    isa  {int(lo) + k:#x}: {a[lo + k:lo + k + 16].tobytes().hex()}")
                print(f"    card {int(lo) + k:#x}: {b[lo + k:lo + k + 16].tobytes().hex()}")
        return 0

    if os.environ.get("OTPU_DIFF_RESIDENT", "1") == "1":
        os.environ["OTPU_RESIDENT"] = "1"
    tag = os.environ.get("OTPU_DIFF_TAG", "res" if os.environ.get("OTPU_RESIDENT") else "str")
    ids = prompt_ids()
    print(f"{mode}: {len(ids)} prompt tokens", flush=True)
    eng, tr = build(mode)
    print(f"{mode}: engine up, image {eng.image.nbytes / 2**20:.1f} MiB", flush=True)
    if os.environ.get("OTPU_DIFF_BEFORE"):      # (the image as written, before any run)
        n = eng.image.nbytes
        out = Path(f"/tmp/dram-{mode}-{tag}-before.bin")
        if mode == "isa":
            out.write_bytes(eng.backend.machine.slices[0].dram[:n].tobytes())
        else:
            board = eng.backend.board
            with out.open("wb") as f:
                for off in range(0, n, CHUNK):
                    f.write(np.asarray(board.read(off, min(CHUNK, n - off)),
                                       np.uint8).tobytes())
        print(f"{mode}: wrote the image before any run ({n / 2**20:.1f} MiB)", flush=True)
        return 0
    per = os.environ.get("OTPU_DIFF_PERLAYER")
    if per:
        # Layer-major: one run a row, so every (tokens - 1) runs close a layer. Dump a 2 MiB
        # window (the first differing clusters of the whole-image diff) after each layer, and stop
        # once the first layers are known: the first layer whose bytes differ is the culprit's.
        rows = len(ids) - 1
        stop = int(os.environ.get("OTPU_DIFF_STOP", 3))
        win = int(os.environ.get("OTPU_DIFF_WINDOW", 0x200000))
        state = {"k": 0}
        # the card runs start()+wait() (a run is a wait), the simulator run() alone
        hook_name = "wait" if hasattr(eng.backend, "wait") else "run"
        orig = getattr(eng.backend, hook_name)
        board = getattr(eng.backend, "board", None)
        dram = getattr(getattr(eng.backend, "machine", None), "slices", [None])[0]

        def read(off, n):
            if dram is not None:
                return np.asarray(dram.dram[off:off + n], np.uint8)
            return np.asarray(board.read(off, n), np.uint8)

        def run(*a, **kw):
            st = orig(*a, **kw)
            state["k"] += 1
            if state["k"] % rows == 0:
                j = state["k"] // rows - 1
                Path(f"/tmp/pl-{mode}-{j}.bin").write_bytes(read(0, win).tobytes())
                print(f"{mode}: layer {j} dumped ({state['k']} runs)", flush=True)
                if j >= stop:
                    raise SystemExit(0)
            return st
        setattr(eng.backend, hook_name, run)
        print(f"{mode}: per-layer dumps through {hook_name}(), {rows} runs a layer", flush=True)
    eng.prefill(ids[:-1])
    print(f"{mode}: prefill done", flush=True)
    n = eng.image.nbytes
    out = Path(f"/tmp/dram-{mode}-{tag}.bin")
    if mode == "isa":
        dram = eng.backend.machine.slices[0].dram
        out.write_bytes(dram[:n].tobytes())
    else:
        board = eng.backend.board
        with out.open("wb") as f:
            for off in range(0, n, CHUNK):
                k = min(CHUNK, n - off)
                f.write(np.asarray(board.read(off, k), np.uint8).tobytes())
    print(f"{mode}: wrote {n / 2**20:.1f} MiB to {out}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
