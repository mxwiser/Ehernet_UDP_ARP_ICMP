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

module eth_axis(
	input	wire						sys_rst_n,
	
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

	wire								arp_working;
	wire	[47:0]						pc_mac_addr;
	wire	[31:0]						pc_ip_addr;
	wire	[15:0]						pc_port;
	wire	[15:0]						board_port;

	axis								rx_net();					// PHY RX -> udp_axis_rx
	axis								tx_arp();					// udp_axis_rx ARP reply
	axis								tx_udp();					// udp_axis_tx UDP data
	axis								tx_net();					// muxed TX -> rmii_axis


rmii_axis								u_rmii_axis (
	.rstn								( sys_rst_n			),
	.rmii_clk							( rmii_clk			),
	.rmii_crs_dv						( rmii_rxdv			),
	.rmii_rxdata						( rmii_rxdata		),
	.rmii_txen							( rmii_txen			),
	.rmii_txdata						( rmii_txdata		),
	.rmii_rst							( rmii_rst			),
	.m_rmii_rx_axis_net					( rx_net			),
	.s_rmii_tx_axis_net					( tx_net			)
);

udp_axis_rx								u_udp_axis_rx (
	.sys_clk							( rmii_clk			),
	.sys_rst_n							( sys_rst_n			),
	.s_axis_rx							( rx_net			),
	.m_axis_arp							( tx_arp			),
	.arp_working						( arp_working		),
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

udp_axis_tx								u_udp_axis_tx (
	.sys_clk							( rmii_clk			),
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

// -------------------------------- TX arbitration (ARP first, same as eth_rmii) -------------------
// ARP 应答优先; 若 UDP 帧正在发送则等其发完再切换, 避免 mid-frame 切换导致 rmii_axis 丢弃整帧
// 两个TX的数据打包模块，一个是UDP_RX里面的ARP_TX打包模块，一个是UDP_TX打包模块。
	wire								tx_select_arp;
	assign		tx_select_arp	=	arp_working && !udp_txbusy;

	assign		tx_net.tdata	=	tx_select_arp ? tx_arp.tdata	: tx_udp.tdata;
	assign		tx_net.tvalid	=	tx_select_arp ? tx_arp.tvalid	: tx_udp.tvalid;
	assign		tx_net.tlast	=	tx_select_arp ? tx_arp.tlast	: tx_udp.tlast;
	assign		tx_net.tuser	=	tx_select_arp ? tx_arp.tuser	: tx_udp.tuser;
	assign		tx_arp.tready	=	tx_select_arp ? tx_net.tready	: 1'b0;
	assign		tx_udp.tready	=	tx_select_arp ? 1'b0			: tx_net.tready;

endmodule
