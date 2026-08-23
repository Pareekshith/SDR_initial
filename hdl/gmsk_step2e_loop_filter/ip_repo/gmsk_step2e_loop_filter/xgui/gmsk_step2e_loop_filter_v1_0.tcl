# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "GAIN_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "GUARD_BITS" -parent ${Page_0}
  ipgui::add_param $IPINST -name "IN_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "KI_INT" -parent ${Page_0}
  ipgui::add_param $IPINST -name "KI_SHIFT" -parent ${Page_0}
  ipgui::add_param $IPINST -name "KP_INT" -parent ${Page_0}
  ipgui::add_param $IPINST -name "KP_SHIFT" -parent ${Page_0}
  ipgui::add_param $IPINST -name "LOBITS" -parent ${Page_0}
  ipgui::add_param $IPINST -name "OUT_WIDTH" -parent ${Page_0}


}

proc update_PARAM_VALUE.GAIN_WIDTH { PARAM_VALUE.GAIN_WIDTH } {
	# Procedure called to update GAIN_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.GAIN_WIDTH { PARAM_VALUE.GAIN_WIDTH } {
	# Procedure called to validate GAIN_WIDTH
	return true
}

proc update_PARAM_VALUE.GUARD_BITS { PARAM_VALUE.GUARD_BITS } {
	# Procedure called to update GUARD_BITS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.GUARD_BITS { PARAM_VALUE.GUARD_BITS } {
	# Procedure called to validate GUARD_BITS
	return true
}

proc update_PARAM_VALUE.IN_WIDTH { PARAM_VALUE.IN_WIDTH } {
	# Procedure called to update IN_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.IN_WIDTH { PARAM_VALUE.IN_WIDTH } {
	# Procedure called to validate IN_WIDTH
	return true
}

proc update_PARAM_VALUE.KI_INT { PARAM_VALUE.KI_INT } {
	# Procedure called to update KI_INT when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.KI_INT { PARAM_VALUE.KI_INT } {
	# Procedure called to validate KI_INT
	return true
}

proc update_PARAM_VALUE.KI_SHIFT { PARAM_VALUE.KI_SHIFT } {
	# Procedure called to update KI_SHIFT when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.KI_SHIFT { PARAM_VALUE.KI_SHIFT } {
	# Procedure called to validate KI_SHIFT
	return true
}

proc update_PARAM_VALUE.KP_INT { PARAM_VALUE.KP_INT } {
	# Procedure called to update KP_INT when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.KP_INT { PARAM_VALUE.KP_INT } {
	# Procedure called to validate KP_INT
	return true
}

proc update_PARAM_VALUE.KP_SHIFT { PARAM_VALUE.KP_SHIFT } {
	# Procedure called to update KP_SHIFT when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.KP_SHIFT { PARAM_VALUE.KP_SHIFT } {
	# Procedure called to validate KP_SHIFT
	return true
}

proc update_PARAM_VALUE.LOBITS { PARAM_VALUE.LOBITS } {
	# Procedure called to update LOBITS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.LOBITS { PARAM_VALUE.LOBITS } {
	# Procedure called to validate LOBITS
	return true
}

proc update_PARAM_VALUE.OUT_WIDTH { PARAM_VALUE.OUT_WIDTH } {
	# Procedure called to update OUT_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.OUT_WIDTH { PARAM_VALUE.OUT_WIDTH } {
	# Procedure called to validate OUT_WIDTH
	return true
}


proc update_MODELPARAM_VALUE.IN_WIDTH { MODELPARAM_VALUE.IN_WIDTH PARAM_VALUE.IN_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.IN_WIDTH}] ${MODELPARAM_VALUE.IN_WIDTH}
}

proc update_MODELPARAM_VALUE.OUT_WIDTH { MODELPARAM_VALUE.OUT_WIDTH PARAM_VALUE.OUT_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.OUT_WIDTH}] ${MODELPARAM_VALUE.OUT_WIDTH}
}

proc update_MODELPARAM_VALUE.GAIN_WIDTH { MODELPARAM_VALUE.GAIN_WIDTH PARAM_VALUE.GAIN_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.GAIN_WIDTH}] ${MODELPARAM_VALUE.GAIN_WIDTH}
}

proc update_MODELPARAM_VALUE.LOBITS { MODELPARAM_VALUE.LOBITS PARAM_VALUE.LOBITS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.LOBITS}] ${MODELPARAM_VALUE.LOBITS}
}

proc update_MODELPARAM_VALUE.GUARD_BITS { MODELPARAM_VALUE.GUARD_BITS PARAM_VALUE.GUARD_BITS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.GUARD_BITS}] ${MODELPARAM_VALUE.GUARD_BITS}
}

proc update_MODELPARAM_VALUE.KP_INT { MODELPARAM_VALUE.KP_INT PARAM_VALUE.KP_INT } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.KP_INT}] ${MODELPARAM_VALUE.KP_INT}
}

proc update_MODELPARAM_VALUE.KP_SHIFT { MODELPARAM_VALUE.KP_SHIFT PARAM_VALUE.KP_SHIFT } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.KP_SHIFT}] ${MODELPARAM_VALUE.KP_SHIFT}
}

proc update_MODELPARAM_VALUE.KI_INT { MODELPARAM_VALUE.KI_INT PARAM_VALUE.KI_INT } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.KI_INT}] ${MODELPARAM_VALUE.KI_INT}
}

proc update_MODELPARAM_VALUE.KI_SHIFT { MODELPARAM_VALUE.KI_SHIFT PARAM_VALUE.KI_SHIFT } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.KI_SHIFT}] ${MODELPARAM_VALUE.KI_SHIFT}
}

