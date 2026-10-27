`timescale 1ns / 1ps
/*
Company : Liyang Milian Electronic Technology Co., Ltd.
Brand: ������(msxbo)
Technical forum:uisrc.com
taobao: osrc.taobao.com
Create Date: 2019/12/17
Module Name: udp_loop_back
Description: 
Copyright: Copyright (c) msxbo
Revision: 1.0
Signal description:
1) _i input
2) _o output
3) _n activ low
4) _dg debug signal 
5) _r delay or register
6) _s state mechine
*/
//////////////////////////////////////////////////////////////////////////////////

module udp_loop_back(
input          sysclk_p,
input          sysclk_n,
output         phy_rst_o,
//PHYA        
input [3:0]    PHYA_rgmii_rxd,
input          PHYA_rgmii_rx_ctl,
input          PHYA_rgmii_rxc,
output[3:0]    PHYA_rgmii_txd,
output         PHYA_rgmii_tx_ctl,
output         PHYA_rgmii_txc,
//PHYB
input [3:0]    PHYB_rgmii_rxd,
input          PHYB_rgmii_rx_ctl,
input          PHYB_rgmii_rxc,
output[3:0]    PHYB_rgmii_txd,
output         PHYB_rgmii_tx_ctl,
output         PHYB_rgmii_txc
);
	

wire      reset;
wire      locked;

reg [15:0] delay_cnt;
wire     clk_15_625;
wire     clk_333_33;
wire     clk_125;
wire     clk_25;

assign  phy_rst_o = (delay_cnt == 10'd100);

always @(posedge clk_25) begin
   if(!locked) 
         delay_cnt <= 10'd0;
   else begin
		 if(delay_cnt == 10'd100)
			delay_cnt <= delay_cnt;
		 else
		    delay_cnt <= delay_cnt + 1'b1;
   end
end

clk_wiz_0 clk_wiz_0(
.clk_in1_p  (sysclk_p), 
.clk_in1_n  (sysclk_n), 
.clk_out1   (clk_15_625), 
.clk_out2   (clk_333_33),
.clk_out3   (clk_125),		
.clk_out4   (clk_25),		  
.locked     (locked));


master_ch  cha_inst
(
.reset        (1'b0),
.dcm_locked   (locked),

.clk_15_625   (clk_15_625),
.clk_125      (clk_125), 
.clk_ref      (clk_333_33),

  
.rgmii_rxd    (PHYA_rgmii_rxd),
.rgmii_rx_ctl (PHYA_rgmii_rx_ctl),
.rgmii_rxc    (PHYA_rgmii_rxc),
        
.rgmii_txd    (PHYA_rgmii_txd),
.rgmii_tx_ctl (PHYA_rgmii_tx_ctl),
.rgmii_txc    (PHYA_rgmii_txc)                          
);

slave_ch  chb_inst
(
.reset        (1'b0),
.dcm_locked   (locked),

.clk_15_625   (clk_15_625),
.clk_125      (clk_125), 
.clk_ref      (clk_333_33),

   
.rgmii_rxd    (PHYB_rgmii_rxd),
.rgmii_rx_ctl (PHYB_rgmii_rx_ctl),
.rgmii_rxc    (PHYB_rgmii_rxc),
        
.rgmii_txd    (PHYB_rgmii_txd),
.rgmii_tx_ctl (PHYB_rgmii_tx_ctl),
.rgmii_txc    (PHYB_rgmii_txc)                          
);    


endmodule
