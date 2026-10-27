# run_sim_rxchain.tcl -- V08MAC receive-path throughput gate (Vivado XSim, no project)
#
# Chain under test (behavioural models for the three generated IP stages, real
# RTL for everything else):
#   8-bit MAC RX at line rate -> 8->64 width converter -> async FIFO (125 ->
#   15.625) -> packet FIFO -> rle4k_mac_proto_v8 -> adapter -> decoder
#
# This is the gate that tb_rle4k_integration and tb_rle4k_fullspeed cannot be:
# both of them drive rle4k_mac_proto_v8 directly, downstream of the stage where
# frames are actually lost. See the header of tb/tb_rle4k_rxchain.v.
#
# Usage (from repo root):
#   & "C:\Xilinx\Vivado\2022.2\bin\vivado.bat" -mode batch -notrace -source scripts/run_sim_rxchain.tcl
#
# Set V08MAC_XVLOG_DEFINES=RXCHAIN_PACED to re-run the same stimulus with a wide
# interframe gap; that separates a throughput defect from a functional one.
#
# Exits 0 only when the TB prints ALL TESTS PASSED.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set src_dir    [file join $repo_root src]
set tb_dir     [file join $repo_root tb]
set sim_dir    [file join $repo_root sim_out_rxchain]

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
    [file join $tb_dir  tb_rle4k_rxchain.v] \
]

foreach f $src_files {
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

set xvlog_defs [list]
if {[info exists ::env(V08MAC_XVLOG_DEFINES)] && $::env(V08MAC_XVLOG_DEFINES) ne ""} {
    foreach d $::env(V08MAC_XVLOG_DEFINES) {
        lappend xvlog_defs -d $d
    }
    puts "xvlog defines: $::env(V08MAC_XVLOG_DEFINES)"
}

puts "=== Compiling sources ==="
if {[catch {eval exec [list $xvlog_exe] -sv -i [list $tb_dir] {*}$xvlog_defs {*}$src_files} msg]} {
    puts "ERROR xvlog: $msg"
    exit 1
}

puts "=== Elaborating ==="
if {[catch {exec {*}$xelab_exe tb_rle4k_rxchain -s sim_rxchain -timescale 1ns/1ps -debug off} msg]} {
    puts "ERROR xelab: $msg"
    exit 1
}

puts "=== Running simulation ==="
if {[catch {exec {*}$xsim_exe sim_rxchain -runall -onerror quit} msg]} {
    puts "ERROR xsim: $msg"
    exit 1
}

set xsim_log [file join $sim_dir xsim.log]
set gate_pass 0
if {[file exists $xsim_log]} {
    set fh [open $xsim_log r]
    set logtxt [read $fh]
    close $fh
    foreach line [split $logtxt "\n"] {
        if {[string match "*frames *" $line] || [string match "*loss rate*" $line] ||
            [string match "*beats dropped*" $line]} {
            puts $line
        }
    }
    if {[string match "*TIMEOUT*" $logtxt]} {
        puts "ERROR: simulation TIMEOUT (see $xsim_log)"
        exit 1
    }
    if {[string match "*TEST FAILED*" $logtxt]} {
        puts "ERROR: TEST FAILED (see $xsim_log)"
        exit 1
    }
    if {[string match "*ALL TESTS PASSED*" $logtxt]} {
        set gate_pass 1
        puts "PASS: ALL TESTS PASSED (see $xsim_log)"
    }
}
if {!$gate_pass} {
    puts "ERROR: did not find ALL TESTS PASSED in $xsim_log"
    exit 1
}

puts "=== RX chain gate complete ==="
exit 0
