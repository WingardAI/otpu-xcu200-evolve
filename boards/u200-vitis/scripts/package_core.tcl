# New in the XCU200 port (WingardAI, 2026) for openTPU,
# https://github.com/FeSens/openTPU (Apache-2.0). See NOTICE.

# Package the openTPU U200 core kernel from a source file list.
#   vivado -mode batch -source package_core.tcl -tclargs \
#     <filelist> <packaged_dir> <temp_project> <kernel_xml> <xo> <kernel_name> <part>
set filelist  [lindex $argv 0]
set packaged  [lindex $argv 1]
set tmp_proj  [lindex $argv 2]
set kernel_xml [lindex $argv 3]
set xo_path   [lindex $argv 4]
set krnl_name [lindex $argv 5]
set part      [lindex $argv 6]

set fh [open $filelist r]
set raw [read $fh]
close $fh
set srcs {}
foreach ln [split $raw "\n"] {
  set ln [string trim $ln]
  if {$ln ne "" && ![string match "#*" $ln]} { lappend srcs $ln }
}

create_project -force kernel_pack $tmp_proj -part $part
set_property target_language Verilog [current_project]
foreach f $srcs { import_files -fileset sources_1 $f }
set_property top $krnl_name [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $packaged -vendor xilinx.com -library RTLKernel \
  -taxonomy /KernelIP -import_files -set_current false
ipx::unload_core $packaged/component.xml
ipx::edit_ip_in_project -upgrade true -name tmp_edit_project -directory $packaged \
  $packaged/component.xml
set core [ipx::current_core]
set_property core_revision 1 $core
foreach up [ipx::get_user_parameters] { ipx::remove_user_parameter [get_property NAME $up] $core }
# one bus interface per AXI master arg (the count comes from the kernel XML: 2 for S=1, 4 for S=2)
set kx [open $kernel_xml r]; set kxml [read $kx]; close $kx
set nbank 0
foreach m [regexp -all -inline {name="m_axi_bank_([0-9]+)"} $kxml] {
  if {[regexp {[0-9]+} $m n]} { if {$n + 1 > $nbank} { set nbank [expr {$n + 1}] } }
}
for {set i 0} {$i < $nbank} {incr i} {
  ipx::associate_bus_interfaces -busif m_axi_bank_$i -clock ap_clk $core -reset ap_rst_n
}
ipx::associate_bus_interfaces -busif s_axi_control -clock ap_clk $core -reset ap_rst_n
set_property xpm_libraries {XPM_CDC XPM_MEMORY XPM_FIFO} $core
set_property sdx_kernel true $core
set_property sdx_kernel_type rtl $core
set_property supported_families { } $core
set_property auto_family_support_level level_2 $core
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity -kernel $core
ipx::save_core $core
close_project -delete

package_xo -xo_path $xo_path -kernel_name $krnl_name -ip_directory $packaged \
  -kernel_xml $kernel_xml
puts "PACKAGE_XO ok: $xo_path"
