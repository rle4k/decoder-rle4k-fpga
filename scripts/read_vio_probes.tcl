# read_vio_probes.tcl -- dump every VIO input probe on the attached KU040.
#
# Usage (from repo root):
#   & "C:\Xilinx\Vivado\2022.2\bin\vivado.bat" -mode batch -nolog -nojournal \
#       -notrace -source scripts/read_vio_probes.tcl [-tclargs <probes.ltx>]
#
# With no argument the probe file is taken from the archived bitstream folder
# that matches the design currently in the repository. Values are printed as
# "PROBE <name> = <value>" so the caller can grep them out of the Vivado log.
#
# This only reads; it never programs the device. Programming lives in
# scripts/program_fpga.tcl.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]

if {[llength $argv] > 0} {
    set ltx [file normalize [lindex $argv 0]]
} else {
    # The .ltx must match the design actually in the device, so prefer the one
    # the current project just produced. Falling back to archives sorted by name
    # picked "recovered-..." over any 2026-... folder (r > 2), which silently
    # loaded a 5-probe file against a 17-probe design; order by mtime instead.
    set ltx ""
    set built [file join $repo_root build rle4k_fpga_v08.runs impl_1 rle4k_lan_top.ltx]
    if {[file exists $built]} {
        set ltx $built
    } else {
        set dated {}
        foreach d [glob -nocomplain -directory \
                   [file join $repo_root reports bitstreams] -types d *] {
            set f [file join $d rle4k_lan_top.ltx]
            if {[file exists $f]} { lappend dated [list [file mtime $f] $f] }
        }
        foreach pair [lsort -integer -decreasing -index 0 $dated] {
            set ltx [lindex $pair 1]
            break
        }
    }
}

if {$ltx eq "" || ![file exists $ltx]} {
    puts "ERROR: no .ltx probe file found; pass one with -tclargs <path>"
    exit 1
}
puts "PROBE_FILE $ltx"

open_hw_manager
connect_hw_server -url localhost:3121
set targets [get_hw_targets]
if {[llength $targets] == 0} {
    puts "ERROR: no hardware target; check the JTAG cable and hw_server"
    exit 1
}
open_hw_target [lindex $targets 0]

set dev [lindex [get_hw_devices xcku040*] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set_property PROBES.FILE      $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device $dev

set vios [get_hw_vios -quiet]
if {[llength $vios] == 0} {
    puts "ERROR: no VIO core found -- the device is not running this design"
    close_hw_target
    disconnect_hw_server
    exit 1
}

foreach vio $vios {
    refresh_hw_vio $vio
    foreach p [get_hw_probes -of_objects $vio] {
        # Output probes carry OUTPUT_VALUE and have no INPUT_VALUE at all, so
        # asking for one aborts the whole dump.
        if {[get_property TYPE $p] eq "vio_output"} {
            puts "PROBE_OUT [get_property NAME $p] = [get_property OUTPUT_VALUE $p]"
        } else {
            puts "PROBE [get_property NAME $p] = [get_property INPUT_VALUE $p]"
        }
    }
}

close_hw_target
disconnect_hw_server
puts "VIO_READ_DONE"
exit 0
