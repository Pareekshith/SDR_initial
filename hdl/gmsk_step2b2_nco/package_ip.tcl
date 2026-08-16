# package_ip.tcl -- packages gmsk_step2b2_nco.v as a reusable Vivado IP
#
# Run:  vivado -mode batch -source package_ip.tcl
# (Vivado resolves via vivado.bat on Windows -- always use `call vivado`, not a
#  bare `vivado`, if invoking this from inside another .bat script.)
#
# Output lands in ./ip_repo/gmsk_step2b2_nco -- add that path as an IP
# Repository (alongside gmsk_step0_regs/gmsk_step1_discriminator/
# gmsk_step2a_interpolator/gmsk_step2b_nco/gmsk_step2d_gardner_ted) in the
# fmcomms2_zed Vivado project before instantiating it in the block design.
# gmsk_step2b_nco (sub-step B) is untouched and stays separately valid --
# this is a new module, not a replacement.

set script_dir [file normalize [file dirname [info script]]]
set ip_name    gmsk_step2b2_nco
set proj_dir   [file join $script_dir "_ip_pkg_proj"]
set repo_dir   [file join $script_dir "ip_repo" $ip_name]

create_project -force ${ip_name}_pkg $proj_dir -part xc7z020clg484-1

add_files -norecurse [file join $script_dir "${ip_name}.v"]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $repo_dir -vendor user.org -library user \
    -taxonomy /UserIP -force -import_files

set core [ipx::current_core]

set_property name               $ip_name                      $core
set_property display_name       "GMSK Step 2b2 Dual-Threshold NCO" $core
set_property description        {Extends the sub-step B phase-accumulator NCO with a second (mid-symbol, 0.5) threshold crossing, feeding gmsk_step2d_gardner_ted real on-time/mid-point sample pairs via the is_midpoint tag.} $core
set_property vendor_display_name "Pari"                        $core
set_property version            "1.0"                         $core

# ipx::create_xgui_document may not exist as a valid command in every
# Vivado session/mode -- skip it (see gmsk_step0_regs packaging gotcha in
# project_fpga_gmsk_plan memory), just update checksums and save.
ipx::update_checksums     $core
ipx::save_core            $core

close_project

puts "Packaged: $repo_dir"
