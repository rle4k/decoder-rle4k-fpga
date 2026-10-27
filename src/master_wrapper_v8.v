// ============================================================================
// master_wrapper_v8 -- Raw MAC wrapper (replaces uiudp_stack with mac_proto)
// ============================================================================
// Based on V05 master_wrapper. Retains: Tri-Mode MAC, AXI-Lite SM, VIO,
// all CDC FIFOs and width converters, reset logic.
// Removed: uiudp_stack, IP/PORT/ARP/ICMP configuration ports.
// Added: rle4k_mac_proto_v8 between MAC FIFOs and app interface.
// ============================================================================

`timescale 1ns / 1ps

module master_wrapper_v8 #(
    parameter [47:0] LOCAL_MAC_ADDRESS = 48'h000A35000102
)(
    input                   reset,
    input                   dcm_locked,
    input                   refclk,
    input                   udp_core_clk,
    input                   gtx_clk,
    output                  core_reset,

    // Host-driven PHY reset override. The VIO lives here because this is where
    // the debug core is instantiated; the pin itself is on the top level.
    output                  phy_rst_force,

    // APP interface (to adapter, same signals as uiudp_stack)
    output                  udp_tx_ready,
    output                  app_tx_ack,
    input                   app_rx_ready,
    // Adapter early congestion (S_BLOCK_ASSIGN / lanes-full). Assert PAUSE before
    // the packet FIFO silently drops — do not wait for !m_axis_tready4 alone.
    input                   app_rx_congested,
    input                   app_tx_request,
    input                   app_tx_data_valid,
    input  [63:0]           app_tx_data,
    input  [7:0]            app_tx_data_keep,
    input                   app_tx_data_last,
    input  [15:0]           app_tx_data_length,

    output                  app_rx_data_valid,
    output [63:0]           app_rx_data,
    output [7:0]            app_rx_data_keep,
    output                  app_rx_data_last,
    output [15:0]           app_rx_data_length,

    // RGMII PHY
    input  [3:0]            rgmii_rxd,
    input                   rgmii_rx_ctl,
    input                   rgmii_rxc,
    output [3:0]            rgmii_txd,
    output                  rgmii_tx_ctl,
    output                  rgmii_txc
);

// ============================================================================
// Internal wires: MAC <-> FIFO <-> width converter <-> mac_proto
// ============================================================================

// mac_proto <-> TX CDC FIFO (64-bit, udp_core_clk domain)
wire        proto_tx_valid;
wire [63:0] proto_tx_data;
wire [7:0]  proto_tx_keep;
wire        proto_tx_ready;
wire        proto_tx_last;
wire        proto_tx_user;

// RX packet FIFO -> mac_proto (64-bit, udp_core_clk domain)
wire        proto_rx_valid;
wire [63:0] proto_rx_data;
wire [7:0]  proto_rx_keep;
wire        proto_rx_last;
wire        proto_rx_ready;

// TX async FIFO output (64-bit, tx_mac_aclk domain)
wire        m_axis_tvalid1;
wire [63:0] m_axis_tdata1;
wire [7:0]  m_axis_tkeep1;
wire        m_axis_tready1;
wire        m_axis_tlast1;

// TX packet FIFO output (64-bit, tx_mac_aclk domain)
wire        m_axis_tvalid2;
wire [63:0] m_axis_tdata2;
wire [7:0]  m_axis_tkeep2;
wire        m_axis_tready2;
wire        m_axis_tlast2;

// RX width converter output (64-bit, rx_mac_aclk domain)
wire        m_axis_tvalid3;
wire [63:0] m_axis_tdata3;
wire [7:0]  m_axis_tkeep3;
wire        m_axis_tready3;
wire        m_axis_tlast3;

// RX async FIFO output (64-bit, udp_core_clk domain)
wire        m_axis_tvalid4;
wire [63:0] m_axis_tdata4;
wire [7:0]  m_axis_tkeep4;
wire        m_axis_tready4;
wire        m_axis_tlast4;

// MAC clock domains
wire        rx_mac_aclk;
wire        tx_mac_aclk;

// MAC 8-bit client interface
wire [7:0]  rx_axis_mac_tdata;
wire        rx_axis_mac_tvalid;
wire        rx_axis_mac_tlast;
wire        rx_axis_mac_tuser;

wire [7:0]  tx_axis_mac_tdata;
wire        tx_axis_mac_tvalid;
wire        tx_axis_mac_tready;
wire        tx_axis_mac_tlast;
wire        tx_axis_mac_tuser;

// AXI-Lite interface for MAC config
wire [11:0] s_axi_awaddr;
wire        s_axi_awvalid, s_axi_awready;
wire [31:0] s_axi_wdata;
wire [31:0] s_axi_wdata_mac; // may OR-in Flow Control enables for 0x40C
wire        s_axi_wvalid,  s_axi_wready;
wire [1:0]  s_axi_bresp;
wire        s_axi_bvalid,  s_axi_bready;
wire [11:0] s_axi_araddr;
wire        s_axi_arvalid, s_axi_arready;
wire [31:0] s_axi_rdata;
wire [1:0]  s_axi_rresp;
wire        s_axi_rvalid,  s_axi_rready;

// 802.3x PAUSE (TEMAC client ports; enabled via 0x40C bring-up mux below)
wire        pause_req;
wire [15:0] pause_val;

// Reset signals
wire        tx_reset, rx_reset;
wire        glbl_rst_intn, gtx_resetn, s_axi_resetn;

// MAC per-frame transmit statistics (observability only)
wire [31:0] tx_statistics_vector;
wire        tx_statistics_valid;

// Link status
wire        inband_link_status;
wire [1:0]  inband_clock_speed;
wire        inband_duplex_status;
wire        speedis100, speedis10100;

// ============================================================================
// Datapath instrumentation
// ============================================================================
// Free-running event counters placed at every hand-off in the RX and TX
// chains. They exist purely so the VIO can tell where a frame stops moving;
// nothing in the datapath reads them. Each counter lives in the clock domain
// of the interface it observes and is sampled asynchronously by the VIO,
// which is acceptable because they are read while the link is idle.
reg [15:0] dbg_rx_mac_frames  = 16'd0;  // frames leaving the MAC RX client port
reg [15:0] dbg_rx_mac_err     = 16'd0;  // of those, how many carried tuser at tlast
reg [15:0] dbg_rx_dwc_frames  = 16'd0;  // frames leaving the 8->64 converter
reg [15:0] dbg_proto_rx_frames= 16'd0;  // frames handed to rle4k_mac_proto_v8
reg [15:0] dbg_proto_tx_frames= 16'd0;  // frames accepted from rle4k_mac_proto_v8
reg [15:0] dbg_tx_mac_frames  = 16'd0;  // frames accepted by the MAC TX client port

always @(posedge rx_mac_aclk) begin
    if (rx_axis_mac_tvalid && rx_axis_mac_tlast) begin
        dbg_rx_mac_frames <= dbg_rx_mac_frames + 16'd1;
        if (rx_axis_mac_tuser)
            dbg_rx_mac_err <= dbg_rx_mac_err + 16'd1;
    end
    if (m_axis_tvalid3 && m_axis_tready3 && m_axis_tlast3)
        dbg_rx_dwc_frames <= dbg_rx_dwc_frames + 16'd1;
end

always @(posedge udp_core_clk) begin
    // Must qualify with ready: now that mac_proto back-pressures, tlast can sit
    // asserted for many cycles while the beat waits, and counting valid alone
    // turns one frame into a large number. That is what made this probe read 57
    // for 5 transmitted requests.
    if (proto_rx_valid && proto_rx_ready && proto_rx_last)
        dbg_proto_rx_frames <= dbg_proto_rx_frames + 16'd1;
    if (proto_tx_valid && proto_tx_ready && proto_tx_last)
        dbg_proto_tx_frames <= dbg_proto_tx_frames + 16'd1;
end

always @(posedge tx_mac_aclk) begin
    if (tx_axis_mac_tvalid && tx_axis_mac_tready && tx_axis_mac_tlast)
        dbg_tx_mac_frames <= dbg_tx_mac_frames + 16'd1;
end

// The MAC reports one statistics vector per frame it actually puts on the wire,
// so this counter separates "the MAC swallowed the frame" from "the MAC
// transmitted it and something downstream lost it". The vector itself carries
// the transmitted length and the underrun/deferral flags.
reg [15:0] dbg_tx_stat_cnt = 16'd0;
reg [31:0] dbg_tx_stat_vec = 32'd0;

always @(posedge tx_mac_aclk) begin
    if (tx_statistics_valid) begin
        dbg_tx_stat_cnt <= dbg_tx_stat_cnt + 16'd1;
        dbg_tx_stat_vec <= tx_statistics_vector;
    end
end

// First beat of the most recent outbound frame. On this protocol that word is
// the start of the Ethernet header, so it shows the destination MAC the board
// is actually replying to.
reg [63:0] dbg_tx_first_word = 64'd0;
reg        dbg_tx_in_frame   = 1'b0;

always @(posedge udp_core_clk) begin
    if (proto_tx_valid && proto_tx_ready) begin
        if (!dbg_tx_in_frame) begin
            dbg_tx_first_word <= proto_tx_data;
            dbg_tx_in_frame   <= 1'b1;
        end
        if (proto_tx_last)
            dbg_tx_in_frame <= 1'b0;
    end
end

// The AXI-Lite bring-up sequencer is a vendor block with no status output, so
// track its progress from the bus itself: a stalled sequencer shows a frozen
// write count together with the address it is parked on.
reg [7:0]  dbg_axi_wr_cnt   = 8'd0;
reg [11:0] dbg_axi_last_addr = 12'd0;

always @(posedge gtx_clk) begin
    if (s_axi_awvalid && s_axi_awready)
        dbg_axi_last_addr <= s_axi_awaddr;
    if (s_axi_bvalid && s_axi_bready)
        dbg_axi_wr_cnt <= dbg_axi_wr_cnt + 8'd1;
end

// ============================================================================
// VIO (link status + datapath debug)
// ============================================================================
vio_0 vio_0 (
    .clk       (gtx_clk),
    .probe_in0 (inband_link_status),
    .probe_in1 (inband_clock_speed),
    .probe_in2 (inband_duplex_status),
    .probe_in3 (speedis100),
    .probe_in4 (speedis10100),
    .probe_in5 (dbg_rx_mac_frames),
    .probe_in6 (dbg_rx_mac_err),
    .probe_in7 (dbg_rx_dwc_frames),
    .probe_in8 (dbg_proto_rx_frames),
    .probe_in9 (dbg_proto_tx_frames),
    .probe_in10(dbg_tx_mac_frames),
    .probe_in11(dbg_axi_wr_cnt),
    .probe_in12(dbg_axi_last_addr),
    .probe_in13({core_reset, gtx_resetn, s_axi_resetn}),
    .probe_in14(dbg_tx_stat_cnt),
    .probe_in15(dbg_tx_stat_vec),
    .probe_in16(dbg_tx_first_word),
    .probe_out0(phy_rst_force)
);

// ============================================================================
// Reset logic
// ============================================================================
tri_mode_ethernet_mac_0_example_design_resets example_resets (
    .s_axi_aclk    (gtx_clk),
    .gtx_clk       (gtx_clk),
    .core_clk      (udp_core_clk),
    .glbl_rst      (reset),
    .reset_error   (1'b0),
    .rx_reset      (rx_reset),
    .tx_reset      (tx_reset),
    .dcm_locked    (dcm_locked),
    .glbl_rst_intn (glbl_rst_intn),
    .gtx_resetn    (gtx_resetn),
    .s_axi_resetn  (s_axi_resetn),
    .phy_resetn    (),
    .chk_resetn    (),
    .core_reset    (core_reset)
);

// ============================================================================
// MAC Protocol (replaces uiudp_stack)
// ============================================================================
// udp_tx_ready is the adapter's transmit back-pressure. It used to be tied high,
// which is what let the adapter keep producing into a full FIFO.
rle4k_mac_proto_v8 #(
    .LOCAL_MAC (LOCAL_MAC_ADDRESS)
) u_mac_proto (
    .clk               (udp_core_clk),
    .rst               (core_reset),

    // MAC RX (from rx_packet_fifo)
    .mac_rx_data_valid  (proto_rx_valid),
    .mac_rx_data        (proto_rx_data),
    .mac_rx_keep        (proto_rx_keep),
    .mac_rx_last        (proto_rx_last),
    .mac_rx_ready       (proto_rx_ready),

    // MAC TX (to tx_async_fifo)
    .mac_tx_data_valid  (proto_tx_valid),
    .mac_tx_data        (proto_tx_data),
    .mac_tx_keep        (proto_tx_keep),
    .mac_tx_ready       (proto_tx_ready),
    .mac_tx_last        (proto_tx_last),
    .mac_tx_user        (proto_tx_user),

    // APP RX (to adapter)
    .app_rx_data_valid  (app_rx_data_valid),
    .app_rx_data        (app_rx_data),
    .app_rx_data_keep   (app_rx_data_keep),
    .app_rx_data_last   (app_rx_data_last),
    .app_rx_data_length (app_rx_data_length),
    .app_rx_ready       (app_rx_ready),

    // APP TX (from adapter)
    .app_tx_ready       (udp_tx_ready),
    .app_tx_ack         (app_tx_ack),
    .app_tx_request     (app_tx_request),
    .app_tx_data_valid  (app_tx_data_valid),
    .app_tx_data        (app_tx_data),
    .app_tx_data_keep   (app_tx_data_keep),
    .app_tx_data_last   (app_tx_data_last),
    .app_tx_data_length (app_tx_data_length)
);

// ============================================================================
// TX path: mac_proto -> CDC FIFO -> packet FIFO -> 64-to-8 converter -> MAC
// ============================================================================
axis_data_fifo_1 tx_async_fifo0 (
    .s_axis_aresetn (~core_reset),
    .s_axis_aclk    (udp_core_clk),
    .s_axis_tvalid  (proto_tx_valid),
    .s_axis_tready  (proto_tx_ready),
    .s_axis_tdata   (proto_tx_data),
    .s_axis_tkeep   (proto_tx_keep),
    .s_axis_tlast   (proto_tx_last),
    .s_axis_tuser   (1'b0),
    .m_axis_aclk    (tx_mac_aclk),
    .m_axis_tvalid  (m_axis_tvalid1),
    .m_axis_tready  (m_axis_tready1),
    .m_axis_tdata   (m_axis_tdata1),
    .m_axis_tkeep   (m_axis_tkeep1),
    .m_axis_tlast   (m_axis_tlast1),
    .m_axis_tuser   ()
);

axis_data_fifo_0 tx_packet_fifo0 (
    .s_axis_aresetn (gtx_resetn),
    .s_axis_aclk    (tx_mac_aclk),
    .s_axis_tvalid  (m_axis_tvalid1),
    .s_axis_tready  (m_axis_tready1),
    .s_axis_tdata   (m_axis_tdata1),
    .s_axis_tkeep   (m_axis_tkeep1),
    .s_axis_tlast   (m_axis_tlast1),
    .s_axis_tuser   (1'b0),
    .m_axis_tvalid  (m_axis_tvalid2),
    .m_axis_tready  (m_axis_tready2),
    .m_axis_tdata   (m_axis_tdata2),
    .m_axis_tkeep   (m_axis_tkeep2),
    .m_axis_tlast   (m_axis_tlast2),
    .m_axis_tuser   ()
);

axis_dwidth_converter_0 tx_axis_dwidth_converter0 (
    .aclk           (tx_mac_aclk),
    .aresetn        (gtx_resetn),
    .s_axis_tvalid  (m_axis_tvalid2),
    .s_axis_tready  (m_axis_tready2),
    .s_axis_tdata   (m_axis_tdata2),
    .s_axis_tkeep   (m_axis_tkeep2),
    .s_axis_tlast   (m_axis_tlast2),
    .m_axis_tvalid  (tx_axis_mac_tvalid),
    .m_axis_tready  (tx_axis_mac_tready),
    .m_axis_tdata   (tx_axis_mac_tdata),
    .m_axis_tkeep   (),
    .m_axis_tlast   (tx_axis_mac_tlast)
);

// ============================================================================
// RX path: MAC -> 8-to-64 converter -> CDC FIFO -> packet FIFO -> mac_proto
// ============================================================================
// TEMAC RX client has no tready (firehose). Tie DWC s_axis_tready so the
// converter can refuse when the async FIFO backs up; OR that into PAUSE so the
// peer stops before silent drops at this boundary.
wire        rx_dwc_s_axis_tready;

axis_dwidth_converter_1 rx_axis_dwidth_converter0 (
    .aclk           (rx_mac_aclk),
    .aresetn        (gtx_resetn),
    .s_axis_tvalid  (rx_axis_mac_tvalid),
    .s_axis_tready  (rx_dwc_s_axis_tready),
    .s_axis_tdata   (rx_axis_mac_tdata),
    .s_axis_tkeep   (1'b1),
    .s_axis_tlast   (rx_axis_mac_tlast),
    .m_axis_tvalid  (m_axis_tvalid3),
    .m_axis_tready  (m_axis_tready3),
    .m_axis_tdata   (m_axis_tdata3),
    .m_axis_tkeep   (m_axis_tkeep3),
    .m_axis_tlast   (m_axis_tlast3)
);

axis_data_fifo_1 rx_async_fifo0 (
    .s_axis_aresetn (gtx_resetn),
    .s_axis_aclk    (rx_mac_aclk),
    .s_axis_tvalid  (m_axis_tvalid3),
    .s_axis_tready  (m_axis_tready3),
    .s_axis_tdata   (m_axis_tdata3),
    .s_axis_tkeep   (m_axis_tkeep3),
    .s_axis_tlast   (m_axis_tlast3),
    .s_axis_tuser   (1'b0),
    .m_axis_aclk    (udp_core_clk),
    .m_axis_tvalid  (m_axis_tvalid4),
    .m_axis_tready  (m_axis_tready4),
    .m_axis_tdata   (m_axis_tdata4),
    .m_axis_tkeep   (m_axis_tkeep4),
    .m_axis_tlast   (m_axis_tlast4),
    .m_axis_tuser   ()
);

axis_data_fifo_0 rx_packet_fifo0 (
    .s_axis_aresetn (~core_reset),
    .s_axis_aclk    (udp_core_clk),
    .s_axis_tvalid  (m_axis_tvalid4),
    .s_axis_tready  (m_axis_tready4),
    .s_axis_tdata   (m_axis_tdata4),
    .s_axis_tkeep   (m_axis_tkeep4),
    .s_axis_tlast   (m_axis_tlast4),
    .s_axis_tuser   (1'b0),
    .m_axis_tvalid  (proto_rx_valid),
    .m_axis_tready  (proto_rx_ready),
    .m_axis_tdata   (proto_rx_data),
    .m_axis_tkeep   (proto_rx_keep),
    .m_axis_tlast   (proto_rx_last),
    .m_axis_tuser   ()
);

// ============================================================================
// Tri-Mode Ethernet MAC
// ============================================================================
tri_mode_ethernet_mac_0 tri_mode_ethernet_mac_i (
    .gtx_clk              (gtx_clk),
    .refclk               (refclk),
    .glbl_rstn            (glbl_rst_intn),
    .rx_axi_rstn          (1'b1),
    .tx_axi_rstn          (1'b1),

    .rx_statistics_vector  (),
    .rx_statistics_valid   (),
    .rx_mac_aclk           (rx_mac_aclk),
    .rx_reset              (rx_reset),
    .rx_axis_mac_tdata     (rx_axis_mac_tdata),
    .rx_axis_mac_tvalid    (rx_axis_mac_tvalid),
    .rx_axis_mac_tlast     (rx_axis_mac_tlast),
    .rx_axis_mac_tuser     (rx_axis_mac_tuser),

    .tx_ifg_delay          (8'd0),
    .tx_statistics_vector  (tx_statistics_vector),
    .tx_statistics_valid   (tx_statistics_valid),
    .tx_mac_aclk           (tx_mac_aclk),
    .tx_reset              (tx_reset),
    .tx_axis_mac_tdata     (tx_axis_mac_tdata),
    .tx_axis_mac_tvalid    (tx_axis_mac_tvalid),
    .tx_axis_mac_tlast     (tx_axis_mac_tlast),
    .tx_axis_mac_tuser     (1'b0),
    .tx_axis_mac_tready    (tx_axis_mac_tready),

    .pause_req             (pause_req),
    .pause_val             (pause_val),

    .speedis100            (speedis100),
    .speedis10100          (speedis10100),

    .rgmii_txd             (rgmii_txd),
    .rgmii_tx_ctl          (rgmii_tx_ctl),
    .rgmii_txc             (rgmii_txc),
    .rgmii_rxd             (rgmii_rxd),
    .rgmii_rx_ctl          (rgmii_rx_ctl),
    .rgmii_rxc             (rgmii_rxc),
    .inband_link_status    (inband_link_status),
    .inband_clock_speed    (inband_clock_speed),
    .inband_duplex_status  (inband_duplex_status),

    .s_axi_aclk            (gtx_clk),
    .s_axi_resetn          (s_axi_resetn),
    .s_axi_awaddr          (s_axi_awaddr),
    .s_axi_awvalid         (s_axi_awvalid),
    .s_axi_awready         (s_axi_awready),
    .s_axi_wdata           (s_axi_wdata_mac),
    .s_axi_wvalid          (s_axi_wvalid),
    .s_axi_wready          (s_axi_wready),
    .s_axi_bresp           (s_axi_bresp),
    .s_axi_bvalid          (s_axi_bvalid),
    .s_axi_bready          (s_axi_bready),
    .s_axi_araddr          (s_axi_araddr),
    .s_axi_arvalid         (s_axi_arvalid),
    .s_axi_arready         (s_axi_arready),
    .s_axi_rdata           (s_axi_rdata),
    .s_axi_rresp           (s_axi_rresp),
    .s_axi_rvalid          (s_axi_rvalid),
    .s_axi_rready          (s_axi_rready),
    .mac_irq               ()
);

// ============================================================================
// AXI-Lite Controller (MAC speed/config)
// ============================================================================
// Vendor SM still writes 0 to Flow Control Config (0x40C) at CNFG_FLOW. Do NOT
// edit src/vendor/**; OR-in TX+RX pause enables on that address instead.
// PG051: bit29 = Transmit Flow Control Enable, bit28 = Receive Flow Control Enable.
tri_mode_ethernet_mac_0_axi_lite_sm axi_lite_controller_0 (
    .s_axi_aclk    (gtx_clk),
    .s_axi_resetn  (s_axi_resetn),
    .mac_speed     (2'b10),
    .update_speed  (1'b0),
    .serial_command(1'b0),
    .serial_response(),
    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready)
);

// Sticky / pending Flow-Control write: assert as soon as AWADDR presents 0x40C
// (do not wait for awready). Covers W-before-AW-ready and same-cycle AW+W.
// PG051 0x40C: bit30=TX FC enable (pause_req), bit29=RX FC enable.
reg flow_wr_pending;
always @(posedge gtx_clk) begin
    if (!s_axi_resetn)
        flow_wr_pending <= 1'b0;
    else begin
        if (s_axi_awvalid && (s_axi_awaddr == 12'h40C))
            flow_wr_pending <= 1'b1;
        if (s_axi_wvalid && s_axi_wready && flow_wr_pending)
            flow_wr_pending <= 1'b0;
    end
end

wire flow_cfg_wr =
    (s_axi_awvalid && (s_axi_awaddr == 12'h40C)) || flow_wr_pending;

// Force enables (do not OR with vendor's zero — make the written value unambiguous).
assign s_axi_wdata_mac = flow_cfg_wr ? 32'h6000_0000 : s_axi_wdata;

// ============================================================================
// 802.3x PAUSE backpressure
// ============================================================================
// Early → late: ASSIGN/lanes-full (adapter) → DWC refuse → async FIFO → packet
// FIFO → proto stall with data present. Covering DWC/async stops drops that
// used to happen while !m_axis_tready4 was still 0 (FIFO not yet full).
wire pause_congested =
    app_rx_congested |
    (~rx_dwc_s_axis_tready) |
    (~m_axis_tready3) |
    (~m_axis_tready4) |
    ((~app_rx_ready) & (proto_rx_valid | m_axis_tvalid4));

rle4k_pause_ctrl u_pause_ctrl (
    .tx_clk          (tx_mac_aclk),
    .tx_reset        (tx_reset),
    .congested_async (pause_congested),
    .pause_req       (pause_req),
    .pause_val       (pause_val),
    .congested_sync  ()
);

endmodule
