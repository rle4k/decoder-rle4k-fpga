# run_sim_lane_rr.tcl — lane assign policy gate (no IP)
#
# Usage (repo root):
#   $env:XILINX_VIVADO = "C:\Xilinx\Vivado\2022.2"
#   & "$env:XILINX_VIVADO\bin\vivado.bat" -mode batch -notrace -source scripts/run_sim_lane_rr.tcl
#
# Optional: set ::LANE_RR_MODE 0|1 before source, or write tb/sim_data/lane_rr_mode.txt
# Default mode=1 (RR fix). Mode 0 is the intentional red baseline (lowest-free).

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set tb_dir     [file join $repo_root tb]
set sim_dir    [file join $repo_root sim_out_lane_rr]

if {[info exists ::env(XILINX_VIVADO)] && $::env(XILINX_VIVADO) ne ""} {
    set xilinx_bin [file normalize [file join $::env(XILINX_VIVADO) bin]]
} else {
    set xilinx_bin [file normalize "C:/Xilinx/Vivado/2022.2/bin"]
}
set xvlog_exe [file join $xilinx_bin xvlog.bat]
set xelab_exe [file join $xilinx_bin xelab.bat]
set xsim_exe  [file join $xilinx_bin xsim.bat]

file mkdir $sim_dir
file mkdir [file join $tb_dir sim_data]

set mode 1
if {[info exists ::LANE_RR_MODE] && $::LANE_RR_MODE ne ""} {
    set mode $::LANE_RR_MODE
} elseif {[info exists ::env(LANE_RR_MODE)] && $::env(LANE_RR_MODE) ne ""} {
    set mode $::env(LANE_RR_MODE)
}
set mode_file [file join $tb_dir sim_data lane_rr_mode.txt]
set mf [open $mode_file w]
puts $mf $mode
close $mf
puts "lane_rr_mode=$mode -> $mode_file"

cd $sim_dir
exec $xvlog_exe [file join $tb_dir tb_parallel_lane_rr.v]
exec $xelab_exe tb_parallel_lane_rr -s tb_lane_rr_sim
# xsim needs cwd with relative path to mode file used by TB
# TB opens "tb/sim_data/lane_rr_mode.txt" from repo root — run from repo_root
cd $repo_root
set rc 0
if {[catch {exec $xsim_exe tb_lane_rr_sim -R -wdb [file join $sim_dir lane_rr.wdb] \
        -log [file join $sim_dir xsim.log] \
        -tclbatch [file join $sim_dir run.tcl]} err]} {
    # create empty tclbatch
}
set rf [open [file join $sim_dir run.tcl] w]
puts $rf "run all"
puts $rf "quit"
close $rf

# Elaborate was in sim_dir; xsim needs that work lib. Re-run from sim_dir with
# a symlink/copy of mode path the TB expects.
file mkdir [file join $sim_dir tb sim_data]
file copy -force $mode_file [file join $sim_dir tb sim_data lane_rr_mode.txt]
cd $sim_dir
set status [catch {exec $xsim_exe tb_lane_rr_sim -R -tclbatch run.tcl \
        >@stdout 2>@stderr} result]
set logf [file join $sim_dir xsim_run.log]
# Also grep transcript from stdout capture — xsim prints to console
puts $result

set passed 0
if {[regexp {ALL TESTS PASSED} $result]} {
    set passed 1
}
# Also check log if redirected
if {!$passed && [file exists [file join $sim_dir xsim.log]]} {
    set lf [open [file join $sim_dir xsim.log] r]
    set ltxt [read $lf]
    close $lf
    if {[regexp {ALL TESTS PASSED} $ltxt]} { set passed 1 }
}

if {$passed} {
    puts "LANE_RR_SIM PASS mode=$mode"
    exit 0
}
puts "LANE_RR_SIM FAIL mode=$mode"
exit 1
