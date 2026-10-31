"""Sample the U200's power and temperatures: a table on the terminal, a peak record at the end
(the card is passively cooled, so the peak -- not the reading at the end of a run -- is what
matters), or run a command between the two samples.

    .venv/bin/python tools/power_monitor.py [--interval 1] [--seconds 600] [--run 'cmd ...']
    .venv/bin/python tools/power_monitor.py --run "tools/stress_2bank.py --xclbin X --runs 4"

Sensors (hwmon): temp1/2 PCB top, temp3 PCB bottom, temp4 = FPGA junction, temp6..9 the DIMMs,
power1 = card power (uW), curr3 = VCCINT (mA). Tj(max) of the xcu200-fsgd2104-2-e is 100 °C; the
report ends with the peak values and, for a run, the peak minus the before-run baseline."""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

HWMON = Path("/sys/bus/pci/devices/0000:01:00.0/hwmon")
SENSORS = {"tj": ("temp4_input", 1e3), "pcb_front": ("temp1_input", 1e3),
           "pcb_rear": ("temp2_input", 1e3), "pcb_bottom": ("temp3_input", 1e3),
           "dimm0": ("temp6_input", 1e3), "power": ("power1_input", 1e6),
           "vccint": ("curr3_input", 1e3)}


def read() -> dict[str, float]:
    d = next(iter(sorted(HWMON.glob("hwmon*"))), None)
    out: dict[str, float] = {}
    if d is None:
        return out
    for k, (f, scale) in SENSORS.items():
        try:
            out[k] = int((d / f).read_text()) / scale
        except (OSError, ValueError):
            out[k] = float("nan")
    return out


def fmt(s: dict[str, float]) -> str:
    return (f"Tj {s.get('tj', 0):4.0f}C  PCB {s.get('pcb_front', 0):3.0f}C  "
            f"power {s.get('power', 0):5.1f}W  VCCINT {s.get('vccint', 0):5.2f}A")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--seconds", type=float, default=0, help="0: until Ctrl-C (or the command ends)")
    ap.add_argument("--run", default=None, help="a command to run between the samples")
    a = ap.parse_args()

    peak: dict[str, float] = {}
    base = read()
    print(f"start  {fmt(base)}")
    proc = None
    if a.run:
        print(f"run: {a.run}")
        proc = subprocess.Popen(a.run, shell=True)
    t0 = time.time()
    try:
        while True:
            s = read()
            for k, v in s.items():
                if v == v:                                  # (not NaN)
                    peak[k] = max(peak.get(k, -1e9), v)
            rc = proc.poll() if proc else None
            if int(time.time() - t0) % 15 < a.interval:     # a line every ~15 s, and always one now
                print(f"  {time.time() - t0:6.0f}s  {fmt(s)}"
                      + ("" if rc is None else f"  (command exit {rc})"), flush=True)
            if proc is not None and rc is not None:
                break
            if a.seconds and time.time() - t0 >= a.seconds:
                break
            time.sleep(a.interval)
    except KeyboardInterrupt:
        pass
    finally:
        if proc is not None and proc.poll() is None:
            proc.terminate()
    end = read()
    print(f"end    {fmt(end)}")
    print(f"PEAK   Tj {peak.get('tj', 0):4.0f}C (was {base.get('tj', 0):4.0f}C, "
          f"+{peak.get('tj', 0) - base.get('tj', 0):3.0f})  PCB {peak.get('pcb_front', 0):3.0f}C  "
          f"power {peak.get('power', 0):5.1f}W  VCCINT {peak.get('vccint', 0):5.2f}A  "
          f"DIMM max {max((peak.get(f'dimm{i}', 0) for i in range(4)), default=0):3.0f}C")
    if peak.get("tj", 0) >= 95:
        print(f"!! the die reached {peak['tj']:.0f} C: the limit is 100 C and the timing margin "
              f"of these builds is ~20 ps -- see docs/u200.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
