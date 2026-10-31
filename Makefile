# openTPU on the Alveo U200 (XCU200) -- see docs/u200.md.
#
#   make kernel    OtpuKernel (registers + a scratch AXI master):     boards/u200-vitis/build.sh
#   make core      OtpuCoreKernel (the accelerator, S=2):             boards/u200-vitis/build_core.sh
#   make core-moe  the same for the MoE image (S=1, 64K TMEM words)
#   make test      the project's test suite (needs Verilator 5; the model tests need the
#                  checkpoints under models/, see README.md)
#
# The Vitis/Vivado tools must be on PATH: source
#   /path/to/Vitis/2024.2/settings64.sh
PY ?= python3

.PHONY: kernel core core-moe test

kernel:
	boards/u200-vitis/build.sh

core:
	boards/u200-vitis/build_core.sh

core-moe:
	OTPU_NS=1 OTPU_TMEM_WORDS=65536 boards/u200-vitis/build_core.sh

test:
	$(PY) -m pytest -q
