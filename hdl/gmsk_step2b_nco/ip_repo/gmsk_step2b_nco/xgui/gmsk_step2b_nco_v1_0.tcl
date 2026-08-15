# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "LOG2_SPS" -parent ${Page_0}
  ipgui::add_param $IPINST -name "MU_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "STEP_WIDTH" -parent ${Page_0}


}

proc update_PARAM_VALUE.LOG2_SPS { PARAM_VALUE.LOG2_SPS } {
	# Procedure called to update LOG2_SPS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.LOG2_SPS { PARAM_VALUE.LOG2_SPS } {
	# Procedure called to validate LOG2_SPS
	return true
}

proc update_PARAM_VALUE.MU_WIDTH { PARAM_VALUE.MU_WIDTH } {
	# Procedure called to update MU_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.MU_WIDTH { PARAM_VALUE.MU_WIDTH } {
	# Procedure called to validate MU_WIDTH
	return true
}

proc update_PARAM_VALUE.STEP_WIDTH { PARAM_VALUE.STEP_WIDTH } {
	# Procedure called to update STEP_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.STEP_WIDTH { PARAM_VALUE.STEP_WIDTH } {
	# Procedure called to validate STEP_WIDTH
	return true
}


proc update_MODELPARAM_VALUE.STEP_WIDTH { MODELPARAM_VALUE.STEP_WIDTH PARAM_VALUE.STEP_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.STEP_WIDTH}] ${MODELPARAM_VALUE.STEP_WIDTH}
}

proc update_MODELPARAM_VALUE.MU_WIDTH { MODELPARAM_VALUE.MU_WIDTH PARAM_VALUE.MU_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.MU_WIDTH}] ${MODELPARAM_VALUE.MU_WIDTH}
}

proc update_MODELPARAM_VALUE.LOG2_SPS { MODELPARAM_VALUE.LOG2_SPS PARAM_VALUE.LOG2_SPS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.LOG2_SPS}] ${MODELPARAM_VALUE.LOG2_SPS}
}

