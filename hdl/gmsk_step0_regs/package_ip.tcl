# package_ip.tcl — packages gmsk_step0_regs.v as a reusable Vivado IP
#
# Run:  vivado -mode batch -source package_ip.tcl
# (Vivado resolves via vivado.bat on Windows — always use `call vivado`, not a
#  bare `vivado`, if invoking this from inside another .bat script.)
#
# Output lands in ./ip_repo/gmsk_step0_regs — add that path as an IP Repository
# in the fmcomms2_zed Vivado project (Project Settings -> IP -> Repository)
# before instantiating it in the block design.

set script_dir [file normalize [file dirname [info script]]]
set ip_name    gmsk_step0_regs
set proj_dir   [file join $script_dir "_ip_pkg_proj"]
set repo_dir   [file join $script_dir "ip_repo" $ip_name]

create_project -force ${ip_name}_pkg $proj_dir -part xc7z020clg484-1

add_files -norecurse [file join $script_dir "${ip_name}.v"]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $repo_dir -vendor user.org -library user \
    -taxonomy /UserIP -force -import_files

set core [ipx::current_core]
set_property name               $ip_name             $core
set_property display_name       "GMSK Step 0 Regs"   $core
set_property description        "Infrastructure-proof AXI4-Lite peripheral: ID / scratch / free-running counter registers." $core
set_property vendor_display_name "Pari"               $core
set_property version            "1.0"                $core

# S_AXI_* port naming should auto-infer the AXI4-Lite bus interface. Confirm
# this by opening the packaged IP afterward (Tools -> Create and Package New
# IP -> Edit an existing packaged IP) and checking the Ports and Interfaces
# tab shows a single "S_AXI" interface before using it in a block design.
#
# ipx::create_xgui_document only builds the cosmetic "re-customize IP" GUI
# page -- not needed since this IP has no configurable parameters, and it's
# not available as a command in every Vivado build/mode. Skip it rather than
# let a missing GUI page block a working IP from being saved.
ipx::update_checksums     $core
ipx::save_core            $core

close_project

puts "Packaged: $repo_dir"
