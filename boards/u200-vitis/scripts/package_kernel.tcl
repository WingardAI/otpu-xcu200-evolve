# Package the openTPU U200 kernel (OtpuKernel) as a Vitis .xo.
#
#   vivado -mode batch -source package_kernel.tcl -tclargs \
#     <kernel_sv> <otpu_ctrl_sv> <otpu_axi_dram_sv> <packaged_dir> <temp_project> \
#     <kernel_xml> <xo> <kernel_name> <part>
#
# Package the RTL as an IP with s_axi_control/m_axi_bank_0 associated to ap_clk/ap_rst_n and the
# xrt IP flags, then hand it to package_xo with kernel.xml.
set kernel_sv  [lindex $argv 0]
set ctrl_sv    [lindex $argv 1]
set axi_sv     [lindex $argv 2]
set packaged   [lindex $argv 3]
set tmp_proj   [lindex $argv 4]
set kernel_xml [lindex $argv 5]
set xo_path    [lindex $argv 6]
set krnl_name  [lindex $argv 7]
set part       [lindex $argv 8]

create_project -force kernel_pack $tmp_proj -part $part
set_property target_language Verilog [current_project]
import_files -fileset sources_1 $kernel_sv
import_files -fileset sources_1 $ctrl_sv
import_files -fileset sources_1 $axi_sv
set_property top $krnl_name [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $packaged -vendor xilinx.com -library RTLKernel \
  -taxonomy /KernelIP -import_files -set_current false
ipx::unload_core $packaged/component.xml
ipx::edit_ip_in_project -upgrade true -name tmp_edit_project -directory $packaged \
  $packaged/component.xml
set core [ipx::current_core]

set_property core_revision 1 $core
foreach up [ipx::get_user_parameters] {
  ipx::remove_user_parameter [get_property NAME $up] $core
}
ipx::associate_bus_interfaces -busif m_axi_bank_0 -clock ap_clk $core -reset ap_rst_n
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
