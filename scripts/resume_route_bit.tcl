# resume_route_bit.tcl — route from placed DCP + write bitstream (OOM recovery)
set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set placed [file join $repo_root build rle4k_fpga_v08.runs impl_1 rle4k_lan_top_placed.dcp]
set outdir [file join $repo_root build rle4k_fpga_v08.runs impl_1]

puts "Opening placed checkpoint: $placed"
open_checkpoint $placed
puts "Routing..."
route_design
puts "Writing bitstream..."
write_bitstream -force [file join $outdir rle4k_lan_top.bit]
if {[llength [get_debug_cores -quiet]] > 0} {
    write_debug_probes -force [file join $outdir rle4k_lan_top.ltx]
}
puts "RESUME_BIT_COMPLETE"
exit 0