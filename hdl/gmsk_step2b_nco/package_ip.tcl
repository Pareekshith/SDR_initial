# package_ip.tcl -- packages gmsk_step2b_nco.v as a reusable Vivado IP
#
# Run:  vivado -mode batch -source package_ip.tcl
# (Vivado resolves via vivado.bat on Windows -- always use `call vivado`, not a
#  bare `vivado`, if invoking this from inside another .bat script.)
#
# Output lands in ./ip_repo/gmsk_step2b_nco -- add that path as an IP
# Repository (alongside gmsk_step0_regs/gmsk_step1_discriminator/
# gmsk_step2a_interpolator) in the fmcomms2_zed Vivado project before
# instantiating it in the block design.
#
# No ASSOCIATED_BUSIF fix needed here, unlike the other three IPs' packaging
# scripts -- this module has no AXI4-Stream bus interface at all (no tdata,
# see the module's own header comment for why), so Vivado's packager has
# nothing to auto-infer beyond aclk/aresetn as plain clock/reset interfaces
# and everything else as plain ports.

set script_dir [file normalize [file dirname [info script]]]
set ip_name    gmsk_step2b_nco
set proj_dir   [file join $script_dir "_ip_pkg_proj"]
set repo_dir   [file join $script_dir "ip_repo" $ip_name]

create_project -force ${ip_name}_pkg $proj_dir -part xc7z020clg484-1

add_files -norecurse [file join $script_dir "${ip_name}.v"]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $repo_dir -vendor user.org -library user \
    -taxonomy /UserIP -force -import_files

set core [ipx::current_core]

set_property name               $ip_name                      $core
set_property display_name       "GMSK Step 2b NCO"            $core
set_property description        "Free-running modulo-1 phase-accumulator NCO -- generates the strobe/mu pair driving symbol timing recovery, standalone ahead of the Gardner loop." $core
set_property vendor_display_name "Pari"                        $core
set_property version            "1.0"                         $core

# ipx::create_xgui_document may not exist as a valid command in every
# Vivado session/mode -- skip it (see gmsk_step0_regs packaging gotcha in
# project_fpga_gmsk_plan memory), just update checksums and save.
ipx::update_checksums     $core
ipx::save_core            $core

close_project

puts "Packaged: $repo_dir"
