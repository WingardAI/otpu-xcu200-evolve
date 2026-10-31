# New in the XCU200 port (WingardAI, 2026) for openTPU,
# https://github.com/FeSens/openTPU (Apache-2.0). See NOTICE.

# Power analysis of the openTPU U200 core kernel, offline (no card, no xclbin).
#
#   vivado -mode batch -nojournal -log <out>/power.log -source tools/power_core.tcl \
#     -tclargs <srcs.f> <outdir> <part> <mhz> <vcd|-> <junction_temp>
#
# Synthesizes rtl/boards/u200-vitis/otpu_u200_core_kernel.sv (S = 2, four DDR4 channels as the
# fp22/fp23 bitstreams; edit NS in the file for the S = 1 shape), places it, then reports power:
# static (leakage at the junction temperature), clock tree, signals, logic, BRAM, DSP. With a VCD
# (tools/power_activity.py) the signal activity is the simulated one -- an idle window and a busy
# window give the real idle/busy split; without one Vivado's vectorless estimate is used.
#
# Reports: <out>/power_vectorless.rpt and <out>/power_vcd.rpt. Checkpoints <out>/post_synth.dcp,
# <out>/post_place.dcp (re-runnable without another synthesis).

proc arg {i default} {
  if {$i < [llength $::argv]} { return [lindex $::argv $i] }
  return $default
}

set list  [arg 0 ""]
set out   [arg 1 ""]
set part  [arg 2 "xcu200-fsgd2104-2-e"]
set mhz   [arg 3 180]
set vcd   [arg 4 "-"]
set tj    [arg 5 100]

if {![file exists $list]} { error "no source list: $list" }
file mkdir $out

set srcs {}
foreach f [split [string trim [read [open $list r]]] "\n"] {
  set f [string trim $f]
  if {$f ne "" && [file exists $f]} { lappend srcs $f }
}
puts "== [llength $srcs] sources"

if {[file exists $out/post_place.dcp] && ![info exists ::env(OTPU_POWER_FORCE)]} {
  puts "== reusing $out/post_place.dcp"
  open_checkpoint $out/post_place.dcp
} else {
  read_verilog -sv {*}$srcs
  synth_design -top OtpuCoreKernel -part $part -flatten_hierarchy rebuilt -mode out_of_context
  create_clock -period [expr {1000.0 / $mhz}] -name ap_clk [get_ports ap_clk]
  write_checkpoint -force $out/post_synth.dcp
  opt_design
  place_design
  write_checkpoint -force $out/post_place.dcp
}

set_operating_conditions -process typical -junction_temp $tj
set power_enable_multi_threading 1
puts "== Tj $tj C, place done"

report_power -file $out/power_vectorless.rpt
puts "== power_vectorless.rpt"

if {$vcd ne "-" && [file exists $vcd]} {
  puts "== reading $vcd"
  read_vcd -strip_path tb_board/dut $vcd
  report_power -file $out/power_vcd.rpt
  puts "== power_vcd.rpt"
}

puts "== POWER DONE"
