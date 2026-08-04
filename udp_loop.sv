`include "axis.svh"

// udp_loop: EP4CE10 + LAN8720A UDP 回环 (AXIS 版本)
// PC 发来的 UDP 数据经 eth_axis 解析后存入 FIFO, 回环发回 PC
module udp_loop (
	input	wire						sys_rst_n,
	output  logic	[1:0]				led,
	input	wire						rmii_clk,
	input	wire					   	rmii_rxdv,
	input	wire	[1:0]				rmii_rxdata,
	output	wire						rmii_txen,
	output	wire	[1:0]				rmii_txdata,
	output	wire						rmii_rst
);

logic[23:0] ckdiv;
logic[1:0]  rled;
assign led = rled;

always_ff@(posedge rmii_clk or negedge sys_rst_n)begin
    if(sys_rst_n == 1'b0)begin
        rled <= 2'b01;
        ckdiv <= 24'd0;
    end else begin
        ckdiv <= ckdiv + 24'd1;
        if(ckdiv == 24'd0)
            rled <= !rled;
    end
end

	// UDP 应用层 AXIS
	wire [7:0]						udp_rx_tdata;
	wire							udp_rx_tvalid;
	wire							udp_rx_tlast;
	wire	[15:0]					udp_rx_amount;
	wire	[7:0]					udp_tx_tdata;
	wire							udp_tx_tvalid;
	wire							udp_tx_tlast;
	wire							udp_tx_tready;
	wire	[15:0]					udp_tx_amount;

	axis	m_udp_rx();
	axis	s_udp_tx();

eth_axis							u1_eth_axis (
	.sys_rst_n						( sys_rst_n		),
	.rmii_clk						( rmii_clk		),
	.rmii_rxdv						( rmii_rxdv		),
	.rmii_rxdata					( rmii_rxdata	),
	.rmii_txen						( rmii_txen		),
	.rmii_txdata					( rmii_txdata	),
	.rmii_rst						( rmii_rst		),
	.m_udp_rx_axis_net				( m_udp_rx		),
	.s_udp_tx_axis_net				( s_udp_tx		),
	.udp_rx_amount					( udp_rx_amount	),
	.udp_tx_amount					( udp_tx_amount	)
);

	// 接口成员 <-> 回环信号
	assign m_udp_rx.tready	= 1'b1;						// 忽略 tready
	assign udp_rx_tdata		= m_udp_rx.tdata;
	assign udp_rx_tvalid	= m_udp_rx.tvalid;
	assign udp_rx_tlast		= m_udp_rx.tlast;
	assign s_udp_tx.tdata	= udp_tx_tdata;
	assign s_udp_tx.tvalid	= udp_tx_tvalid;
	assign s_udp_tx.tlast	= udp_tx_tlast;
	assign udp_tx_tready	= s_udp_tx.tready;

	// 回环: RX 数据 -> FIFO -> TX
	wire							fifo_empty;
	reg								fwd;						// 正在转发一个数据报
	reg								udp_rx_tlast_d;
	reg		[15:0]					udp_tx_amount_r;

fifo fifo_inst (
	.clock	( rmii_clk			),
	.rstn	( sys_rst_n			),
	.data	( udp_rx_tdata		),
	.wrreq	( udp_rx_tvalid		),
	.rdreq	( udp_tx_tready && fwd ),
	.empty	( fifo_empty		),
	.full	( 					),
	.q		( udp_tx_tdata		)
);

wire rx_frame_start = udp_rx_tlast && !udp_rx_tlast_d;

always @ ( posedge rmii_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		udp_rx_tlast_d <= 1'b0;
		fwd <= 1'b0;
		udp_tx_amount_r <= 16'd0;
	end else begin
		udp_rx_tlast_d <= udp_rx_tlast;
		if ( rx_frame_start && fifo_empty ) begin
			fwd <= 1'b1;
			udp_tx_amount_r <= udp_rx_amount;
		end else if ( fifo_empty && fwd && !udp_rx_tlast ) begin
			fwd <= 1'b0;
		end
	end
end

assign udp_tx_tvalid = fwd && !fifo_empty;
assign udp_tx_tlast  = fwd && !fifo_empty;
assign udp_tx_amount = udp_tx_amount_r;

endmodule
