# program_fpga.tcl -- JTAG program the KU040 with a known bitstream + evidence capture
#
# Usage (from repo root):
#   & "C:\Xilinx\Vivado\2022.2\bin\vivado.bat" -mode batch -notrace -source scripts/program_fpga.tcl
#
# Paths are derived from [info script]; NEVER hard-code an absolute repo path here.
# Override the bitstream with either:
#   set ::V08MAC_BIT_FILE <path>        (before sourcing)
#   $env:V08MAC_BIT_FILE = "<path>"     (PowerShell)
#
# Emits BEFORE/AFTER markers so the on-device design identity can be compared
# against the .ltx probe file (see docs/V1.0/V1018).

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]

if {[info exists ::V08MAC_BIT_FILE] && $::V08MAC_BIT_FILE ne ""} {
    set bit_file [file normalize $::V08MAC_BIT_FILE]
} elseif {[info exists ::env(V08MAC_BIT_FILE)] && $::env(V08MAC_BIT_FILE) ne ""} {
    set bit_file [file normalize $::env(V08MAC_BIT_FILE)]
} else {
    set bit_file [file join $repo_root build rle4k_fpga_v08.runs impl_1 rle4k_lan_top.bit]
}
set ltx_file [file rootname $bit_file].ltx

puts "repo_root=$repo_root"
puts "bit_file=$bit_file"

if {![file exists $bit_file]} {
    puts "ERROR: bitstream not found: $bit_file"
    exit 1
}
puts "BIT_MTIME [clock format [file mtime $bit_file] -format {%Y-%m-%d %H:%M:%S}]"
puts "BIT_SIZE  [file size $bit_file]"
if {[file exists $ltx_file]} {
    puts "LTX_PRESENT $ltx_file"
} else {
    puts "LTX_ABSENT $ltx_file"
}

open_hw_manager
connect_hw_server
open_hw_target

set hw_device [lindex [get_hw_devices] 0]
current_hw_device $hw_device
puts "DEVICE $hw_device"

# ---------------- BEFORE ----------------
puts "===== BEFORE ====="
refresh_hw_device -update_hw_probes false $hw_device
if {[catch {puts "BEFORE_DONE [get_property REGISTER.CONFIG_STATUS.BIT_DONE_STATUS $hw_device]"} e]} {
    puts "BEFORE_DONE unavailable ($e)"
}
if {[catch {puts "BEFORE_IDCODE [get_property IDCODE $hw_device]"} e]} {
    puts "BEFORE_IDCODE unavailable"
}
puts "BEFORE_ILA_COUNT [llength [get_hw_ilas -quiet]]"
puts "BEFORE_VIO_COUNT [llength [get_hw_vios -quiet]]"

# ---------------- PROGRAM ----------------
puts "===== PROGRAM ====="
set_property PROGRAM.FILE $bit_file $hw_device
if {[file exists $ltx_file]} {
    set_property PROBES.FILE     $ltx_file $hw_device
    set_property FULL_PROBES.FILE $ltx_file $hw_device
}
if {[catch {program_hw_devices $hw_device} e]} {
    puts "ERROR: program_hw_devices failed: $e"
    exit 1
}
puts "PROGRAMMING COMPLETE"

# ---------------- AFTER ----------------
puts "===== AFTER ====="
refresh_hw_device $hw_device
if {[catch {puts "AFTER_DONE [get_property REGISTER.CONFIG_STATUS.BIT_DONE_STATUS $hw_device]"} e]} {
    puts "AFTER_DONE unavailable ($e)"
}
puts "AFTER_ILA_COUNT [llength [get_hw_ilas -quiet]]"
puts "AFTER_VIO_COUNT [llength [get_hw_vios -quiet]]"
foreach v [get_hw_vios -quiet] { puts "AFTER_VIO $v" }
foreach i [get_hw_ilas -quiet] { puts "AFTER_ILA $i" }

close_hw_target
disconnect_hw_server
close_hw_manager
puts "PROGRAM_SCRIPT_OK"
exit 0
