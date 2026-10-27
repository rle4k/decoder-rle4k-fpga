# create_project_2022_2.tcl -- rebuild the V08MAC Vivado project from source.
#
# The original build/ tree (project + IP + known-good bitstream) was lost, and the
# project had been authored with Vivado 2025.1 which is not installed. This script
# recreates everything from the checked-in RTL/XDC using the daily toolchain 2022.2.
#
# Usage (from repo root):
#   & "C:\Xilinx\Vivado\2022.2\bin\vivado.bat" -mode batch -notrace \
#       -source scripts/create_project_2022_2.tcl
#
# Optional -tclargs:
#   -force        delete an existing build/rle4k_fpga_v08.xpr first
#   -probe-only   create project + IP, dump IP port templates, then stop

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set build_dir  [file join $repo_root build]
set proj_name  rle4k_fpga_v08
set part       xcku040-ffva1156-2-i

set opt_force 0
set opt_probe_only 0
foreach a $argv {
    switch -- $a {
        -force      { set opt_force 1 }
        -probe-only { set opt_probe_only 1 }
    }
}

proc pline {s} { puts "@@ $s" }

set xpr [file join $build_dir $proj_name.xpr]
if {[file exists $xpr]} {
    if {$opt_force} {
        pline "removing existing project $xpr"
        file delete -force [file join $build_dir $proj_name.xpr]
        file delete -force [file join $build_dir $proj_name.srcs]
        file delete -force [file join $build_dir $proj_name.gen]
        file delete -force [file join $build_dir $proj_name.runs]
        file delete -force [file join $build_dir $proj_name.cache]
        file delete -force [file join $build_dir $proj_name.hw]
        file delete -force [file join $build_dir $proj_name.ip_user_files]
        file delete -force [file join $build_dir $proj_name.sim]
        # The IP output directory is not part of the project tree, so leaving it
        # behind makes create_ip disambiguate into <name>_1 and keep the stale
        # <name> alongside it. The project then builds from one config while the
        # obvious-looking directory on disk still shows the old one -- which is
        # exactly how a MAC_Speed change appeared not to have taken effect.
        file delete -force [file join $build_dir ip]
    } else {
        pline "FATAL project already exists: $xpr (pass -tclargs -force to recreate)"
        exit 1
    }
}

file mkdir $build_dir
create_project $proj_name $build_dir -part $part -force
set_property target_language Verilog [current_project]
pline "PROJECT_CREATED $xpr part=$part"

# ---------------------------------------------------------------------------
# RTL sources. src/vendor/uisrc/01_rtl holds the Milianke reference design; only
# the TEMAC support blocks that master_wrapper_v8 actually instantiates are used.
# ---------------------------------------------------------------------------
set rtl_files [list \
    [file join $repo_root src rle4k_lan_top_v8.v] \
    [file join $repo_root src rle4k_phy_reset.v] \
    [file join $repo_root src master_wrapper_v8.v] \
    [file join $repo_root src rle4k_pause_ctrl.v] \
    [file join $repo_root src rle4k_mac_proto_v8.v] \
    [file join $repo_root src rle4k_stream_adapter_v8.v] \
    [file join $repo_root src rle4k_cdc_fifo_36.v] \
    [file join $repo_root src rle4k_sync_fifo_36.v] \
    [file join $repo_root src rle4k_ring_window.v] \
    [file join $repo_root src rle4k_lane_pipe_v8.v] \
    [file join $repo_root src rle4k_parallel_bank_v8.v] \
    [file join $repo_root src rle4k_decoder_core.v] \
    [file join $repo_root src rle4k_decoder_code_parser.v] \
    [file join $repo_root src rle4k_decoder_mask_lut.v] \
    [file join $repo_root src rle4k_decoder_mask_tables.v] \
    [file join $repo_root src decoder_output_accumulator.v] \
    [file join $repo_root src vendor uisrc 01_rtl tri_mode_ethernet_mac_0_axi_lite_sm.v] \
    [file join $repo_root src vendor uisrc 01_rtl tri_mode_ethernet_mac_0_example_design_resets.v] \
    [file join $repo_root src vendor uisrc 01_rtl tri_mode_ethernet_mac_0_reset_sync.v] \
    [file join $repo_root src vendor uisrc 01_rtl tri_mode_ethernet_mac_0_sync_block.v] \
]
foreach f $rtl_files {
    if {![file exists $f]} { pline "FATAL missing RTL source: $f"; exit 1 }
}
add_files -norecurse -fileset sources_1 $rtl_files
set_property top rle4k_lan_top [get_filesets sources_1]
pline "RTL_ADDED [llength $rtl_files] files, top=rle4k_lan_top"

