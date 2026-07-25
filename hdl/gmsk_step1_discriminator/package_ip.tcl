# package_ip.tcl — packages gmsk_step1_discriminator.v as a reusable Vivado IP
#
# Run:  vivado -mode batch -source package_ip.tcl
# (Vivado resolves via vivado.bat on Windows — always use `call vivado`, not a
#  bare `vivado`, if invoking this from inside another .bat script.)
#
# Output lands in ./ip_repo/gmsk_step1_discriminator — add that path (plus the
# gmsk_step0_regs one already in use) as an IP Repository in the fmcomms2_zed
# Vivado project (Project Settings -> IP -> Repository) before instantiating
# it in the block design. Port naming (aclk/aresetn, s_axis_t*/m_axis_t*)
# follows Xilinx's standard AXI4-Stream convention so Vivado's packager
# should auto-infer S_AXIS/M_AXIS bus interfaces — confirm this on the
# Ports and Interfaces tab before using it in a block design, same as was
# done for gmsk_step0_regs's S_AXI interface.

set script_dir [file normalize [file dirname [info script]]]
set ip_name    gmsk_step1_discriminator
set proj_dir   [file join $script_dir "_ip_pkg_proj"]
set repo_dir   [file join $script_dir "ip_repo" $ip_name]

create_project -force ${ip_name}_pkg $proj_dir -part xc7z020clg484-1

add_files -norecurse [file join $script_dir "${ip_name}.v"]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $repo_dir -vendor user.org -library user \
    -taxonomy /UserIP -force -import_files

set core [ipx::current_core]
set_property name               $ip_name                      $core
set_property display_name       "GMSK Step 1 Discriminator"   $core
set_property description        "Delay-and-conjugate-multiply frequency discriminator: turns complex baseband IQ into a per-sample instantaneous-frequency estimate for the RX demod chain." $core
set_property vendor_display_name "Pari"                        $core
set_property version            "1.0"                         $core

# ipx::create_xgui_document only builds the cosmetic "re-customize IP" GUI
# page and isn't available as a command in every Vivado build/mode (see the
# gmsk_step0_regs packaging gotcha in project_fpga_gmsk_plan memory) — skip
# it rather than let a missing GUI page block a working IP from being saved.
ipx::update_checksums     $core
ipx::save_core            $core

close_project

puts "Packaged: $repo_dir"
