# export_hw.tcl -- export the fmcomms2_zed hardware platform (with bitstream)
# for FSBL/BOOT.BIN generation. Run: vivado -mode batch -source export_hw.tcl

set ::env(ADI_IGNORE_VERSION_CHECK) 1

set proj_path "C:/Users/Parit/Documents/Projects/ADI_hdl/projects/fmcomms2/zed/fmcomms2_zed.xpr"
set xsa_out   "C:/Users/Parit/Documents/Projects/SDR_initial/hdl/boot_build/fmcomms2_zed.xsa"

open_project $proj_path
write_hw_platform -fixed -include_bit -force $xsa_out

puts "Exported: $xsa_out"
