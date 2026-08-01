# build_fsbl.py -- build a Zynq FSBL for fmcomms2_zed from the exported .xsa
# (run export_hw.tcl first). Run: vitis -s build_fsbl.py
#
# Creating a "standalone" platform for a Zynq PS processor auto-generates a
# zynq_fsbl boot domain as part of platform creation (no separate app_component
# needed -- an earlier attempt at that failed with
# "AttributeError: 'Platform' object has no attribute 'startswith'" since
# create_app_component expects the platform as a name string, not an object,
# and the FSBL sources already exist under <workspace>/fsbl_platform/zynq_fsbl/
# by the time create_platform_component returns).
import vitis

client = vitis.create_client()
client.set_workspace(path="C:/Users/Parit/Documents/Projects/SDR_initial/hdl/boot_build/fsbl_ws")

platform = client.create_platform_component(
    name="fsbl_platform",
    hw_design="C:/Users/Parit/Documents/Projects/SDR_initial/hdl/boot_build/fmcomms2_zed.xsa",
    os="standalone",
    cpu="ps7_cortexa9_0",
    domain_name="standalone_domain"
)
platform.build()

print("BUILD DONE -- fsbl.elf at fsbl_ws/fsbl_platform/zynq_fsbl/build/fsbl.elf")
