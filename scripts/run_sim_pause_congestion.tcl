# run_sim_pause_congestion.tcl -- early PAUSE OR gate (rule 14)
set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set tb_dir     [file join $repo_root tb]
set sim_dir    [file join $repo_root sim_out_pause_congestion]

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
if {[info exists ::env(PAUSE_CONGESTION_MODE)] && $::env(PAUSE_CONGESTION_MODE) ne ""} {
    set mode $::env(PAUSE_CONGESTION_MODE)
}
puts "pause_congestion_mode=$mode"

cd $sim_dir
puts [exec $xvlog_exe [file join $tb_dir tb_rle4k_pause_congestion.v]]
puts [exec $xelab_exe tb_rle4k_pause_congestion -s pause_cong_sim]

set flag [expr {$mode == 0 ? "late0" : "early1"}]
set rc 0
if {[catch {exec $xsim_exe pause_cong_sim -runall -testplusarg $flag} result]} {
    set rc 1
}
puts $result
if {[string match "*tb_rle4k_pause_congestion: FAIL*" $result]} { set rc 1 }
if {[string match "*ALL TESTS PASSED*" $result]} { set rc 0 }
puts "run_sim_pause_congestion: done mode=$mode rc=$rc"
exit $rc
