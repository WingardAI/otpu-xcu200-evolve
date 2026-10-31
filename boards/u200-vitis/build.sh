#!/usr/bin/env bash
# New in the XCU200 port (WingardAI, 2026) for openTPU,
# https://github.com/FeSens/openTPU (Apache-2.0). See NOTICE.

# Build the openTPU U200 Vitis RTL kernel (Phase 1 skeleton): package OtpuKernel as an .xo and
# link it for xilinx_u200_gen3x16_xdma_2_202110_1.
#
#   source /path/to/Vitis/2024.2/settings64.sh
#   boards/u200-vitis/build.sh
#
# Environment: OUT (default boards/u200-vitis/build), JOBS (v++ jobs), KERNEL_MHZ (default 300).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="${OUT:-$here/build}"
jobs="${JOBS:-8}"
kmhz="${KERNEL_MHZ:-300}"
part="xcu200-fsgd2104-2-e"
platform="xilinx_u200_gen3x16_xdma_2_202110_1"

if ! command -v vivado >/dev/null 2>&1; then
  echo "build.sh: vivado not on PATH (source .../Vitis/2024.2/settings64.sh)" >&2
  exit 2
fi
if ! command -v v++ >/dev/null 2>&1; then
  echo "build.sh: v++ not on PATH (source .../Vitis/2024.2/settings64.sh)" >&2
  exit 2
fi

mkdir -p "$out"
# package_xo appends to an existing .xo container; always start from clean artifacts.
rm -rf "$out/packaged" "$out/temp_pack" "$out/OtpuKernel.xo" "$out/OtpuKernel.xclbin"
echo "== package OtpuKernel (.xo)"
vivado -mode batch -nojournal -log "$out/package.log" \
  -source "$here/scripts/package_kernel.tcl" \
  -tclargs "$root/rtl/boards/u200-vitis/otpu_u200_kernel.sv" \
           "$root/rtl/shell/otpu_ctrl.sv" \
           "$root/rtl/mem/otpu_axi_dram.sv" \
           "$out/packaged" "$out/temp_pack" "$here/kernel.xml" \
           "$out/OtpuKernel.xo" "OtpuKernel" "$part"

echo "== link OtpuKernel (.xclbin), kernel clock ${kmhz} MHz"
v++ -l -t hw --platform "$platform" --kernel_frequency "$kmhz" \
  --vivado.synth.jobs "$jobs" --vivado.impl.jobs 1 \
  -o "$out/OtpuKernel.xclbin" "$out/OtpuKernel.xo"

echo "done: $out/OtpuKernel.xclbin"
