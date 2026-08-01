# package_ip.tcl — packages gmsk_step1a_ila_counter.v as a reusable Vivado IP
#
# Run:  vivado -mode batch -source package_ip.tcl
# (Vivado resolves via vivado.bat on Windows — always use `call vivado`, not a
#  bare `vivado`, if invoking this from inside another .bat script.)
#
# Output lands in ./ip_repo/gmsk_step1a_ila_counter — add that path (alongside
# gmsk_step0_regs and gmsk_step1_discriminator's) as an IP Repository in the
# fmcomms2_zed Vivado project (Project Settings -> IP -> Repository) before
# instantiating it in the block design.
#
# No AXI4-Stream interface here (unlike gmsk_step1_discriminator) — just
# aclk/aresetn, which Vivado's packager auto-infers as a Clock interface with
# an associated Reset, same auto-detection as the other two IPs' clock pins.
# No ASSOCIATED_BUSIF fixup needed since there's no bus interface to
# associate it with.

set script_dir [file normalize [file dirname [info script]]]
set ip_name    gmsk_step1a_ila_counter
set proj_dir   [file join $script_dir "_ip_pkg_proj"]
set repo_dir   [file join $script_dir "ip_repo" $ip_name]

create_project -force ${ip_name}_pkg $proj_dir -part xc7z020clg484-1

add_files -norecurse [file join $script_dir "${ip_name}.v"]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $repo_dir -vendor user.org -library user \
    -taxonomy /UserIP -force -import_files

set core [ipx::current_core]

set_property name               $ip_name                      $core
set_property display_name       "GMSK Step 1a ILA Counter"    $core
set_property description        "Free-running counter with no upstream dependency, wired onto the rx_clk/reset nets purely to prove the ILA/dbg_hub capture chain works on that clock domain before trusting any AD9361-data observation on it." $core
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
