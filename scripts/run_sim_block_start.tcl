# run_sim_block_start.tcl -- Defect B probe: is .block_start(1'b0) a bug?
#
# Runs tb_rle4k_block_start twice against the same RTL:
#   A) BLOCK_START_MODE=0 -- shipped rle4k_lan_top_v8 (.block_start(1'b0))
#        expected: FAIL, the core's parameter validation never runs
#   B) BLOCK_START_MODE=1 -- proposed fix (strip_byte_cnt_rst delayed 1 cycle)
#        expected: PASS, error_code 0x03 is raised for stride < width
#
# Usage (from repo root):
#   $env:XILINX_VIVADO = "C:\Xilinx\Vivado\2022.2"
#   & "$env:XILINX_VIVADO\bin\vivado.bat" -mode batch -notrace -source scripts/run_sim_block_start.tcl
#
# Exits 0 when A fails and B passes, i.e. the defect is confirmed AND the
# proposed fix resolves it. Any other combination exits 1.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set src_dir    [file join $repo_root src]
set tb_dir     [file join $repo_root tb]

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

set src_files [list \
    [file join $src_dir rle4k_decoder_code_parser.v] \
    [file join $src_dir decoder_output_accumulator.v] \
    [file join $src_dir rle4k_decoder_core.v] \
    [file join $src_dir rle4k_cdc_fifo_36.v] \
    [file join $src_dir rle4k_mac_proto_v8.v] \
    [file join $src_dir rle4k_stream_adapter_v8.v] \
    [file join $tb_dir  tb_rle4k_chain.v] \
    [file join $tb_dir  tb_rle4k_block_start.v] \
]
foreach f $src_files {
    if {![file exists $f]} {
        puts "ERROR: missing source $f"
        exit 1
    }
}

# Returns 1 when the run printed ALL TESTS PASSED.
proc run_variant {name subdir defines repo_root tb_dir src_files xvlog_exe xelab_exe xsim_exe} {
    set sim_dir [file join $repo_root $subdir]
    if {[catch {file delete -force $sim_dir} err]} {
        puts "WARN: could not remove $sim_dir ($err)"
    }
    file mkdir $sim_dir
    cd $sim_dir

    set defargs [list]
    foreach d $defines { lappend defargs -d $d }

    puts ""
    puts "=== $name ==="
    if {[catch {eval exec [list $xvlog_exe] -sv -i [list $tb_dir] {*}$defargs {*}$src_files} msg]} {
        puts "ERROR xvlog: $msg"
        exit 1
    }
    if {[catch {exec {*}$xelab_exe tb_rle4k_block_start -s sim_bs -timescale 1ns/1ps -debug off} msg]} {
        puts "ERROR xelab: $msg"
        exit 1
    }
    if {[catch {exec {*}$xsim_exe sim_bs -runall -onerror quit} msg]} {
        puts "ERROR xsim: $msg"
        exit 1
    }
    set xsim_log [file join $sim_dir xsim.log]
    set passed 0
    if {[file exists $xsim_log]} {
        set fh [open $xsim_log r]
        set logtxt [read $fh]
        close $fh
        foreach line [split $logtxt "\n"] {
            if {[string match "*  *" $line] && ![string match "#*" $line]} { puts $line }
        }
        if {[string match "*ALL TESTS PASSED*" $logtxt]} { set passed 1 }
    }
    return $passed
}

set a_pass [run_variant "A: shipped .block_start(1'b0)" sim_out_bs_shipped {} \
                        $repo_root $tb_dir $src_files $xvlog_exe $xelab_exe $xsim_exe]
set b_pass [run_variant "B: proposed fix (delayed strip pulse)" sim_out_bs_fix {BLOCK_START_FIX} \
                        $repo_root $tb_dir $src_files $xvlog_exe $xelab_exe $xsim_exe]

puts ""
puts "================ Defect B verdict ================"
puts " A shipped (.block_start(1'b0)) parameter check ran : [expr {$a_pass ? {yes} : {no}}]"
puts " B fix     (delayed strip pulse) parameter check ran : [expr {$b_pass ? {yes} : {no}}]"
if {!$a_pass && $b_pass} {
    puts " VERDICT: .block_start(1'b0) is a LATENT BUG; the proposed fix resolves it."
    puts "=================================================="
    exit 0
}
puts " VERDICT: unexpected combination - inspect the logs above."
puts "=================================================="
exit 1
