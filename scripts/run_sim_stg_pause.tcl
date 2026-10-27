# run_sim_stg_pause.tcl — rule-14 TB for staging pause watermark
#
# Usage (repo root):
#   $env:XILINX_VIVADO = "C:\Xilinx\Vivado\2022.2"
#   $env:V08MAC_STG_PAUSE_MODE = "0"   # optional RED
#   & "$env:XILINX_VIVADO\bin\vivado.bat" -mode batch -notrace -source scripts/run_sim_stg_pause.tcl

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set tb_dir     [file join $repo_root tb]
set sim_dir    [file join $repo_root sim_out_stg_pause]

if {[info exists ::env(V08LAN_XILINX_BIN)] && $::env(V08LAN_XILINX_BIN) ne ""} {
    set xilinx_bin [file normalize $::env(V08LAN_XILINX_BIN)]
} elseif {[info exists ::env(XILINX_VIVADO)] && $::env(XILINX_VIVADO) ne ""} {
    set xilinx_bin [file normalize [file join $::env(XILINX_VIVADO) bin]]
} else {
    set xilinx_bin [file normalize "C:/Xilinx/Vivado/2022.2/bin"]
}
set xvlog_exe [file join $xilinx_bin xvlog.bat]
set xelab_exe [file join $xilinx_bin xelab.bat]
set xsim_exe  [file join $xilinx_bin xsim.bat]

set mode_file [file join $tb_dir sim_data stg_pause_mode.txt]
file mkdir [file join $tb_dir sim_data]
if {[info exists ::env(V08MAC_STG_PAUSE_MODE)] && $::env(V08MAC_STG_PAUSE_MODE) ne ""} {
    set fd [open $mode_file w]
    puts $fd $::env(V08MAC_STG_PAUSE_MODE)
    close $fd
}
if {![file exists $mode_file]} {
    set fd [open $mode_file w]
    puts $fd "1"
    close $fd
}

puts "repo_root=$repo_root"
puts "stg_pause_mode=[string trim [read [open $mode_file r]]]"

catch {file delete -force $sim_dir}
file mkdir $sim_dir
cd $sim_dir

set tb_v [file join $tb_dir tb_stg_pause_watermark.v]
if {[catch {exec $xvlog_exe -sv $tb_v} msg]} { puts "ERROR xvlog: $msg"; exit 1 }
if {[catch {exec $xelab_exe -debug typical tb_stg_pause_watermark -s stg_pause_sim} msg]} {
    puts "ERROR xelab: $msg"; exit 1
}
if {[catch {exec $xsim_exe stg_pause_sim -R} msg]} {
    puts $msg
    if {[string match "*ALL TESTS PASSED*" $msg]} { exit 0 }
    exit 1
}
puts $msg
if {[string match "*ALL TESTS PASSED*" $msg]} { exit 0 }
if {[string match "*FAIL*" $msg]} { exit 1 }
exit 0
