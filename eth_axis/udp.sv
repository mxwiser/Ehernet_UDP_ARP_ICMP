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
	axis								tx_sys();					// udp_axis_rx ARP reply
	axis								tx_udp();					// udp_axis_tx UDP data
	axis								tx_net();					// muxed TX -> rmii_axis
	axis								tx_net_fifo();

	
	parameter		BOARD_MAC_ADDR			= 48'h00_10_22_33_44_55;
	parameter		BOARD_IP_ADDR			= 32'hA9_FE_01_17;			// 169.254.1.23




rmii_axis								u_rmii_axis (
	.rstn								( sys_rst_n			),
	.rmii_clk							( rmii_clk			),
	.rmii_crs_dv						( rmii_rxdv			),
	.rmii_rxdata						( rmii_rxdata		),
	.rmii_txen							( rmii_txen			),
	.rmii_txdata						( rmii_txdata		),
	.rmii_rst							( rmii_rst			),
	.m_rmii_rx_axis_net					( rx_net			),
	.s_rmii_tx_axis_net					( tx_net_fifo		)
);

udp_axis_rx#(
	.BOARD_IP_ADDR   (BOARD_IP_ADDR),
	.BOARD_MAC_ADDR  (BOARD_MAC_ADDR)
)
										u_udp_axis_rx (
	.sys_clk							( rmii_clk			),
	.sys_rst_n							( sys_rst_n			),
	.s_axis_rx							( rx_net			),
	.m_axis_tx							( tx_sys			),
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

// udp_axis_tx#(	
// 	.BOARD_IP_ADDR   (BOARD_IP_ADDR),
// 	.BOARD_MAC_ADDR  (BOARD_MAC_ADDR)
// )								
// 										u_udp_axis_tx (
// 	.sys_clk							( rmii_clk			),
// 	.sys_rst_n							( sys_rst_n			),
// 	.m_axis_tx							( tx_udp			),
// 	.udp_txstart						( udp_txstart		),
// 	.udp_txamount						( udp_txamount		),
// 	.udp_txdata							( udp_txdata		),
// 	.udp_txreq							( udp_txreq			),
// 	.udp_txbusy							( udp_txbusy		),
// 	.pc_mac_addr						( pc_mac_addr		),
// 	.pc_ip_addr							( pc_ip_addr		),
// 	.pc_port							( pc_port			),
// 	.board_port							( board_port		)
// );




//TX SYS BUFFER

logic        sys_frame_end_flag;
logic        sys_data_idx;
logic [8:0] sys_fifo_data; 
assign sys_fifo_data = {1'b0,tx_sys.tdata};

assign tx_sys.tready = 1'b1;
always_ff@(posedge rmii_clk or negedge sys_rst_n) begin
	if(!sys_rst_n) begin
		sys_data_idx   <= 'b0;
		sys_frame_end_flag <= 'b0;
	end else begin
		if(tx_sys.tlast) begin
			sys_data_idx <= 1'b1;
		end else begin
			sys_data_idx <='d0;
			if(sys_data_idx!='d0)begin
				sys_frame_end_flag <= 'b1;
			end
		end
		if (sys_frame_end_flag) begin
			sys_frame_end_flag <= 'b0;
		end
	end
end

wire  		 sys_empty;
wire  	 	 sys_rdreq;
wire[15:0]   sys_q;
wire		 sys_q_idx;
wire[7:0]	 sys_q_data;
wire		 sys_q_end;
assign sys_q_end  = (sys_q_idx);      
assign sys_q_idx  = sys_q[8];
assign sys_q_data = sys_q[7:0];
assign sys_rdreq		= !sys_empty && tx_net_fifo.tready;
assign tx_net_fifo.tvalid = sys_rdreq && !sys_q_end;
assign tx_net_fifo.tlast  = !sys_empty && !sys_q_end;
assign tx_net_fifo.tdata  = sys_q_data;
fifo#(
	.DATA_WIDTH('d9),
	.DEPTH('d512)
)udp_tx_sys_fifo_512_d9(
	.clock 		(rmii_clk),
	.rstn  		(sys_rst_n),
	.wrreq		(tx_sys.tvalid||sys_frame_end_flag),
	.data		(sys_frame_end_flag?{1'b1,8'h00}:sys_fifo_data),
	.empty		(sys_empty),
	.rdreq		(sys_rdreq),
	.q			(sys_q)
);


endmodule
