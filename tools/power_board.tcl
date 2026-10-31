# New in the XCU200 port (WingardAI, 2026) for openTPU,
# https://github.com/FeSens/openTPU (Apache-2.0). See NOTICE.

# Power analysis of the slices (otpu_board is the DUT of the board simulation, so a simulated VCD
# annotates it one-to-one; the kernel's four otpu_mem_ch/otpu_axi_dram bridges are not in the
# simulation's DUT -- the testbench models them -- and get the vectorless estimate).
#
#   vivado -mode batch -nojournal -log <out>/power.log -source tools/power_board.tcl \
#     -tclargs <srcs.f> <outdir> <part> <mhz> <vcd|-> <junction_temp> <S>
#
# Reports: power_idle_vcd.rpt / power_busy_vcd.rpt (one checkpoint each: post_place_<S>.dcp).

proc arg {i default} {
  if {$i < [llength $::argv]} { return [lindex $::argv $i] }
  return $default
}

set list [arg 0 ""]
set out  [arg 1 ""]
set part [arg 2 "xcu200-fsgd2104-2-e"]
set mhz  [arg 3 180]
set vcd  [arg 4 "-"]
set tj   [arg 5 90]
set S    [arg 6 2]

file mkdir $out
set srcs {}
foreach f [split [string trim [read [open $list r]]] "\n"] {
  set f [string trim $f]
  if {$f ne "" && [file exists $f]} { lappend srcs $f }
}
set dcp $out/post_place_S$S.dcp

if {[file exists $dcp] && ![info exists ::env(OTPU_POWER_FORCE)]} {
  puts "== reusing $dcp"
  open_checkpoint $dcp
} else {
  read_verilog -sv {*}$srcs
  synth_design -top otpu_board -part $part -mode out_of_context -flatten_hierarchy rebuilt \
    -generic S=$S -generic D=128 -generic MCOLS=4 -generic ACT_ROWS=16 -generic ACT_BLOCKS=128 \
    -generic TMEM_WORDS=32768 -generic IMEM_WORDS=32768 -generic LANES=8 -generic WIN=16 \
    -generic TMEM_IMPL=0 -generic MXU_IMPL=2 -generic MXU_E=4 -generic VPU_CL=2 \
    -generic ULANES=8 -generic COLL_GATHER=1 -generic SEQ_WC=1 -generic PLATFORM=4
  create_clock -period [expr {1000.0 / $mhz}] -name clk [get_ports clk]
  opt_design
  place_design
  write_checkpoint -force $dcp
}

set_operating_conditions -process typical -junction_temp $tj
set power_enable_multi_threading 1
report_power -file $out/power_vectorless_S$S.rpt

if {$vcd ne "-"} {
  foreach f $vcd {
    if {![file exists $f]} { continue }
    open_checkpoint $dcp
    set_operating_conditions -process typical -junction_temp $tj
    set name [file rootname [file tail $f]]
    if {[catch {read_vcd -strip_path tb_board/dut $f} e]} { puts "READVCD FAILED: $e" }
    report_power -file $out/power_$name.rpt
    close_design
    puts "PW DONE $name"
  }
}
puts "POWER DONE S=$S"
