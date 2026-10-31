# ---------------------------------------------------------------------------------------------
# Force the implementation clock period to the frequency we actually want.
# v++ 2024.2 writes the impl clock through write_user_impl_clock_constraint, which asks the
# clocking wizard for a solution and (for this shell) yields the platform default 100 MHz, so
# place/route run with a 10 ns period and the "achievable frequency" reported by
# AUTO-FREQ-SCALING is only the linear extrapolation 1/(10 ns - WNS) of a route built with lots
# of slack.  Re-create the same generated clock with a 2/3 ratio (9.999 ns * 2/3 = 6.666 ns =
# 150 MHz) so the placer and router are actually timing driven to the target.  Keeping it a
# generated clock (same -source pin) preserves the clock-domain relationships of the shell.
proc otpu_force_kernel_period {mhz} {
  set name clk_kernel_00_unbuffered_net
  set clk [get_clocks -quiet $name]
  if {$clk eq ""} {
    puts "CRITICAL WARNING: \[core_pblocks.tcl\] clock '$name' not found; clock not overridden"
    return
  }
  set outpins [get_pins -quiet -of_objects $clk]
  if {![llength $outpins]} {
    set outpins [get_pins -quiet level0_i/ulp/ss_ucs/inst/aclk_kernel_00_hierarchy/clkwiz_aclk_kernel_00/inst/CLK_CORE_DRP_I/clk_inst/mmcme4_adv_inst/CLKOUT0]
  }
  if {![llength $outpins]} {
    puts "CRITICAL WARNING: \[core_pblocks.tcl\] no output pin for '$name'; clock not overridden"
    return
  }
  set outpin [lindex $outpins 0]
  set srcpin [get_property SOURCE $clk]
  if {$srcpin eq ""} {
    puts "CRITICAL WARNING: \[core_pblocks.tcl\] '$name' is not a generated clock; clock not overridden"
    return
  }
  set srcper [get_property PERIOD [get_clocks -of_objects $srcpin]]
  if {![string is double -strict $srcper]} {
    puts "CRITICAL WARNING: \[core_pblocks.tcl\] source period '$srcper' not numeric; clock not overridden"
    return
  }
  set target [expr {1000.0 / $mhz}]
  set oldper [get_property PERIOD $clk]
  # smallest integer divide/multiply pair giving the target period from the source period
  set best_d 0; set best_m 0; set best_err 1.0e9
  foreach m {1 2 3 4 5 6 7 8 9 10 12 15 16 20 24 25 30 32 40 48 50 60 64} {
    foreach d {1 2 3 4 5 6 7 8 9 10 12 15 16 20 24 25 30 32 40 48 50 60 64} {
      set per [expr {$srcper * $d / $m}]
      set err [expr {abs($per - $target)}]
      if {$err < $best_err} { set best_err $err; set best_d $d; set best_m $m }
    }
  }
  if {$best_d == 0} {
    puts "CRITICAL WARNING: \[core_pblocks.tcl\] no divider for $mhz MHz; clock not overridden"
    return
  }
  create_generated_clock -name $name -source $srcpin -divide_by $best_d -multiply_by $best_m $outpin
  set got [get_property PERIOD [get_clocks -quiet $name]]
  puts "OTPU_FLOORPLAN: kernel clock forced to $got ns ([format %.2f [expr {1000.0/$got}]] MHz; source $srcper ns, -divide_by $best_d -multiply_by $best_m), was [format %.2f [expr {1000.0/$oldper}]] MHz"
}
otpu_force_kernel_period [expr {[info exists ::env(KERNEL_MHZ)] ? $::env(KERNEL_MHZ) : 150}]

# Critical shell-facing logic in SLR1 (with the shell); bulk slice in SLR0; SLR2 free.
# SLR1 X0-2 (non-shell half) holds mem_ch + AXI bridges + dram_base + reset syncs, so the
# bridge write-window/CMD path and the AXI output to the shell never cross an SLR.
# SLR0 Y0-4 holds u_board (slice/ctrl/trace/u_mem). The only cross is the FIFO-buffered
# native bus at the Y4/Y5 boundary into the mem_ch.
create_pblock pblock_board_slr0
resize_pblock pblock_board_slr0 -add { CLOCKREGION_X0Y0 CLOCKREGION_X1Y0 CLOCKREGION_X2Y0 \
    CLOCKREGION_X3Y0 CLOCKREGION_X4Y0 CLOCKREGION_X5Y0 \
    CLOCKREGION_X0Y1 CLOCKREGION_X1Y1 CLOCKREGION_X2Y1 CLOCKREGION_X3Y1 CLOCKREGION_X4Y1 \
    CLOCKREGION_X5Y1 \
    CLOCKREGION_X0Y2 CLOCKREGION_X1Y2 CLOCKREGION_X2Y2 CLOCKREGION_X3Y2 CLOCKREGION_X4Y2 \
    CLOCKREGION_X5Y2 \
    CLOCKREGION_X0Y3 CLOCKREGION_X1Y3 CLOCKREGION_X2Y3 CLOCKREGION_X3Y3 CLOCKREGION_X4Y3 \
    CLOCKREGION_X5Y3 \
    CLOCKREGION_X0Y4 CLOCKREGION_X1Y4 CLOCKREGION_X2Y4 CLOCKREGION_X3Y4 CLOCKREGION_X4Y4 \
    CLOCKREGION_X5Y4 }
