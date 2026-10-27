# run_sim_pause_ctrl.tcl -- PAUSE backpressure gate (rule 14)
set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set tb_dir     [file join $repo_root tb]
set src_dir    [file join $repo_root src]
set sim_dir    [file join $repo_root sim_out_pause_ctrl]

if {[info exists ::env(XILINX_VIVADO)] && $::env(XILINX_VIVADO) ne ""} {
    set xilinx_bin [file normalize [file join $::env(XILINX_VIVADO) bin]]
} else {
    set xilinx_bin [file normalize "C:/Xilinx/Vivado/2022.2/bin"]
}
set xvlog_exe [file join $xilinx_bin xvlog.bat]
set xelab_exe [file join $xilinx_bin xelab.bat]
set xsim_exe  [file join $xilinx_bin xsim.bat]

file mkdir $sim_dir

set mode 1
if {[info exists ::PAUSE_PEER_HONOR] && $::PAUSE_PEER_HONOR ne ""} {
    set mode $::PAUSE_PEER_HONOR
} elseif {[info exists ::env(PAUSE_PEER_HONOR)] && $::env(PAUSE_PEER_HONOR) ne ""} {
    set mode $::env(PAUSE_PEER_HONOR)
}
puts "pause_peer_honor=$mode"

cd $sim_dir
puts [exec $xvlog_exe [file join $src_dir rle4k_pause_ctrl.v] [file join $tb_dir tb_rle4k_pause_ctrl.v]]
puts [exec $xelab_exe tb_rle4k_pause_ctrl -s pause_ctrl_sim]

set honor_flag [expr {$mode == 0 ? "honor0" : "honor1"}]

# Peer PAUSE reaction latency (rule 14): 0 = idealised instant peer (legacy
# behaviour), 1 = peer reacts PEER_LAT cycles late, which is the only mode that
# can go red on the pre-min-hold rle4k_pause_ctrl.
set lat 0
if {[info exists ::PAUSE_PEER_LAT] && $::PAUSE_PEER_LAT ne ""} {
    set lat $::PAUSE_PEER_LAT
} elseif {[info exists ::env(PAUSE_PEER_LAT)] && $::env(PAUSE_PEER_LAT) ne ""} {
    set lat $::env(PAUSE_PEER_LAT)
}
puts "pause_peer_lat=$lat"
set extra_args {}
if {$lat != 0} { lappend extra_args -testplusarg latency1 }
set rc 0
if {[catch {exec $xsim_exe pause_ctrl_sim -runall -testplusarg $honor_flag {*}$extra_args} result]} {
    set rc 1
}
puts $result
if {[string match "*tb_rle4k_pause_ctrl: FAIL*" $result]} { set rc 1 }
if {[string match "*ALL TESTS PASSED*" $result]} { set rc 0 }
puts "run_sim_pause_ctrl: done mode=$mode lat=$lat rc=$rc"
exit $rc