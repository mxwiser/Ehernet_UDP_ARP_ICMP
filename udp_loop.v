// author:		Benjamin SMith
// create time:	2023/03/22 11:07
// edit time:	2023/03/22 16:21
// platform:	Cyclone ep4ce10f17i7, 野火 board
// module:		udp_loop
// function:	UDP loop, transform information back to server
// version:		1.0
// history:	

module udp_loop (
	input	wire						sys_rst_n,
	
	input	wire						rmii_clk,
	input	wire						rmii_crsdv,
	input	wire	[1:0]				rmii_rxdata,
	output	wire						rmii_txen,
	output	wire	[1:0]				rmii_txdata,
	output	wire						rmii_rst
);
wire rst;
assign rst = !sys_rst_n;
eth_mac_mii u0_eth_mac_mii(
	.rst(rst),

    // output wire        rx_clk,
    // output wire        rx_rst,
    // output wire        tx_clk,
    // output wire        tx_rst,

    /*
     * AXI input
     */
    input  wire [7:0]  tx_axis_tdata,
    input  wire        tx_axis_tvalid,
    output wire        tx_axis_tready,
    input  wire        tx_axis_tlast,
    input  wire        tx_axis_tuser,

    /*
     * AXI output
     */
    output wire [7:0]  rx_axis_tdata,
    output wire        rx_axis_tvalid,
    output wire        rx_axis_tlast,
    output wire        rx_axis_tuser,

    /*
     * MII interface
     */
    input  wire        mii_rx_clk,
    input  wire [3:0]  mii_rxd,
    input  wire        mii_rx_dv,
    input  wire        mii_rx_er,
    input  wire        mii_tx_clk,
    output wire [3:0]  mii_txd,
    output wire        mii_tx_en,
    output wire        mii_tx_er,

    /*
     * Status
     */
    output wire        tx_start_packet,
    output wire        tx_error_underflow,
    output wire        rx_start_packet,
    output wire        rx_error_bad_frame,
    output wire        rx_error_bad_fcs,

    /*
     * Configuration
     */
    input  wire [7:0]  cfg_ifg,
    input  wire        cfg_tx_enable,
    input  wire        cfg_rx_enable
);

udp_complete u1_udp_complete(
	.clk(rmii_clk),
	.rst(rst)
);

endmodule