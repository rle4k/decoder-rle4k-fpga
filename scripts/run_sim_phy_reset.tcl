# run_sim_phy_reset.tcl -- gate rle4k_phy_reset before it reaches the board
#
# Usage (from repo root):
#   $env:XILINX_VIVADO = "C:\Xilinx\Vivado\2022.2"
#   & "$env:XILINX_VIVADO\bin\vivado.bat" -mode batch -notrace -source scripts/run_sim_phy_reset.tcl
#
# Checks the PHY reset assertion clears the 10 ms datasheet floor, releases
# exactly once (the straps latch on that edge), and re-arms on loss of lock.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set src_dir    [file join $repo_root src]
set tb_dir     [file join $repo_root tb]
set sim_dir    [file join $repo_root sim_out_phy_reset]

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

puts "repo_root=$repo_root"

if {[catch {file delete -force $sim_dir} err]} {
    puts "WARN: could not remove $sim_dir ($err) - reusing directory"
}
file mkdir $sim_dir

set src_files [list \
    [file join $src_dir rle4k_phy_reset.v] \
    [file join $tb_dir tb_phy_reset.v] \
]
foreach f $src_files {
    if {![file exists $f]} { puts "ERROR: missing source $f"; exit 1 }
}

cd $sim_dir
if {![file exists $xvlog_exe]} {
    puts "ERROR: xvlog not found at $xvlog_exe - set XILINX_VIVADO or V08LAN_XILINX_BIN"
    exit 1
}

puts "=== Compiling ==="
if {[catch {eval exec [list $xvlog_exe] -sv {*}$src_files} msg]} {
    puts "ERROR xvlog: $msg"
    exit 1
}

puts "=== Elaborating ==="
if {[catch {exec {*}$xelab_exe tb_phy_reset -s sim_snap -timescale 1ns/1ps -debug off} msg]} {
    puts "ERROR xelab: $msg"
    exit 1
}

puts "=== Running ==="
catch {exec {*}$xsim_exe sim_snap -runall -onerror quit} msg
puts $msg

set xsim_log [file join $sim_dir xsim.log]
if {![file exists $xsim_log]} {
    puts "ERROR: no xsim.log"
    exit 1
}
set fh [open $xsim_log r]
set logtxt [read $fh]
close $fh

if {[string match "*TIMEOUT*" $logtxt]} { puts "ERROR: simulation TIMEOUT"; exit 1 }
if {[string match "*FAILED*"  $logtxt]} { puts "ERROR: TEST FAILED"; exit 1 }
if {![string match "*ALL TESTS PASSED*" $logtxt]} {
    puts "ERROR: did not find ALL TESTS PASSED in $xsim_log"
    exit 1
}

puts "PASS: ALL TESTS PASSED"
exit 0
