# run_sim_parallel_feed.tcl — rule-14 TB for parallel compressed feed
#
# Usage (from repo root):
#   $env:XILINX_VIVADO = "C:\Xilinx\Vivado\2022.2"
#   & "$env:XILINX_VIVADO\bin\vivado.bat" -mode batch -notrace -source scripts/run_sim_parallel_feed.tcl
#
# Modes via tb/sim_data/feed_depth_mode.txt:
#   0 = shallow RED baseline
#   1 = deep GREEN (default)
#
# Or set env V08MAC_FEED_DEPTH_MODE=0|1 before sourcing.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set tb_dir     [file join $repo_root tb]
set sim_dir    [file join $repo_root sim_out_parallel_feed]

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

set mode_file [file join $tb_dir sim_data feed_depth_mode.txt]
file mkdir [file join $tb_dir sim_data]
if {[info exists ::env(V08MAC_FEED_DEPTH_MODE)] && $::env(V08MAC_FEED_DEPTH_MODE) ne ""} {
    set fd [open $mode_file w]
    puts $fd $::env(V08MAC_FEED_DEPTH_MODE)
    close $fd
}
if {![file exists $mode_file]} {
    set fd [open $mode_file w]
    puts $fd "1"
    close $fd
}

puts "repo_root=$repo_root"
puts "xilinx_bin=$xilinx_bin"
puts "feed_depth_mode=[string trim [read [open $mode_file r]]]"

if {[catch {file delete -force $sim_dir} err]} {
    puts "WARN: could not remove $sim_dir ($err)"
}
file mkdir $sim_dir
cd $sim_dir

if {![file exists $xvlog_exe]} {
    puts "ERROR: xvlog not found at $xvlog_exe"
    exit 1
}

set tb_v [file join $tb_dir tb_parallel_feed_overlap.v]
puts "=== xvlog $tb_v ==="
if {[catch {exec $xvlog_exe -sv $tb_v} msg]} {
    puts "ERROR xvlog: $msg"
    exit 1
}

puts "=== xelab ==="
if {[catch {exec $xelab_exe -debug typical tb_parallel_feed_overlap -s parallel_feed_sim} msg]} {
    puts "ERROR xelab: $msg"
    exit 1
}

puts "=== xsim ==="
if {[catch {exec $xsim_exe parallel_feed_sim -R} msg]} {
    puts $msg
    if {[string match "*ALL TESTS PASSED*" $msg]} {
        puts "PASS (finish code may be non-zero on some xsim builds)"
        exit 0
    }
    exit 1
}
puts $msg
if {[string match "*ALL TESTS PASSED*" $msg]} {
    exit 0
}
if {[string match "*FAIL*" $msg]} {
    exit 1
}
exit 0
