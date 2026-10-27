# run_sim_crc.tcl -- Run tb_decoder_crc simulation using Vivado XSim
# Usage (from repo root):
#   $env:XILINX_VIVADO = "C:\Xilinx\Vivado\2022.2"
#   & "$env:XILINX_VIVADO\bin\vivado.bat" -mode batch -notrace -source scripts/run_sim_crc.tcl

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set src_dir    [file join $repo_root src]
set tb_dir     [file join $repo_root tb]
set sim_dir    [file join $repo_root sim_out]

# Vivado bin: env override, then 2022.2 default (never 2025.1 legacy)
if {[info exists ::env(V08LAN_XILINX_BIN)] && $::env(V08LAN_XILINX_BIN) ne ""} {
    set xilinx_bin [file normalize $::env(V08LAN_XILINX_BIN)]
} elseif {[info exists ::env(XILINX_VIVADO)] && $::env(XILINX_VIVADO) ne ""} {
    set xilinx_bin [file normalize [file join $::env(XILINX_VIVADO) bin]]
} else {
    set xilinx_bin [file normalize "C:/Xilinx/Vivado/2022.2/bin"]
}
set xvlog_exe  [file join $xilinx_bin xvlog.bat]
set xelab_exe  [file join $xilinx_bin xelab.bat]
set xsim_exe   [file join $xilinx_bin xsim.bat]

puts "repo_root=$repo_root"
puts "xilinx_bin=$xilinx_bin"

# Work directory (clean if possible; continue if locked e.g. another xsim)
if {[catch {file delete -force $sim_dir} err]} {
    puts "WARN: could not remove $sim_dir ($err) - reusing directory"
}
file mkdir $sim_dir

# Source files
set src_files [list \
    [file join $src_dir rle4k_decoder_code_parser.v] \
    [file join $src_dir decoder_output_accumulator.v] \
    [file join $src_dir rle4k_decoder_core.v] \
    [file join $tb_dir tb_decoder_crc.v] \
]

puts "=== Compiling sources ==="
foreach f $src_files {
    puts "  xvlog: $f"
    if {![file exists $f]} {
        puts "ERROR: missing source $f"
        exit 1
    }
}

# Compile: work dir = sim_out; TB uses ../tb/sim_data/* relative to this cwd
cd $sim_dir
if {![file exists $xvlog_exe]} {
    puts "ERROR: xvlog not found at $xvlog_exe - set XILINX_VIVADO or V08LAN_XILINX_BIN"
    exit 1
}
# Optional extra `define macros, space separated (e.g. V08MAC_XVLOG_DEFINES=BLOCK_START_ZERO)
set xvlog_defs [list]
if {[info exists ::env(V08MAC_XVLOG_DEFINES)] && $::env(V08MAC_XVLOG_DEFINES) ne ""} {
    foreach d $::env(V08MAC_XVLOG_DEFINES) {
        lappend xvlog_defs -d $d
    }
    puts "xvlog defines: $::env(V08MAC_XVLOG_DEFINES)"
}
if {[catch {eval exec [list $xvlog_exe] -sv {*}$xvlog_defs {*}$src_files} msg]} {
    puts "ERROR xvlog: $msg"
    exit 1
}

puts "=== Elaborating ==="
if {[catch {exec {*}$xelab_exe tb_decoder_crc -s sim_snap -timescale 1ns/1ps -debug off} msg]} {
    puts "ERROR xelab: $msg"
    exit 1
}

puts "=== Running simulation ==="
if {[catch {exec {*}$xsim_exe sim_snap -runall -onerror quit} msg]} {
    puts "ERROR xsim: $msg"
    exit 1
}

# Gate on TB result text in xsim.log (xsim exits 0 even on $finish after TIMEOUT)
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

puts "=== Simulation complete ==="
if {![info exists ::V08LAN_SKIP_SIM_CRC_EXIT]} {
    exit 0
}