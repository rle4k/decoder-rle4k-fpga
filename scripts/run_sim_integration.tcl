# run_sim_integration.tcl -- V08MAC end-to-end RTL gate (Vivado XSim, no project)
#
# Chain under test (pure RTL only, no generated Xilinx IP):
#   raw Ethernet frames -> rle4k_mac_proto_v8 -> rle4k_stream_adapter_v8
#     -> rle4k_cdc_fifo_36 -> rle4k_decoder_core -> CRC32
# The top-level glue (CDC, skid buffer, CRC accumulator) is reproduced verbatim
# in tb/tb_rle4k_chain.v, including rle4k_lan_top_v8's .block_start(1'b0).
#
# Usage (from repo root):
#   $env:XILINX_VIVADO = "C:\Xilinx\Vivado\2022.2"
#   & "$env:XILINX_VIVADO\bin\vivado.bat" -mode batch -notrace -source scripts/run_sim_integration.tcl
#
# Exits 0 only when the TB prints ALL TESTS PASSED.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set src_dir    [file join $repo_root src]
set tb_dir     [file join $repo_root tb]
set sim_dir    [file join $repo_root sim_out_integration]

# Vivado bin: env override, then 2022.2 default (never 2025.1 legacy)
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
    [file join $tb_dir  tb_rle4k_integration.v] \
]

puts "=== Compiling sources ==="
foreach f $src_files {
    puts "  xvlog: $f"
    if {![file exists $f]} {
        puts "ERROR: missing source $f"
        exit 1
    }
}

# Work dir = sim_out_integration; the TB reads ../tb/sim_data/* relative to it.
cd $sim_dir
if {![file exists $xvlog_exe]} {
    puts "ERROR: xvlog not found at $xvlog_exe - set XILINX_VIVADO or V08LAN_XILINX_BIN"
    exit 1
}
# Optional extra `define macros, space separated (e.g. V08MAC_XVLOG_DEFINES=BLOCK_START_FIX)
set xvlog_defs [list]
if {[info exists ::env(V08MAC_XVLOG_DEFINES)] && $::env(V08MAC_XVLOG_DEFINES) ne ""} {
    foreach d $::env(V08MAC_XVLOG_DEFINES) {
        lappend xvlog_defs -d $d
    }
    puts "xvlog defines: $::env(V08MAC_XVLOG_DEFINES)"
}
if {[catch {eval exec [list $xvlog_exe] -sv -i [list $tb_dir] {*}$xvlog_defs {*}$src_files} msg]} {
    puts "ERROR xvlog: $msg"
    exit 1
}

puts "=== Elaborating ==="
if {[catch {exec {*}$xelab_exe tb_rle4k_integration -s sim_int -timescale 1ns/1ps -debug off} msg]} {
    puts "ERROR xelab: $msg"
    exit 1
}

puts "=== Running simulation ==="
if {[catch {exec {*}$xsim_exe sim_int -runall -onerror quit} msg]} {
    puts "ERROR xsim: $msg"
    exit 1
}

# Gate on TB result text (xsim exits 0 even after $finish on TIMEOUT)
set xsim_log [file join $sim_dir xsim.log]
set gate_pass 0
if {[file exists $xsim_log]} {
    set fh [open $xsim_log r]
    set logtxt [read $fh]
    close $fh
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

puts "=== Integration gate complete ==="
exit 0
