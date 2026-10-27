# run_sim_block_gate.tcl -- V08LAN block-level simulation gate (Phase 3)
# Usage: vivado -mode batch -notrace -source scripts/run_sim_block_gate.tcl
#
# Currently chains: tb_decoder_crc (multi-block strip + CRC + block_done/strip_end asserts).
# Optional future: aligned tb_rle4k_decoder_core_batch_* once ported.

puts "================================================================"
puts " V08LAN run_sim_block_gate - decoder strip / block regression"
puts "================================================================"

set ::V08LAN_SKIP_SIM_CRC_EXIT 1
set _gate_script [file join [file dirname [file normalize [info script]]] run_sim_crc.tcl]
source $_gate_script

puts "=== Block gate: tb_decoder_crc PASS (exit delegated to host) ==="
exit 0
