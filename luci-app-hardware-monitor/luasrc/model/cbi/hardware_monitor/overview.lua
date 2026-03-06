m = Map("hardware_monitor", translate("Hardware Monitor Settings"), 
    translate("Configure hardware monitoring settings and thresholds"))

s = m:section(TypedSection, "config", translate("Monitoring Settings"))
s.anonymous = true

s:option(Flag, "enabled", translate("Enable Monitoring"), 
    translate("Enable real-time hardware monitoring"))

s:option(Value, "refresh_interval", translate("Refresh Interval"))
    .default = "5"
    .datatype = "uinteger"
    .description = translate("Auto-refresh interval in seconds (5-60)")

s = m:section(TypedSection, "thresholds", translate("Alert Thresholds"))
s.anonymous = true

s:option(Value, "cpu_warning", translate("CPU Warning Threshold (%)"))
    .default = "70"
    .datatype = "range(1,100)"

s:option(Value, "memory_warning", translate("Memory Warning Threshold (%)"))
    .default = "80"
    .datatype = "range(1,100)"

s:option(Value, "disk_warning", translate("Disk Warning Threshold (%)"))
    .default = "85"
    .datatype = "range(1,100)"

return m
