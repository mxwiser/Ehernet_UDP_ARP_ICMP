`include "axis.svh"

// author:		Benjamin SMith
// create time:	2023/03/20 11:16
// edit time:	2026/08/05
// platform:	Cyclone ep4ce10f17i7, 野火 board
// module:		eth_axis
// function:	Ethernet communication, including ARP and UDP, IPv4 only
//				renamed from eth_rmii.sv: gmii bus replaced by AXIS (axis.svh),
//				external ports and function unchanged, udp_loop.sv can use it directly
// version:		0.1, test ARP function

module udp(
	input	wire						sys_rst_n,
	input   wire                        sys_clk,
	input	wire						rmii_clk,					// 50 MHz, used as system clock in all bottom modules
	input	wire						rmii_rxdv,
	input	wire	[1:0]				rmii_rxdata,
	output	wire						rmii_txen,
	output	wire	[1:0]				rmii_txdata,
	output	wire						rmii_rst,
	// user port
	output	wire						udp_rxstart,
	output	wire						udp_rxend,
	output	wire						udp_rxdv,
	output	wire	[7:0]				udp_rxdata,
	output	wire	[15:0]				udp_rxamount,				// total amount of data, including all pieces
	output	wire	[15:0]				udp_rxnum,					// the order of the received data in this package



	input	wire						udp_txstart,
	input	wire	[15:0]				udp_txamount,
	input	wire	[7:0]				udp_txdata,
	output	wire						udp_txreq,					// acknowledge that udp_txdata has been transfered
	output	wire						udp_txbusy
);


	wire	[47:0]						pc_mac_addr;
	wire	[31:0]						pc_ip_addr;
	wire	[15:0]						pc_port;
	wire	[15:0]						board_port;

	axis								rx_net();					// PHY RX -> udp_axis_rx
	axis								rx_net_cdc();	
	axis								tx_sys();					// udp_axis_rx ARP reply
	axis								tx_udp();					// udp_axis_tx UDP data
	axis								tx_net();					// muxed TX -> rmii_axis
	axis								tx_phy();

	
	parameter		BOARD_MAC_ADDR			= 48'h51_12_22_33_44_55;
	parameter		BOARD_IP_ADDR			= 32'h0A_0A_01_0A;			// 10.10.1.10




rmii_axis								u_rmii_axis (
	.rstn								( sys_rst_n			),
	.rmii_clk							( rmii_clk			),
	.rmii_crs_dv						( rmii_rxdv			),
	.rmii_rxdata						( rmii_rxdata		),
	.rmii_txen							( rmii_txen			),
	.rmii_txdata						( rmii_txdata		),
	.rmii_rst							( rmii_rst			),
	.m_rmii_rx_axis_net					( rx_net			),
	.s_rmii_tx_axis_net					( tx_phy     		)
);

rx_cdc_fifo_axis u_rx_cdc_fifo_axis(
	.rstn     (sys_rst_n),
	.clk  	  (sys_clk),
	.rmii_clk (rmii_clk),
	.s_rx (rx_net),
	.m_rx (rx_net_cdc)
);

udp_axis_rx#(
	.BOARD_IP_ADDR   (BOARD_IP_ADDR),
	.BOARD_MAC_ADDR  (BOARD_MAC_ADDR)
)
										u_udp_axis_rx (
	.sys_clk							( sys_clk			),
	.sys_rst_n							( sys_rst_n			),
	.s_axis_rx							( rx_net_cdc		),
	.m_axis_tx							( tx_sys			),
	.udp_rxstart						( udp_rxstart		),
	.udp_rxend							( udp_rxend			),
	.udp_rxdv							( udp_rxdv			),
	.udp_rxdata							( udp_rxdata		),
	.udp_rxamount						( udp_rxamount		),
	.udp_rxnum							( udp_rxnum			),
	.pc_mac_addr						( pc_mac_addr		),
	.pc_ip_addr							( pc_ip_addr		),
	.pc_port							( pc_port			),
	.board_port							( board_port		)
);


udp_axis_tx#(	
	.BOARD_IP_ADDR   (BOARD_IP_ADDR),
	.BOARD_MAC_ADDR  (BOARD_MAC_ADDR)
)								
										u_udp_axis_tx (
	.sys_clk							( sys_clk			),
	.sys_rst_n							( sys_rst_n			),
	.m_axis_tx							( tx_udp			),
	.udp_txstart						( udp_txstart		),
	.udp_txamount						( udp_txamount		),
	.udp_txdata							( udp_txdata		),
	.udp_txreq							( udp_txreq			),
	.udp_txbusy							( udp_txbusy		),
	.pc_mac_addr						( pc_mac_addr		),
	.pc_ip_addr							( pc_ip_addr		),
	.pc_port							( pc_port			),
	.board_port							( board_port		)
);




tx_cdc_fifo_axis u_tx_cdc_fifo_axis(
	.clk	 (sys_clk),
	.rstn	 (sys_rst_n),
	.sys_tx  (tx_sys),
	.udp_tx	 (tx_udp),
	.phy_tx  (tx_phy)
);



endmodule
