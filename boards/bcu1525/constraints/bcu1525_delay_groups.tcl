# New in the XCU200 port (WingardAI, 2026) for openTPU,
# https://github.com/FeSens/openTPU (Apache-2.0). See NOTICE.

# Each DIMM's LiteDRAM core (otpu_ld4 u_ld0..u_ld3) has its own IDELAYCTRL, its own 300 MHz
# reference clock and its own banks, so each needs its own IODELAY_GROUP: without one the
# placer's DRC PLIDC-7 stops ("Design has more than one unlocked and ungrouped IDELAYCTRL
# cells"). LiteX's generated XDC (boards/bcu1525/litedram/otpu_ld4.xdc) carries no group
# constraints, and its IDELAYE3 / ODELAYE3 cells sit directly under the core instance.
# create_project.tcl adds this file as an unmanaged late Tcl constraint (PROCESSING_ORDER LATE,
# USED_IN_SYNTHESIS false), so it applies to the synthesized netlist before placement.
foreach i {0 1 2 3} {
  set grp "otpu_ld4_$i"
  set ctrl [get_cells -quiet "u_ld$i/IDELAYCTRL"]
  if {[llength $ctrl]} { set_property IODELAY_GROUP $grp $ctrl }
  foreach c [get_cells -quiet -hier -filter "NAME =~ u_ld$i/* && (REF_NAME == IDELAYE3 || REF_NAME == ODELAYE3)"] {
    set_property IODELAY_GROUP $grp $c
  }
  puts "IODELAY_GROUP $grp: [llength [get_cells -quiet -hier -filter "NAME =~ u_ld$i/* && (REF_NAME == IDELAYE3 || REF_NAME == ODELAYE3)"]] delay cells + [llength $ctrl] IDELAYCTRL"
}
