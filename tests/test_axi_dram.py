"""otpu_axi_dram (the U200 native-port -> AXI4 bridge): unit and otpu_mem_ch integration tests.

The testbenches are small self-checking SV programs run with iverilog/vvp (no Verilator model
needed): the bridge alone against an AXI memory model, and the bridge behind the real
otpu_mem_ch (both bank-parity ports, partial-write read-modify-write, n_wdone, n_err).
"""
import shutil
import subprocess

import pytest

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _run_iverilog(tmp_path: Path, name: str, tb: str, sources: list[str]) -> None:
    iverilog = shutil.which("iverilog")
    vvp = shutil.which("vvp")
    if not iverilog or not vvp:
        pytest.skip("iverilog/vvp not installed")
    exe = tmp_path / name
    cmd = [iverilog, "-g2012", "-o", str(exe), tb, *sources]
    subprocess.run(cmd, cwd=ROOT, check=True, capture_output=True, text=True)
    r = subprocess.run([vvp, str(exe)], cwd=ROOT, capture_output=True, text=True,
                       timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "PASS" in r.stdout, r.stdout + r.stderr


def test_axi_dram_unit(tmp_path):
    """Writes/reads on both native ports, back-to-back reads (outstanding ARs/tag FIFO), a
    partial WSTRB and direction changes, against the AXI memory model."""
    _run_iverilog(tmp_path, "tb_axi_dram", "sim/verilator/tb_axi_dram.sv",
                  ["sim/verilator/axi_mem_model.sv", "rtl/mem/otpu_axi_dram.sv"])


def test_axi_dram_behind_otpu_mem_ch(tmp_path):
    """The same path with the real otpu_mem_ch in front: both bank-parity ports, its
    read-modify-write for a partial write, the write count n_wdone and n_err."""
    _run_iverilog(tmp_path, "tb_memch_axi", "sim/verilator/tb_memch_axi.sv",
                  ["sim/verilator/axi_mem_model.sv", "rtl/mem/otpu_axi_dram.sv",
                   "rtl/shell/otpu_mem_ch.sv", "rtl/shell/otpu_afifo.sv"])


@pytest.mark.parametrize("params", [
    # same timings on both controllers
    "RLAT0=8,RGAP0=0,WLAT0=4,RLAT1=8,RGAP1=0,WLAT1=16",
    # one fast, one deep and gappy (what two independent DDR4 controllers look like)
    "RLAT0=8,RGAP0=0,WLAT0=4,RLAT1=300,RGAP1=8,WLAT1=64",
    # both deep, with latency jitter (bank/page state)
    "RLAT0=120,RGAP0=4,WLAT0=64,RLAT1=120,RGAP1=4,WLAT1=64,RJIT=16",
])
def test_two_channels(tmp_path, params):
    """Two otpu_mem_ch + otpu_axi_dram pairs behind two controllers with different latency: the
    mem_ch's controller-side contract (one read beat a cycle, only on a port with a read
    outstanding) and the data, over reads, writes, partial-write read-modify-writes, both bank
    parities, 4 KB page crossings and direction changes."""
    over = [f"-Ptb_2ch_axi.{kv.split('=')[0]}={kv.split('=')[1]}" for kv in params.split(",")]
    iverilog = shutil.which("iverilog")
    vvp = shutil.which("vvp")
    if not iverilog or not vvp:
        pytest.skip("iverilog/vvp not installed")
    exe = tmp_path / "tb_2ch_axi"
    cmd = [iverilog, "-g2012", *over, "-o", str(exe), "sim/verilator/tb_2ch_axi.sv",
           "sim/verilator/axi_mem_model.sv", "rtl/mem/otpu_axi_dram.sv",
           "rtl/shell/otpu_mem_ch.sv", "rtl/shell/otpu_afifo.sv"]
    subprocess.run(cmd, cwd=ROOT, check=True, capture_output=True, text=True)
    r = subprocess.run([vvp, str(exe), "+seed=7"], cwd=ROOT, capture_output=True, text=True,
                       timeout=900)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "PASS: two channels" in r.stdout, r.stdout[-4000:]
