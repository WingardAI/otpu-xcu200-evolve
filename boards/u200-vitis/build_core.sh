#!/usr/bin/env bash
# Build the openTPU U200 core kernel (Phase 3): package OtpuCoreKernel and link the xclbin.
#   source /path/to/Vitis/2024.2/settings64.sh
#   boards/u200-vitis/build_core.sh
# Environment: OUT, JOBS, KERNEL_MHZ (default 150: the core and the AXI bridge share ap_clk).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="${OUT:-$here/build}"
jobs="${JOBS:-8}"
kmhz="${KERNEL_MHZ:-150}"
ns="${OTPU_NS:-2}"                     # slices: 2 the default, 1 for the MoE image
tw="${OTPU_TMEM_WORDS:-32768}"         # TMEM words a bank: 65536 for the MoE image
part="xcu200-fsgd2104-2-e"
platform="xilinx_u200_gen3x16_xdma_2_202110_1"
mkdir -p "$out"
rm -rf "$out/packaged_core" "$out/temp_core" "$out/OtpuCoreKernel.xo" "$out/OtpuCoreKernel.xclbin"
kern="rtl/boards/u200-vitis/otpu_u200_core_kernel.sv"
if [ "$ns" != 2 ] || [ "$tw" != 32768 ]; then     # a variant top: NS and TMEM_WORDS patched
  mkdir -p "$out/gen"                              # (Qwen3.5-35B-A3B: NS=1, TMEM 64K)
  kern="$out/gen/otpu_u200_core_kernel.sv"
  sed -e "s/localparam int NS  = 2;/localparam int NS  = $ns;/" \
      -e "s/\.TMEM_WORDS(1 << 15)/.TMEM_WORDS($tw)/" \
      rtl/boards/u200-vitis/otpu_u200_core_kernel.sv > "$kern"
  echo "== kernel variant: NS=$ns TMEM_WORDS=$tw ($kern)"
fi
list="$out/core_srcs.f"
cat > "$list" <<SRCS
rtl/top/otpu_pkg.sv
rtl/vpu/otpu_fp.sv
rtl/vpu/otpu_fpipe.sv
rtl/mem/otpu_tmem.sv
rtl/mem/otpu_actram.sv
rtl/seq/otpu_seq.sv
rtl/vpu/otpu_vtree.sv
rtl/dma/otpu_dma.sv
rtl/mxu/otpu_mxu.sv
rtl/vpu/otpu_quant.sv
rtl/vpu/otpu_se_comp.sv
rtl/vpu/otpu_se_tail.sv
rtl/vpu/otpu_vpu.sv
rtl/top/otpu_coll.sv
rtl/top/otpu_slice.sv
rtl/tech/xilinxus/otpu_tech_dsp.sv
rtl/tech/generic/otpu_tech_ram.sv
rtl/shell/otpu_ctrl.sv
rtl/shell/otpu_trace.sv
rtl/shell/otpu_board.sv
rtl/mem/otpu_native_dram.sv
rtl/shell/otpu_afifo.sv
rtl/shell/otpu_mem_ch.sv
rtl/shell/otpu_axi_split2.sv
rtl/mem/otpu_axi_dram.sv
$kern
SRCS
echo "== package OtpuCoreKernel (.xo)"
(cd "$root" && vivado -mode batch -nojournal -log "$out/package_core.log" \
  -source "$here/scripts/package_core.tcl" \
  -tclargs "$list" "$out/packaged_core" "$out/temp_core" "$here/kernel_core.xml" \
           "$out/OtpuCoreKernel.xo" "OtpuCoreKernel" "$part")
echo "== link OtpuCoreKernel (.xclbin), ${kmhz} MHz"
v++ -l -t hw --platform "$platform" --kernel_frequency "$kmhz" --optimize 3 \
  --vivado.impl.strategies "" \
  --vivado.prop run.impl_1.STRATEGY=Performance_Explore \
  --vivado.prop "run.impl_1.{STEPS.PLACE_DESIGN.ARGS.MORE OPTIONS}={}" \
  --vivado.prop run.impl_1.STEPS.PLACE_DESIGN.TCL.PRE="$here/constraints/core_pblocks.tcl" \
  --vivado.prop run.impl_1.STEPS.PHYS_OPT_DESIGN.IS_ENABLED=true \
  --vivado.prop run.impl_1.STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE=AggressiveFanoutOpt \
  --vivado.prop run.impl_1.STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED=true \
  --vivado.prop run.impl_1.STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE=AggressiveExplore \
  --vivado.prop run.impl_1.STEPS.POST_ROUTE_PHYS_OPT_DESIGN.TCL.POST="$here/constraints/core_diag.tcl" \
  --vivado.synth.jobs "$jobs" --vivado.impl.jobs 1 \
  --connectivity.sp OtpuCoreKernel_1.m_axi_bank_0:DDR[0] \
  --connectivity.sp OtpuCoreKernel_1.m_axi_bank_1:DDR[1] \
  --connectivity.sp OtpuCoreKernel_1.m_axi_bank_2:DDR[2] \
  --connectivity.sp OtpuCoreKernel_1.m_axi_bank_3:DDR[3] \
  -o "$out/OtpuCoreKernel.xclbin" "$out/OtpuCoreKernel.xo"
echo "done: $out/OtpuCoreKernel.xclbin"
