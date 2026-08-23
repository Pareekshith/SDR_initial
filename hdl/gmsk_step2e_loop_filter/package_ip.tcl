# package_ip.tcl -- packages gmsk_step2e_loop_filter.v as a reusable Vivado IP
#
# Run:  vivado -mode batch -source package_ip.tcl
# (Vivado resolves via vivado.bat on Windows -- always use `call vivado`, not a
#  bare `vivado`, if invoking this from inside another .bat script.)
#
# Output lands in ./ip_repo/gmsk_step2e_loop_filter -- add that path as an IP
# Repository (alongside gmsk_step0_regs/gmsk_step1_discriminator/
# gmsk_step2a_interpolator/gmsk_step2b2_nco/gmsk_interp_tag_delay/
# gmsk_step2d_gardner_ted) in the fmcomms2_zed Vivado project before
# instantiating it in the block design.

set script_dir [file normalize [file dirname [info script]]]
set ip_name    gmsk_step2e_loop_filter
set proj_dir   [file join $script_dir "_ip_pkg_proj"]
set repo_dir   [file join $script_dir "ip_repo" $ip_name]

create_project -force ${ip_name}_pkg $proj_dir -part xc7z020clg484-1

add_files -norecurse [file join $script_dir "${ip_name}.v"]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $repo_dir -vendor user.org -library user \
    -taxonomy /UserIP -force -import_files

set core [ipx::current_core]

# Only s_axis is a real AXI4-Stream bus interface here -- adj_out/adj_valid
# are plain, permanent ports (same category as gmsk_step2b2_nco's own
# step_in/adj_in), not a bus, so unlike gmsk_step2d_gardner_ted's own
# packaging there's no second (m_axis) interface for Vivado to mis-associate
# aclk with -- no ASSOCIATED_BUSIF fix needed here.
set_property name               $ip_name                          $core
set_property display_name       "GMSK Step 2e Loop Filter"        $core
set_property description        {Proportional-plus-integrator (PI) loop filter -- turns gmsk_step2d_gardner_ted's e(n) into gmsk_step2b2_nco's adj_in correction, closing the timing-recovery loop.} $core
set_property vendor_display_name "Pari"                            $core
set_property version            "1.0"                             $core

# ipx::create_xgui_document may not exist as a valid command in every
# Vivado session/mode -- skip it (see gmsk_step0_regs packaging gotcha in
# project_fpga_gmsk_plan memory), just update checksums and save.
ipx::update_checksums     $core
ipx::save_core            $core

close_project

puts "Packaged: $repo_dir"