# ---------------------------------------------------------------------------
# Constraints. constrs/rle4k_lan_top.xdc is a TEMPLATE with wrong pins for this
# board and is deliberately NOT added; src/vendor/.../fpga_pin.xdc carries PHYB
# ports that do not exist on this top level plus an illegal AK14 LED pin.
# rle4k_lan_top_ku040.xdc is the single authoritative constraint file.
# ---------------------------------------------------------------------------
set xdc [file join $repo_root constrs rle4k_lan_top_ku040.xdc]
if {![file exists $xdc]} { pline "FATAL missing constraints: $xdc"; exit 1 }
add_files -fileset constrs_1 -norecurse $xdc
pline "XDC_ADDED $xdc"

# CDC groups reference clocks that only exist after the out-of-context IP is
# linked, so this half of the constraints is implementation-only.
set xdc_timing [file join $repo_root constrs rle4k_lan_top_ku040_timing.xdc]
if {![file exists $xdc_timing]} { pline "FATAL missing constraints: $xdc_timing"; exit 1 }
add_files -fileset constrs_1 -norecurse $xdc_timing
set_property used_in_synthesis false [get_files $xdc_timing]
pline "XDC_ADDED $xdc_timing (implementation only)"

# ---------------------------------------------------------------------------
# IP. Port lists below must match the instantiations in master_wrapper_v8.v and
# rle4k_lan_top_v8.v; run with -probe-only to dump the generated templates.
# ---------------------------------------------------------------------------
set ip_dir [file join $build_dir ip]
file mkdir $ip_dir

proc mk_ip {name vlnv_name vlnv_ver cfg} {
    global ip_dir
    pline "IP_CREATE $name"
    create_ip -name $vlnv_name -vendor xilinx.com -library ip -version $vlnv_ver \
        -module_name $name -dir $ip_dir
    if {[llength $cfg] > 0} {
        set_property -dict $cfg [get_ips $name]
    }
}

# 100 MHz LVDS reference in; x10 => VCO 1000 MHz => /64, /3, /8, /40.
#
# The board clock is 100 MHz, not 200. Telling the wizard 200 does not fail
# loudly: it picks a x5 multiplier, the MMCM still locks (VCO lands at 500 MHz,
# comfortably in range) and every output comes out at exactly half frequency --
# gtx_clk at 62.5 MHz instead of 125. RGMII_TXC then runs at half rate, so the
# PHY never sees a valid gigabit transmit clock and nothing reaches the wire,
# while receive keeps working because it is clocked by the PHY's recovered RXC.
# That is the whole "board is silent on transmit" regression. See reports/
# 2026-08-08-tx-regression-bisect.md.
mk_ip clk_wiz_0 clk_wiz 6.0 [list \
    CONFIG.PRIM_SOURCE {Differential_clock_capable_pin} \
    CONFIG.PRIM_IN_FREQ {100.000} \
    CONFIG.CLKIN1_JITTER_PS {100.0} \
    CONFIG.USE_PHASE_ALIGNMENT {true} \
    CONFIG.CLKOUT1_USED {true} \
    CONFIG.CLKOUT2_USED {true} \
    CONFIG.CLKOUT3_USED {true} \
    CONFIG.CLKOUT4_USED {true} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {15.625} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {333.333} \
    CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {125.000} \
    CONFIG.CLKOUT4_REQUESTED_OUT_FREQ {25.000} \
    CONFIG.USE_LOCKED {true} \
    CONFIG.USE_RESET {false} \
]