set __board [get_cells -quiet -hier -filter {NAME =~ *OtpuCoreKernel_1/inst/u_board || NAME =~ *rstn_sync0_reg*}]
if {[llength $__board]} {
  add_cells_to_pblock pblock_board_slr0 $__board
  puts "OTPU_FLOORPLAN: pblock_board_slr0 <- [llength $__board] cell(s)"
} else {
  puts "CRITICAL WARNING: \[core_pblocks.tcl\] no board cells found"
}

create_pblock pblock_io_slr1
# all of SLR1: with S = 2 the four channels (4 mem_ch + 4 AXI bridges) do not fit the old
# X0..X2 strip without congestion (fp21: 16,505 unrouted signals at 200 MHz); the shell's placed
# cells stay where they are, the placer fits ours into the rest.
resize_pblock pblock_io_slr1 -add { CLOCKREGION_X0Y5 CLOCKREGION_X1Y5 CLOCKREGION_X2Y5 \
    CLOCKREGION_X3Y5 CLOCKREGION_X4Y5 CLOCKREGION_X5Y5 \
    CLOCKREGION_X0Y6 CLOCKREGION_X1Y6 CLOCKREGION_X2Y6 \
    CLOCKREGION_X3Y6 CLOCKREGION_X4Y6 CLOCKREGION_X5Y6 \
    CLOCKREGION_X0Y7 CLOCKREGION_X1Y7 CLOCKREGION_X2Y7 \
    CLOCKREGION_X3Y7 CLOCKREGION_X4Y7 CLOCKREGION_X5Y7 \
    CLOCKREGION_X0Y8 CLOCKREGION_X1Y8 CLOCKREGION_X2Y8 \
    CLOCKREGION_X3Y8 CLOCKREGION_X4Y8 CLOCKREGION_X5Y8 \
    CLOCKREGION_X0Y9 CLOCKREGION_X1Y9 CLOCKREGION_X2Y9 \
    CLOCKREGION_X3Y9 CLOCKREGION_X4Y9 CLOCKREGION_X5Y9 }
set __io [get_cells -quiet -hier *u_memch*]
set __io [concat $__io [get_cells -quiet -hier *g_bridge0*]]
set __io [concat $__io [get_cells -quiet -hier *g_bridge1*]]
set __io [concat $__io [get_cells -quiet -hier *g_bridge2*]]
set __io [concat $__io [get_cells -quiet -hier *g_bridge3*]]
set __io [concat $__io [get_cells -quiet -hier *dram_base0_reg*]]
set __io [concat $__io [get_cells -quiet -hier *dram_base1_reg*]]
set __io [concat $__io [get_cells -quiet -hier *dram_base*]]
set __io [concat $__io [get_cells -quiet -hier *rstn_sync1_reg*]]
set __io [concat $__io [get_cells -quiet -hier *rstn_sync2_reg*]]
if {[llength $__io]} {
  add_cells_to_pblock pblock_io_slr1 $__io
  puts "OTPU_FLOORPLAN: pblock_io_slr1 <- [llength $__io] cell(s)"
} else {
  puts "CRITICAL WARNING: \[core_pblocks.tcl\] no mem/bridge cells found"
}

set __syncpins [get_pins -quiet -hier -filter {NAME =~ *rstn_sync0_reg*/CLR || NAME =~ *rstn_sync1_reg*/CLR || NAME =~ *rstn_sync2_reg*/CLR}]
if {[llength $__syncpins]} {
  set_false_path -to $__syncpins
  puts "OTPU_FLOORPLAN: false-pathed [llength $__syncpins] reset-sync CLR pin(s)"
} else {
  puts "WARNING: \[core_pblocks.tcl\] no rstn_sync* CLR pins found"
}

# The native bus' SLR crossing (otpu_u200_core_kernel g_nreg): two register slices a channel. The
# transmit side stays with the board (SLR0), the receive side with the mem_ch (SLR1), so the
# crossing net is flop to flop and the board never drives SLR1 logic directly (fp17's worst path,
# 4.4 ns of route). Matched by leaf name (a generate block's instance reads g_nreg[0].u_nbtx).
set __nbtx [get_cells -quiet -hier -filter {NAME =~ *u_nbtx}]
if {[llength $__nbtx]} {
  add_cells_to_pblock pblock_board_slr0 $__nbtx
  puts "OTPU_FLOORPLAN: pblock_board_slr0 <- +[llength $__nbtx] native-bus tx slice(s)"
} else {
  puts "WARNING: \[core_pblocks.tcl\] no native-bus tx slices found"
}
set __nbrx [get_cells -quiet -hier -filter {NAME =~ *u_nbrx}]
if {[llength $__nbrx]} {
  add_cells_to_pblock pblock_io_slr1 $__nbrx
  puts "OTPU_FLOORPLAN: pblock_io_slr1 <- +[llength $__nbrx] native-bus rx slice(s)"
} else {
  puts "WARNING: \[core_pblocks.tcl\] no native-bus rx slices found"
}

# Per-channel FIFO compaction (OTPU_FIFO_PBLOCK=1): each channel's wide queues get their own
# clock region inside the io pblock, so their write-enable/write-address nets stay inside one
# region (fp10 measured 3.55 ns of route for one u_of WE net when the 512 RAMD32s spread over
# three regions; fp19's 250 MHz run failed on congestion in exactly this datapath).
source [file join [file dirname [info script]] core_pblocks_fifo.inc]
