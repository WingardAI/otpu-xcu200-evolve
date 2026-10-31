"""Kernel-top bandwidth regression: OtpuKernel + AXI memory model.

Replays the host AXI-Lite register sequence (soft reset, base, mode, write/read, n, start,
ctrl) through the real kernel, with AXI4 protocol checks. This is the system-level layer the
bridge unit tests miss: kernel port widths, control mux, reset, and the generator's
command/write-data handshakes. It also prints the bridge diagnostic registers on failure.
"""
import re
import shutil
import subprocess

import pytest

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_kernel_bandwidth(tmp_path):
    iverilog = shutil.which("iverilog")
    vvp = shutil.which("vvp")
    if not iverilog or not vvp:
        pytest.skip("iverilog/vvp not installed")
    exe = tmp_path / "tb_kernel_bw"
    cmd = [iverilog, "-g2012", "-o", str(exe),
           "sim/verilator/tb_kernel_bw.sv",
           "sim/verilator/axi_mem_model.sv",
           "rtl/mem/otpu_axi_dram.sv",
           "rtl/boards/u200-vitis/otpu_u200_kernel.sv",
           "rtl/shell/otpu_ctrl.sv"]
    subprocess.run(cmd, cwd=ROOT, check=True, capture_output=True, text=True)
    r = subprocess.run([vvp, str(exe)], cwd=ROOT, capture_output=True, text=True,
                       timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "PASS: kernel-top bandwidth TB" in r.stdout, r.stdout + r.stderr
    assert "FAIL" not in r.stdout, r.stdout + r.stderr
    # both modes must complete the expected number of beats
    assert re.search(r"write:.*beats=4096", r.stdout), r.stdout + r.stderr
    assert re.search(r"read:.*beats=4096", r.stdout), r.stdout + r.stderr