# TEMAC: RGMII, gigabit-only, AXI-Lite management (driven by
# tri_mode_ethernet_mac_0_axi_lite_sm), no MDIO, no frame filter.
#
# MAC_Speed must stay 1000_Mbps. The recovered 2026-04-27 design that works on
# this board was built that way, and Tri_speed generates a different RGMII
# transmit structure whose speed comes from AXI-Lite register 0x410 at runtime
# rather than being fixed at elaboration. Management_Frequency is pinned to the
# same 125 MHz the working design used rather than the IP's 150 MHz default.
# SupportLevel 1 = shared logic inside the core; that is what exposes the `refclk`
# IDELAYCTRL reference input which master_wrapper_v8 drives from the 333.33 MHz clock.
mk_ip tri_mode_ethernet_mac_0 tri_mode_ethernet_mac 9.0 [list \
    CONFIG.Physical_Interface {RGMII} \
    CONFIG.MAC_Speed {1000_Mbps} \
    CONFIG.Management_Frequency {125} \
    CONFIG.SupportLevel {1} \
    CONFIG.Management_Interface {true} \
    CONFIG.Enable_MDIO {false} \
    CONFIG.Frame_Filter {false} \
    CONFIG.Number_of_Table_Entries {0} \
    CONFIG.Statistics_Counters {false} \
    CONFIG.Half_Duplex {false} \
]

# 64-bit AXI-Stream, tkeep + tlast + 1-bit tuser.
#
# FIFO_DEPTH 8192 (64 KB) is an RX requirement, not a round number: the RX chain has
# no backpressure to the MAC (rx_axis_dwidth_converter0.s_axis_tready is unconnected),
# so anything that does not fit is dropped on the floor. The largest block in the
# reference set is 53,524 B on the wire, and the sender can now deliver a block at
# line rate, so a stage that cannot hold a whole block loses frames even when the
# average rate is comfortable. 2048 (16 KB) held less than a third of one.
mk_ip axis_data_fifo_0 axis_data_fifo 2.0 [list \
    CONFIG.TDATA_NUM_BYTES {8} \
    CONFIG.TUSER_WIDTH {1} \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
    CONFIG.FIFO_DEPTH {8192} \
    CONFIG.FIFO_MODE {2} \
    CONFIG.IS_ACLK_ASYNC {0} \
]

mk_ip axis_data_fifo_1 axis_data_fifo 2.0 [list \
    CONFIG.TDATA_NUM_BYTES {8} \
    CONFIG.TUSER_WIDTH {1} \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
    CONFIG.FIFO_DEPTH {8192} \
    CONFIG.FIFO_MODE {1} \
    CONFIG.IS_ACLK_ASYNC {1} \
]

# 64 -> 8 (application to MAC TX client).
mk_ip axis_dwidth_converter_0 axis_dwidth_converter 1.1 [list \
    CONFIG.S_TDATA_NUM_BYTES {8} \
    CONFIG.M_TDATA_NUM_BYTES {1} \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
]

# 8 -> 64 (MAC RX client to application).
mk_ip axis_dwidth_converter_1 axis_dwidth_converter 1.1 [list \
    CONFIG.S_TDATA_NUM_BYTES {1} \
    CONFIG.M_TDATA_NUM_BYTES {8} \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
]

