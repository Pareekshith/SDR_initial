# package_ip.tcl -- packages gmsk_step2a_interpolator.v as a reusable Vivado IP
#
# Run:  vivado -mode batch -source package_ip.tcl
# (Vivado resolves via vivado.bat on Windows -- always use `call vivado`, not a
#  bare `vivado`, if invoking this from inside another .bat script.)
#
# Output lands in ./ip_repo/gmsk_step2a_interpolator -- add that path as an IP
# Repository (alongside gmsk_step0_regs/gmsk_step1_discriminator) in the
# fmcomms2_zed Vivado project before instantiating it in the block design.

set script_dir [file normalize [file dirname [info script]]]
set ip_name    gmsk_step2a_interpolator
set proj_dir   [file join $script_dir "_ip_pkg_proj"]
set repo_dir   [file join $script_dir "ip_repo" $ip_name]

create_project -force ${ip_name}_pkg $proj_dir -part xc7z020clg484-1

add_files -norecurse [file join $script_dir "${ip_name}.v"]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $repo_dir -vendor user.org -library user \
    -taxonomy /UserIP -force -import_files

set core [ipx::current_core]

# Same ASSOCIATED_BUSIF fix gmsk_step1_discriminator's packaging needed --
# Vivado's auto-inference only associates aclk with whichever bus interface
# it finds first (observed: just m_axis). Both s_axis and m_axis run off
# aclk; Connection Automation uses ASSOCIATED_BUSIF to know that.
set aclk_intf       [ipx::get_bus_interfaces aclk -of_objects $core]
set assoc_busif_arg [ipx::get_bus_parameters ASSOCIATED_BUSIF -of_objects $aclk_intf]
set_property value {s_axis:m_axis} $assoc_busif_arg
set_property name               $ip_name                      $core
set_property display_name       "GMSK Step 2a Interpolator"   $core
set_property description        "Cubic Farrow (Lagrange) interpolator core, mu supplied externally -- open-loop sub-step ahead of the Gardner timing-recovery loop." $core
set_property vendor_display_name "Pari"                        $core
set_property version            "1.0"                         $core

# ipx::create_xgui_document may not exist as a valid command in every
# Vivado session/mode -- skip it (see gmsk_step0_regs packaging gotcha in
# project_fpga_gmsk_plan memory), just update checksums and save.
ipx::update_checksums     $core
ipx::save_core            $core

close_project

puts "Packaged: $repo_dir"
