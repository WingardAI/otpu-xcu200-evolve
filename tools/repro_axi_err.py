"""Reproduce the U200 core kernel's AXI_ERR down to one instruction (docs/u200.md
T1.2). The shell has an **AXI firewall**: `RRESP != OKAY` means it blocked a transaction it judged
non-compliant (illegal burst/length, an address outside the port's window, a protocol violation) --
so the useful thing to know is *which* instruction provokes it.

    .venv/bin/python tools/repro_axi_err.py --xclbin boards/u200-vitis/build/OtpuCoreKernel_fp14_133mhz_2ddr.xclbin --bisect

Runs a Qwen prefill chunk by chunk, stops at the failing chunk, rebuilds that chunk's program list,
confirms it fails alone, then bisects the list (prefix by prefix) to the smallest failing prefix and
dumps it. Every attempt needs a **fresh configuration** (loading the same xclbin twice is a no-op in
XRT, and the error sticky otherwise poisons the later runs), so the transport is closed, `--alt` is
loaded and then the target.

fp14 (S = 1, 133 MHz, WNS +0.190) fails this prompt 5/5, always on channel 0 at AR 0x28ba8040: a
deterministic functional failure with the whole timing margin intact.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))


def reload(xclbin: str, alt: str) -> None:
    for x in (alt, xclbin):
        subprocess.run([sys.executable, "-c", f"import pyxrt; pyxrt.device(0).load_xclbin({x!r})"],
                       cwd=ROOT, capture_output=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--xclbin", required=True)
    ap.add_argument("--alt", default="boards/u200-vitis/build/OtpuKernel.xclbin")
    ap.add_argument("--model", default="qwen3")
    ap.add_argument("--reps", type=int, default=51)
    ap.add_argument("--prompt")
    ap.add_argument("--out", default="/tmp/repro_axi_err")
    ap.add_argument("--bisect", action="store_true")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    os.environ["OTPU_XCLBIN"] = a.xclbin

    from transformers import AutoTokenizer
    from opentpu.llm import model_dir, load_spec
    from opentpu.llm.qwen3 import Engine, load_weights
    from opentpu.llm import prefill as PF
    from opentpu.host.board import Board, BoardBackend, device_config, default_transport

    path = model_dir(a.model)
    spec, weights = load_spec(path), load_weights(path)
    tok = AutoTokenizer.from_pretrained(path)
    text = a.prompt or ("The quick brown fox jumps over the lazy dog. " * a.reps)
    t = tok.apply_chat_template([{"role": "user", "content": text}],
                               add_generation_prompt=True, enable_thinking=False, tokenize=True)
    ids = list(t["input_ids"] if hasattr(t, "keys") else t)
    print(f"prompt {len(ids)} tokens, image {Path(a.xclbin).name}", flush=True)

    tr = None

    def open_engine():
        """A fresh configuration + transport + engine (closing the previous transport first)."""
        nonlocal tr
        if tr is not None:
            try:
                tr.close()
            except Exception:                                # noqa: BLE001
                pass
            tr = None
        reload(str(ROOT / a.xclbin), str(ROOT / a.alt))
        tr = default_transport()
        cfg = device_config(Board(tr, lock=False).info())
        return Engine(spec, weights, cap=2048, cfg=cfg,
                      backend=lambda c, imgs: BoardBackend(c, imgs, transport=tr, model=path.name),
                      wformat="int8", head_format="int8", resident=True, prog_cache=True,
                      prompt_runs=True, snapshots=None)

    # ---- phase A: which prefill run fails?
    eng = open_engine()
    n, bad = 0, None
    try:
        for toks, _ in eng.prefill_chunks(ids):
            n += 1
            print(f"  run {n}: {len(toks)} rows at position {eng.poss[0]}", flush=True)
    except Exception as e:                                   # noqa: BLE001
        bad = n + 1
        print(f"\nFAILED in run {bad}: {type(e).__name__}: {e}")
    if bad is None:
        print("no failure on this prompt/image (nothing to reproduce)")
        return 1

    # ---- phase B: that run's programs alone
    eng = open_engine()
    runs = list(PF.split(0, len(ids), lambda b: PF.r_max(eng, b), eng.block, PF.conv_k(eng)))
    p, R, kind = runs[bad - 1]
    entry = PF.programs(eng, p, R, kind if kind else "P")
    progs, names = entry
    print(f"run {bad}: position {p}, {R} rows, kind {kind}, {len(progs)} programs, "
          f"state words {names}")
    (out / "progs.txt").write_text("\n".join(f"{i:4d}  {q}" for i, q in enumerate(progs)))

    eng = open_engine()
    try:
        PF.run(eng, entry, p, R)
        print("the run PASSES alone: the failure needs the earlier runs' state")
        return 2
    except Exception as e:                                   # noqa: BLE001
        print(f"the run FAILS alone: {type(e).__name__}: {e}")

    if not a.bisect:
        return 0
    # ---- phase C: smallest failing prefix
    lo, hi = 0, len(progs)
    while hi - lo > 1:
        mid = (lo + hi) // 2
        eng = open_engine()
        try:
            PF.run(eng, (progs[:mid], names), p, R)
            lo = mid
            print(f"  prefix {mid:4d}: ok", flush=True)
        except Exception:                                    # noqa: BLE001
            hi = mid
            print(f"  prefix {mid:4d}: FAIL", flush=True)
    print(f"\nsmallest failing prefix: {hi} program(s); the one that trips the firewall:")
    print("  " + str(progs[hi - 1]))
    (out / "failing_prog.txt").write_text("\n".join(str(q) for q in progs[:hi]))
    print(f"written to {out / 'failing_prog.txt'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