# Probes 0-4 are the RGMII inband link status; 5-13 are the datapath and
# AXI-Lite bring-up counters declared in master_wrapper_v8.v.
mk_ip vio_0 vio 3.0 [list \
    CONFIG.C_NUM_PROBE_IN {17} \
    CONFIG.C_NUM_PROBE_OUT {1} \
    CONFIG.C_PROBE_OUT0_WIDTH {1} \
    CONFIG.C_PROBE_OUT0_INIT_VAL {0x0} \
    CONFIG.C_PROBE_IN0_WIDTH {1} \
    CONFIG.C_PROBE_IN1_WIDTH {2} \
    CONFIG.C_PROBE_IN2_WIDTH {1} \
    CONFIG.C_PROBE_IN3_WIDTH {1} \
    CONFIG.C_PROBE_IN4_WIDTH {1} \
    CONFIG.C_PROBE_IN5_WIDTH {16} \
    CONFIG.C_PROBE_IN6_WIDTH {16} \
    CONFIG.C_PROBE_IN7_WIDTH {16} \
    CONFIG.C_PROBE_IN8_WIDTH {16} \
    CONFIG.C_PROBE_IN9_WIDTH {16} \
    CONFIG.C_PROBE_IN10_WIDTH {16} \
    CONFIG.C_PROBE_IN11_WIDTH {8} \
    CONFIG.C_PROBE_IN12_WIDTH {12} \
    CONFIG.C_PROBE_IN13_WIDTH {3} \
    CONFIG.C_PROBE_IN14_WIDTH {16} \
    CONFIG.C_PROBE_IN15_WIDTH {32} \
    CONFIG.C_PROBE_IN16_WIDTH {64} \
]

# Decode-tail ILA (rle4k_lan_top_v8.v). Observation only; the known-good baseline has
# 0 ILA + 1 VIO, so a JTAG scan reporting 1 ILA is how you tell the two apart.
mk_ip ila_0 ila 6.2 [list \
    CONFIG.C_NUM_OF_PROBES {18} \
    CONFIG.C_DATA_DEPTH {8192} \
    CONFIG.C_ADV_TRIGGER {true} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {2} \
    CONFIG.C_PROBE0_WIDTH {32} \
    CONFIG.C_PROBE1_WIDTH {32} \
    CONFIG.C_PROBE2_WIDTH {16} \
    CONFIG.C_PROBE3_WIDTH {16} \
    CONFIG.C_PROBE4_WIDTH {10} \
    CONFIG.C_PROBE5_WIDTH {1} \
    CONFIG.C_PROBE6_WIDTH {1} \
    CONFIG.C_PROBE7_WIDTH {1} \
    CONFIG.C_PROBE8_WIDTH {1} \
    CONFIG.C_PROBE9_WIDTH {1} \
    CONFIG.C_PROBE10_WIDTH {1} \
    CONFIG.C_PROBE11_WIDTH {1} \
    CONFIG.C_PROBE12_WIDTH {1} \
    CONFIG.C_PROBE13_WIDTH {1} \
    CONFIG.C_PROBE14_WIDTH {1} \
    CONFIG.C_PROBE15_WIDTH {1} \
    CONFIG.C_PROBE16_WIDTH {1} \
    CONFIG.C_PROBE17_WIDTH {32} \
]

set all_ips [get_ips]
pline "IP_LIST $all_ips"

foreach ip $all_ips {
    generate_target {instantiation_template} [get_files [get_property IP_FILE $ip]]
}

# Dump the generated instantiation templates so port lists can be diffed against
# the hand-written instantiations before spending time on synthesis.
foreach ip $all_ips {
    set veo [file join $ip_dir $ip $ip.veo]
    pline "---- TEMPLATE $ip ----"
    if {[file exists $veo]} {
        set fh [open $veo r]
        puts [read $fh]
        close $fh
    } else {
        pline "  (no .veo at $veo)"
    }
    pline "---- END TEMPLATE $ip ----"
}

if {$opt_probe_only} {
    pline "PROBE_ONLY_DONE"
    close_project
    exit 0
}

foreach ip $all_ips {
    pline "IP_GENERATE $ip"
    generate_target all [get_files [get_property IP_FILE $ip]]
}

update_compile_order -fileset sources_1
pline "PROJECT_READY"
close_project
exit 0
