# run_sim_fullspeed.tcl -- V08MAC zero inter-frame-gap stress (Vivado XSim, no project)
#
# Diagnostic, not a pass/fail gate: drives STREAM_DATA frames back to back with
# no idle cycle and reports frames sent / accepted / bytes fed / words decoded,
# plus a TX back-pressure probe on rle4k_mac_proto_v8.mac_tx_ready.
#
# Usage (from repo root):
#   $env:XILINX_VIVADO = "C:\Xilinx\Vivado\2022.2"
#   & "$env:XILINX_VIVADO\bin\vivado.bat" -mode batch -notrace -source scripts/run_sim_fullspeed.tcl
#
# Exits 0 when the simulation ran. Set V08MAC_FULLSPEED_STRICT=1 to make proven
# frame loss a hard failure (use once the RTL fixes have landed).

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set src_dir    [file join $repo_root src]
set tb_dir     [file join $repo_root tb]
set sim_dir    [file join $repo_root sim_out_fullspeed]

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
puts "xilinx_bin=$xilinx_bin"

if {[catch {file delete -force $sim_dir} err]} {
    puts "WARN: could not remove $sim_dir ($err) - reusing directory"
}
file mkdir $sim_dir

set src_files [list \
    [file join $src_dir rle4k_decoder_code_parser.v] \
    [file join $src_dir decoder_output_accumulator.v] \
    [file join $src_dir rle4k_decoder_core.v] \
    [file join $src_dir rle4k_cdc_fifo_36.v] \
    [file join $src_dir rle4k_mac_proto_v8.v] \
    [file join $src_dir rle4k_stream_adapter_v8.v] \
    [file join $tb_dir  tb_rle4k_chain.v] \
    [file join $tb_dir  tb_rle4k_fullspeed.v] \
]

puts "=== Compiling sources ==="
foreach f $src_files {
    puts "  xvlog: $f"
    if {![file exists $f]} {
        puts "ERROR: missing source $f"
        exit 1
    }
}

cd $sim_dir
if {![file exists $xvlog_exe]} {
    puts "ERROR: xvlog not found at $xvlog_exe - set XILINX_VIVADO or V08LAN_XILINX_BIN"
    exit 1
}
if {[catch {eval exec [list $xvlog_exe] -sv -i [list $tb_dir] {*}$src_files} msg]} {
    puts "ERROR xvlog: $msg"
    exit 1
}

puts "=== Elaborating ==="
if {[catch {exec {*}$xelab_exe tb_rle4k_fullspeed -s sim_fs -timescale 1ns/1ps -debug off} msg]} {
    puts "ERROR xelab: $msg"
    exit 1
}

puts "=== Running simulation ==="
# Optional inter-frame gap, e.g. -tclargs -gap 8. Zero (the default) is the
# back-to-back stress; a non-zero value paces the burst for comparison.
set gap 0
for {set i 0} {$i < [llength $argv]} {incr i} {
    if {[lindex $argv $i] eq "-gap"} { set gap [lindex $argv [expr {$i + 1}]] }
}
set gap_file [file join $repo_root tb sim_data fullspeed_gap.txt]
set gfh [open $gap_file w]
puts $gfh $gap
close $gfh
puts "=== inter-frame gap = $gap cycles ==="

if {[catch {exec {*}$xsim_exe sim_fs -runall -onerror quit} msg]} {
    puts "ERROR xsim: $msg"
    exit 1
}

set xsim_log [file join $sim_dir xsim.log]
set loss 0
if {[file exists $xsim_log]} {
    set fh [open $xsim_log r]
    set logtxt [read $fh]
    close $fh
    puts "--- stress summary ---"
    foreach line [split $logtxt "\n"] {
        if {[string match "*>>>*" $line] || [string match "*Phase*" $line]} {
            puts $line
        }
    }
    if {[string match "*RX FRAME LOSS PROVEN*" $logtxt]} { set loss 1 }
    if {[string match "*TX FSM IGNORES mac_tx_ready*" $logtxt]} { set loss 1 }
}

puts "=== Full-speed stress complete (see $xsim_log) ==="
if {$loss && [info exists ::env(V08MAC_FULLSPEED_STRICT)] &&
    $::env(V08MAC_FULLSPEED_STRICT) ne ""} {
    puts "ERROR: frame loss detected and V08MAC_FULLSPEED_STRICT is set"
    exit 1
}
exit 0
