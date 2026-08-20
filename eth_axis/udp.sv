`include "axis.svh"
`include "pc_head.svh"


module udp(
	input	wire						sys_rst_n,
	input   wire                        sys_clk,

	// Runtime board address configuration. Assert board_addr_cfg_valid for one
	// sys_clk cycle; MAC and IP are updated atomically on that rising edge.
	input	wire						board_addr_cfg_valid,
	input	wire	[47:0]				board_mac_addr_cfg,
	input	wire	[31:0]				board_ip_addr_cfg,

	// phy  port
	axis							    m_phy_rx,
	axis							    s_phy_tx,
	input								rx_clk,
	input								tx_clk,
	// user port
	output	wire						udp_rxstart,
	output	wire						udp_rxend,       // not include paddding
	output	wire						udp_rxframe_done,// when padding fifo out.  
	output	wire						udp_rxdv,
	output	wire	[7:0]				udp_rxdata,
	output	wire	[15:0]				udp_rxamount,				// total amount of data, including all pieces
	output	wire	[15:0]				udp_rxnum,					// the order of the received data in this package
	pc_head.master						udp_rx_head,

	//txstart开始前需要确保pc_mac_addr，pc_ip_addr，pc_port，board_port稳定.
	input	wire						udp_txstart,
	input	wire	[15:0]				udp_txamount,
	input	wire	[7:0]				udp_txdata,
	output	wire						udp_txreq,					// acknowledge that udp_txdata has been transfered
	output	wire						udp_txbusy,
	pc_head.slave						udp_tx_head
);









	axis								rx_net_cdc();	
	axis								tx_sys();					// udp_axis_rx ARP reply
	axis								tx_udp();					// udp_axis_tx UDP data

	
	localparam logic [47:0] DEFAULT_BOARD_MAC_ADDR = 48'h60_A8_01_33_44_55;
	localparam logic [31:0] DEFAULT_BOARD_IP_ADDR  = 32'hC0_A8_01_0A;	// 192.168.1.10

	logic [47:0] BOARD_MAC_ADDR;
	logic [31:0] BOARD_IP_ADDR;

	always_ff @(posedge sys_clk or negedge sys_rst_n) begin
		if (!sys_rst_n) begin
			BOARD_MAC_ADDR <= DEFAULT_BOARD_MAC_ADDR;
			BOARD_IP_ADDR  <= DEFAULT_BOARD_IP_ADDR;
		end else if (board_addr_cfg_valid) begin
			BOARD_MAC_ADDR <= board_mac_addr_cfg;
			BOARD_IP_ADDR  <= board_ip_addr_cfg;
		end
	end






rx_cdc_fifo_axis u_rx_cdc_fifo_axis(
	.rstn     (sys_rst_n),
	.clk  	  (sys_clk),
	.rx_clk   (rx_clk),
	.s_rx     (m_phy_rx),
	.m_rx     (rx_net_cdc)
);

udp_axis_rx							u_udp_axis_rx (
	.sys_clk							( sys_clk			),
	.sys_rst_n							( sys_rst_n			),
	.board_mac_addr						( BOARD_MAC_ADDR	),
	.board_ip_addr						( BOARD_IP_ADDR		),
	.s_axis_rx							( rx_net_cdc		),
	.m_axis_tx							( tx_sys			),
	.udp_rxstart						( udp_rxstart		),
	.udp_rxend							( udp_rxend			),
	.udp_rxframe_done					( udp_rxframe_done	),
	.udp_rxdv							( udp_rxdv			),
	.udp_rxdata							( udp_rxdata		),
	.udp_rxamount						( udp_rxamount		),
	.udp_rxnum							( udp_rxnum			),
	.rx_head							( udp_rx_head)
);


udp_axis_tx							u_udp_axis_tx (
	.sys_clk							( sys_clk			),
	.sys_rst_n							( sys_rst_n			),
	.board_mac_addr						( BOARD_MAC_ADDR	),
	.board_ip_addr						( BOARD_IP_ADDR		),
	.m_axis_tx							( tx_udp			),
	.udp_txstart						( udp_txstart		),
	.udp_txamount						( udp_txamount		),
	.udp_txdata							( udp_txdata		),
	.udp_txreq							( udp_txreq			),
	.udp_txbusy							( udp_txbusy		),
	.tx_head							( udp_tx_head			)
);



tx_cdc_fifo_axis u_tx_cdc_fifo_axis(
	.clk	 (sys_clk),
	.tx_clk  (tx_clk),
	.rstn	 (sys_rst_n),
	.sys_tx  (tx_sys),
	.udp_tx	 (tx_udp),
	.phy_tx  (s_phy_tx)
);



endmodule
