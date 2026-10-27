# run_sim_ring_window.tcl -- whole-block ring address gate (XSim)
set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ..]]
set tb_dir     [file join $root_dir tb]
set src_dir    [file join $root_dir src]
set sim_dir    [file join $root_dir sim_out ring_window]
file mkdir $sim_dir
cd $sim_dir

set xilinx_root {C:/Xilinx/Vivado/2022.2}
if {[info exists env(XILINX_VIVADO)] && $env(XILINX_VIVADO) ne ""} {
    set xilinx_root $env(XILINX_VIVADO)
}
set xilinx_bin [file join $xilinx_root bin]
set xvlog_exe [file join $xilinx_bin xvlog.bat]
set xelab_exe [file join $xilinx_bin xelab.bat]
set xsim_exe  [file join $xilinx_bin xsim.bat]

set src_files [list \
    [file join $src_dir rle4k_ring_window.v] \
    [file join $tb_dir  tb_rle4k_ring_window.v] \
]

puts "xvlog..."
if {[catch {eval exec [list $xvlog_exe] -sv {*}$src_files} msg]} {
    puts "ERROR xvlog: $msg"
    exit 1
}
puts "xelab..."
if {[catch {exec {*}$xelab_exe tb_rle4k_ring_window -s sim_ring -timescale 1ns/1ps -debug off} msg]} {
    puts "ERROR xelab: $msg"
    exit 1
}
puts "xsim..."
if {[catch {exec {*}$xsim_exe sim_ring -runall -onerror quit} msg]} {
    puts "ERROR xsim: $msg"
    exit 1
}

set xsim_log [file join $sim_dir xsim.log]
set fh [open $xsim_log r]
set log [read $fh]
close $fh
puts $log
if {[string match "*PASS tb_rle4k_ring_window*" $log]} {
    puts "PASS: ring window"
    exit 0
}
puts "ERROR: ring window failed"
exit 1