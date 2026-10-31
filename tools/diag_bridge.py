"""Read a core kernel's bridge diagnostics (otpu_ctrl 0x028..0x02F) and optionally run a Qwen
prompt to provoke the failure first.

    python3 tools/diag_bridge.py --xclbin X.xclbin [--prompt TEXT --tokens N]

0x028  per channel {cause, err} (4 bits a channel, channels 0..3) + the mem_ch's sticky bits
        cause: 1 = R beat with no tag, 2 = RLAST mismatch, 3 = RRESP != OK, 4 = BRESP != OK
0x029/0x02A  the AR / AW address the FIRST failing channel had last issued (low 32 bits)
0x02B  which channel failed first (bits 1:0) and its sticky bit (bit 2)
0x02C  the kernel cycle count at that first failure
0x02D/0x02E  queue state of channels 0/1 (outstanding, cmd_count, wd0, wd1, read beat, w_state)
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

CODES = {0: "none", 1: "R beat with no tag", 2: "RLAST mismatch", 3: "RRESP != OKAY",
         4: "BRESP != OKAY"}


def show(t, label: str) -> None:
    # otpu_ctrl decodes WORD addresses (r_a[11:2]): the eight dbg words are the case labels
    # 10'h028..10'h02F, i.e. BYTE offsets 0x0A0..0x0BC
    w = [t.reg_read(0x0A0 + 4 * i) for i in range(8)]
    st = t.reg_read(0x00C)                 # STATUS (regs.py: 0x0C, word aligned)
    ST = {0: "halted", 1: "error", 2: "loading", 3: "wr_idle", 4: "axi_err", 5: "calib0",
          6: "calib1", 7: "run", 8: "wait_to", 9: "ecc_ded"}
    print(f"--- {label}")
    print(f"  STATUS 0x00C = {st:#010x}  " + " ".join(f"{n}={1 if (st >> b) & 1 else 0}"
                                              for b, n in ST.items()))
    print("  raw dbg 0x0A0..0x0BC: " + " ".join(f"{x:08x}" for x in w))
    ch_err = (w[0] >> 16) & 0xF
    for c in range(4):
        nib = (w[0] >> (4 * c)) & 0xF
        err, code = nib & 1, (nib >> 1) & 7
        print(f"  ch{c}: err={err} cause={code} ({CODES.get(code, '?')})"
              f"  mem_ch sticky={1 if (ch_err >> c) & 1 else 0}")
    which, valid = w[3] & 3, (w[3] >> 2) & 1
    print(f"  first failure: {'ch%d' % which if valid else 'none'}"
          f"  AR@={w[1]:08x}  AW@={w[2]:08x}  cycle={w[4]}")
    for c in (0, 1):
        q = w[5 + c]
        print(f"  ch{c} queue: outstanding={(q >> 24) & 0xFF} cmd_count={(q >> 18) & 0x3F}"
              f" wd0={(q >> 12) & 0x3F} wd1={(q >> 6) & 0x3F} rd_beat={(q >> 4) & 0x3}"
              f" w_state={(q >> 3) & 1}")
    print(f"  legacy err_cycle: {w[7]}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--xclbin", required=True)
    ap.add_argument("--prompt", help="run this prompt first (a Qwen3 model) to provoke a failure")
    ap.add_argument("--tokens", type=int, default=8)
    ap.add_argument("--model", default="qwen3")
    a = ap.parse_args()

    if a.prompt:
        import opentpu.host.board as B
        import opentpu.host.chat as C
        cap = {}
        orig_dt = B.default_transport

        def dt(*aa, **kw):
            tr = orig_dt(*aa, **kw)
            cap["t"] = tr
            return tr

        B.default_transport = dt
        try:
            C.main(["--model", a.model, "--backend", "board", "--greedy",
                    "--max-new", str(a.tokens), "--plain", "--prompt", a.prompt])
        except Exception as e:                       # noqa: BLE001 - report, then read the regs
            print(f"\nrun failed: {type(e).__name__}: {e}")
        finally:
            B.default_transport = orig_dt
        if "t" in cap:
            show(cap["t"], "after the run")
        else:
            print("note: no transport captured (the run failed before the backend was built)")
            return 1
    else:                                       # just read the registers
        from opentpu.host.xrt import XrtTransport
        t = XrtTransport(a.xclbin)
        show(t, "after open")
    t = locals().get("t")
    if t is not None:
        t.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
