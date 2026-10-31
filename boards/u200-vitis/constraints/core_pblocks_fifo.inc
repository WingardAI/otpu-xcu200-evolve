
# ---------------------------------------------------------------------------------------------
# Per-channel FIFO compaction (OTPU_FIFO_PBLOCK=1).
#
# A mem_ch's wide queues are distributed-RAM arrays: u_of 512b, u_ad/u_xd 577b, u_ar/u_xr 512b.
# Each writes all of its bits from ONE write enable and one write address, so the WE and the
# write-address bits fan out over ~600 RAMD32 pins inside the FIFO's own tiles.  That is fine
# while the tiles are adjacent, but the io pblock runs at ~40 % utilisation (Vivado has no
# reason to keep them together), and in fp10 the 512 RAMD32 of one u_of ended up spread over
# three clock regions: the WE net alone cost 3.55 ns of route and the FIFO's write pointer
# 1.69 ns, i.e. 8.22 ns total for four LUT levels (94.5 % route).
#
# Giving each channel's queues a single clock region keeps every FIFO's control nets inside a
# region.  ~3.1k LUTRAM of the region's ~9.8k LUTRAM sites are used, so there is room, and the
# rest of the channel (arbiter, command compare) stays in the parent io pblock.
if {[info exists ::env(OTPU_FIFO_PBLOCK)]} {
  foreach {c region} {0 CLOCKREGION_X0Y5 1 CLOCKREGION_X1Y5} {
    set pb "pblock_fifo_ch$c"
    create_pblock $pb
    resize_pblock $pb -add $region
    set cells {}
    # (plain patterns: [0] is a single-character glob class matching '0', as in *g_bridge0*)
    foreach pat [list \
        *g_ch\\[$c\\].u_memch/g_port\\[0\\].u_oq* \
        *g_ch\\[$c\\].u_memch/g_port\\[0\\].u_of* \
        *g_ch\\[$c\\].u_memch/g_port\\[0\\].u_tag* \
        *g_ch\\[$c\\].u_memch/g_port\\[1\\].u_oq* \
        *g_ch\\[$c\\].u_memch/g_port\\[1\\].u_of* \
        *g_ch\\[$c\\].u_memch/g_port\\[1\\].u_tag* \
        *g_ch\\[$c\\].u_memch/u_aq* \
        *g_ch\\[$c\\].u_memch/u_ad* \
        *g_ch\\[$c\\].u_memch/u_xq* \
        *g_ch\\[$c\\].u_memch/u_xd* \
        *g_ch\\[$c\\].u_memch/u_ar* \
        *g_ch\\[$c\\].u_memch/u_xr* \
        *g_ch\\[$c\\].u_memch/u_xai* \
        *g_ch\\[$c\\].u_memch/u_xwi* \
        *g_ch\\[$c\\].u_memch/u_xrq* \
        *g_ch\\[$c\\].u_memch/u_xbq* ] {
      set got [get_cells -quiet -hier $pat]
      if {![llength $got]} { puts "WARNING: \[core_pblocks.tcl\] fifo pattern matched nothing: $pat" }
      set cells [concat $cells $got]
    }
    set cells [lsort -unique $cells]
    if {[llength $cells]} {
      add_cells_to_pblock [get_pblocks $pb] $cells
      puts "OTPU_FLOORPLAN: $pb <- [llength $cells] cell(s) in $region"
    } else {
      puts "CRITICAL WARNING: \[core_pblocks.tcl\] $pb matched no cells"
    }
  }
}
