# vivado_open_project_smoke.tcl -- open V08MAC .xpr and exit (no synth)
#
# Usage (from repo root):
#   & "$env:XILINX_VIVADO\bin\vivado.bat" -mode batch -notrace -source scripts/vivado_open_project_smoke.tcl
#
# Override: set ::V08MAC_XPR / $env:V08MAC_XPR

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
puts "project_path=$project_path"
if {![file exists $project_path]} {
    puts "ERROR: missing $project_path"
    exit 1
}
open_project $project_path
puts "INFO: project opened top=[get_property top [get_filesets sources_1]]"
close_project
exit 0
