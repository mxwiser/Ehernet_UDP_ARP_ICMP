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



wire         mac_mii_rxc;
wire         mac_mii_rxdv;
wire         mac_mii_rxer;
wire  [3:0]  mac_mii_rxd;
wire         mac_mii_txc;
wire         mac_mii_txen;
wire         mac_mii_txer;
wire  [3:0]  mac_mii_txd;


rmii_phy_if u_0_rmii_phy_if(
	.rstn_async (sys_rst_n),
	.mode_speed (1'b1),
    // RMII interface connect to PHY
    .phy_rmii_ref_clk (rmii_clk),  // 50MHz required
    .phy_rmii_crsdv   (rmii_crsdv),
    .phy_rmii_rxer    (1'b0),     // rxer is optional for RMII
    .phy_rmii_rxd     (rmii_rxdata),
    .phy_rmii_txen    (rmii_txen),
    .phy_rmii_txd     (rmii_txdata),

	//MII phy
    .mac_mii_rxc    (mac_mii_rxc),
    .mac_mii_rxdv   (mac_mii_rxdv),
    .mac_mii_rxer   (mac_mii_rxer),
    .mac_mii_rxd    (mac_mii_rxd),
    .mac_mii_txc    (mac_mii_txc),
    .mac_mii_txen   (mac_mii_txen),
    .mac_mii_txer   (mac_mii_txer),
    .mac_mii_txd    (mac_mii_txd)

);



eth_mac_mii u0_eth_mac_mii(
	.rst(rst),

    // output wire        rx_clk,
    // output wire        rx_rst,
    // output wire        tx_clk,
    // output wire        tx_rst,



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
     * Configuration
     */
    input  wire [7:0]  cfg_ifg,
    input  wire        cfg_tx_enable,
    input  wire        cfg_rx_enable
);

udp_complete u2_udp_complete(
	.clk(rmii_clk),
	.rst(rst)
);

endmodule