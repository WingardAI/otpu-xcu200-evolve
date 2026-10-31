# Post-route diagnostics (only when OTPU_DIAG is set to a file prefix).
# Writes the top failing/near-critical kernel paths and a per-region utilization dump so the
# next floorplan iteration can see *which* structures (wide LUTRAM FIFOs, bridges, board) are
# on the critical paths instead of only the single worst one that report_timing_summary shows.
if {[info exists ::env(OTPU_DIAG)]} {
  set prefix $::env(OTPU_DIAG)
  set kclk [get_clocks -quiet clk_kernel_00_unbuffered_net]
  puts "OTPU_DIAG: kernel clock period [get_property PERIOD $kclk] ns"
  if {[catch {
    report_timing -setup -max_paths 300 -nworst 300 -path_type short \
      -file ${prefix}_timing_top.rpt
    puts "OTPU_DIAG: wrote ${prefix}_timing_top.rpt"
  } err]} { puts "OTPU_DIAG: report_timing failed: $err" }
  if {[catch {
    report_timing -setup -max_paths 1 -nworst 1 -group [get_clocks clk_kernel_00_unbuffered_net] \
      -path_type full -file ${prefix}_timing_worst_full.rpt
    puts "OTPU_DIAG: wrote ${prefix}_timing_worst_full.rpt"
  } err]} { puts "OTPU_DIAG: report_timing(full) failed: $err" }
  if {[catch {
    report_utilization -hierarchical -hierarchical_depth 3 -file ${prefix}_util_hier.rpt
    puts "OTPU_DIAG: wrote ${prefix}_util_hier.rpt"
  } err]} { puts "OTPU_DIAG: report_utilization failed: $err" }
}

# Per-pblock (i.e. per-SLR-group) area: the exact split of our kernel across SLR0/SLR1.
if {[info exists ::env(OTPU_DIAG)]} {
  if {[catch {
    report_utilization -pblocks [get_pblocks] -file ${::env(OTPU_DIAG)}_pblock_util.rpt
    puts "OTPU_DIAG: wrote ${::env(OTPU_DIAG)}_pblock_util.rpt"
  } err]} { puts "OTPU_DIAG: report_utilization -pblocks failed: $err" }
}
