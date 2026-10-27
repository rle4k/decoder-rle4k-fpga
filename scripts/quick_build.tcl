# quick_build.tcl -- open V08MAC Vivado project, synth + impl + bitstream
#
# Usage (from repo root):
#   $env:XILINX_VIVADO = "C:\Xilinx\Vivado\2022.2"
#   & "$env:XILINX_VIVADO\bin\vivado.bat" -mode batch -notrace -source scripts/quick_build.tcl
#
# Override project with:
#   set ::V08MAC_XPR <path>     (before sourcing)
#   $env:V08MAC_XPR = "<path>"  (PowerShell)
#
# Note: build/*.xpr may be a 2025.1 historical artifact; daily toolchain is 2022.2
# (see docs/V1.0/V1017). Opening with 2022.2 may fail until G4 rebuild debt is cleared.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]

if {[info exists ::V08MAC_XPR] && $::V08MAC_XPR ne ""} {
    set project_path [file normalize $::V08MAC_XPR]
} elseif {[info exists ::env(V08MAC_XPR)] && $::env(V08MAC_XPR) ne ""} {
    set project_path [file normalize $::env(V08MAC_XPR)]
} else {
    set project_path [file join $repo_root build rle4k_fpga_v08.xpr]
}

puts "repo_root=$repo_root"
puts "Opening project: $project_path"
if {![file exists $project_path]} {
    puts "ERROR: project not found: $project_path"
    puts "HINT: place/create build/rle4k_fpga_v08.xpr or set V08MAC_XPR"
    exit 1
}

open_project $project_path

# Ensure PAUSE controller + per-lane staging FIFO are in the fileset
# (existing .xpr may predate these files).
foreach add_v [list \
    [file join $repo_root src rle4k_pause_ctrl.v] \
    [file join $repo_root src rle4k_sync_fifo_36.v] \
] {
    if {[file exists $add_v]} {
        set already [get_files -quiet -of_objects [get_filesets sources_1] $add_v]
        if {$already eq ""} {
            add_files -norecurse -fileset sources_1 $add_v
            puts "ADDED $add_v to sources_1"
        } else {
            puts "OK $add_v already in sources_1"
        }
    }
}
update_compile_order -fileset sources_1

# The ILA in rle4k_lan_top_v8.v is behind `ifdef ILA_DEBUG and OFF by default, because it
# changes routing and the production bitstream must be validated on the netlist that
# actually ships. Set V08MAC_ILA_DEBUG=1 to build the debug bitstream instead.
set ila_debug 0
if {[info exists ::env(V08MAC_ILA_DEBUG)] && $::env(V08MAC_ILA_DEBUG) ne "" &&
    $::env(V08MAC_ILA_DEBUG) ne "0"} {
    set ila_debug 1
}
if {$ila_debug} {
    set_property verilog_define {ILA_DEBUG} [get_filesets sources_1]
    puts "ILA_DEBUG = ON  (debug bitstream, ILA instantiated)"
} else {
    set_property verilog_define {} [get_filesets sources_1]
    puts "ILA_DEBUG = OFF (production bitstream, no ILA)"
}

puts "Resetting runs..."
reset_run synth_1
reset_run impl_1

puts "Launching synthesis..."
launch_runs synth_1 -jobs 8
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "Synthesis status: $synth_status"
if {$synth_status ne "synth_design Complete!"} {
    puts "FATAL: synthesis did not reach synth_design Complete!"
    exit 1
}

puts "Launching implementation + bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
puts "Implementation status: $impl_status"
if {$impl_status ne "write_bitstream Complete!"} {
    puts "FATAL: implementation did not reach write_bitstream Complete!"
    exit 1
}

set bit_file [file join [get_property DIRECTORY [get_runs impl_1]] rle4k_lan_top.bit]
puts "Bitstream: $bit_file"
puts "BUILD COMPLETE"

close_project
exit 0
