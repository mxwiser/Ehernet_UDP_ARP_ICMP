`include "pc_head.svh"

// UDP 回环缓存：整帧接收完成后，将载荷和对应的地址信息回传。
module udp_ring #(
	parameter DATA_FIFO_DEPTH = 2048,
	parameter META_FIFO_DEPTH = 64
)(
	input  wire						clk,
	input  wire						rstn,

	input  wire						udp_rxframe_done,
	input  wire						udp_rxdv,
	input  wire [7:0]				udp_rxdata,
	input  wire [15:0]				udp_rxamount,
	pc_head.slave					udp_rx_head,

	output wire						udp_txstart,
	output wire [15:0]				udp_txamount,
	output wire [7:0]				udp_txdata,
	input  wire						udp_txreq,
	input  wire						udp_txbusy,
	pc_head.master					udp_tx_head
);

	wire								data_fifo_full;
	wire								meta_fifo_empty;
	wire								meta_fifo_full;
	wire [127:0]						rx_meta_data;
	wire [127:0]						tx_meta_data;
	reg								rx_drop;

	wire data_fifo_overflow = udp_rxdv && data_fifo_full;
	wire meta_fifo_overflow = udp_rxframe_done && !rx_drop && meta_fifo_full;
	wire fifo_clear = data_fifo_overflow || meta_fifo_overflow;
	wire meta_wrreq = udp_rxframe_done && !rx_drop;
	wire meta_rdreq = udp_txstart && !udp_txbusy;

	assign rx_meta_data = {
		udp_rx_head.pc_mac_addr,
		udp_rx_head.pc_ip_addr,
		udp_rx_head.pc_port,
		udp_rx_head.board_port,
		udp_rxamount
	};

	assign {
		udp_tx_head.pc_mac_addr,
		udp_tx_head.pc_ip_addr,
		udp_tx_head.pc_port,
		udp_tx_head.board_port,
		udp_txamount
	} = tx_meta_data;

	assign udp_txstart = !meta_fifo_empty;

	fifo #(
		.DATA_WIDTH						( 8				),
		.DEPTH							( DATA_FIFO_DEPTH	)
	) u_fifo_data (
		.rstn							( rstn				),
		.clock							( clk				),
		.clear							( fifo_clear		),
		.data							( udp_rxdata		),
		.rdreq							( udp_txreq		),
		.wrreq							( udp_rxdv && !rx_drop ),
		.empty							( 					),
		.full							( data_fifo_full	),
		.q								( udp_txdata		)
	);

	fifo #(
		.DATA_WIDTH						( 128				),
		.DEPTH							( META_FIFO_DEPTH	)
	) u_fifo_meta (
		.rstn							( rstn				),
		.clock							( clk				),
		.clear							( fifo_clear		),
		.data							( rx_meta_data		),
		.rdreq							( meta_rdreq		),
		.wrreq							( meta_wrreq		),
		.empty							( meta_fifo_empty	),
		.full							( meta_fifo_full	),
		.q								( tx_meta_data		)
	);

	// 数据溢出后丢弃当前帧剩余载荷，到整帧结束时恢复。
	always_ff @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			rx_drop <= 1'b0;
		end else if (data_fifo_overflow) begin
			rx_drop <= 1'b1;
		end else if (udp_rxframe_done) begin
			rx_drop <= 1'b0;
		end
	end

endmodule
