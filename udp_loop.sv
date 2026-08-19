`include "axis.svh"

// udp_loop: EP4CE10 + LAN8720A UDP 回环 (AXIS 版本)
// PC 发来的 UDP 数据经 eth_axis 解析后存入 FIFO, 回环发回 PC
module udp_loop (
	output  logic	     				led,
	input	logic                       clk,
	input	logic						rmii_clk,
	input	logic					   	rmii_rxdv,
	input	logic	[1:0]				rmii_rxdata,
	output	logic						rmii_txen,
	output	logic	[1:0]				rmii_txdata,
	output	logic						rmii_rst
);

	reg 			 					rstn;

	always_ff@(posedge clk) begin
		if(!rstn) begin
			rstn <=1;
		end
	end


	wire								udp_rxstart;
	wire								udp_rxend;
	wire								udp_rxframe_done;
	wire								udp_rxdv;
	wire	[7:0]						udp_rxdata;
	wire	[15:0]						udp_rxamount;
	wire	[15:0]						udp_rxnum;
	wire								udp_txstart;
	wire	[15:0]						udp_txamount;
	wire	[7:0]						udp_txdata;
	wire								udp_txreq;
	wire								udp_txbusy;

    axis								m_phy_rx();
    axis								s_phy_tx();

phy_rmii_axis							u_phy_rmii_axis (
	.rstn								( rstn		),
	.rmii_clk							( rmii_clk			),
	.rmii_crs_dv						( rmii_rxdv			),
	.rmii_rxdata						( rmii_rxdata		),
	.rmii_txen							( rmii_txen			),
	.rmii_txdata						( rmii_txdata		),
	.rmii_rst							( rmii_rst			),
	.m_rmii_rx_axis_net					( m_phy_rx			),
	.s_rmii_tx_axis_net					( s_phy_tx     		)
);

udp		u1_udp (
	.sys_rst_n							( rstn		    ),
	.sys_clk							( clk			),
	.m_phy_rx							( m_phy_rx      ),
	.s_phy_tx                           ( s_phy_tx      ),
	.tx_clk								( rmii_clk		),
	.rx_clk								( rmii_clk      ),	
	.udp_rxstart						( udp_rxstart	),
	.udp_rxend							( udp_rxend		),
	.udp_rxframe_done					( udp_rxframe_done),
	.udp_rxdv							( udp_rxdv		),
	.udp_rxdata							( udp_rxdata	),
	.udp_rxamount						( udp_rxamount	),
	.udp_rxnum							( udp_rxnum		),
	.udp_txstart						( udp_txstart	),
	.udp_txamount						( udp_txamount	),
	.udp_txdata							( udp_txdata	),
	.udp_txreq							( udp_txreq		),
	.udp_txbusy							( udp_txbusy	)
);

// 帧数据 FIFO: 载荷字节按到达顺序排队 (wrreq=udp_rxdv, rdreq=udp_txreq)
// 帧元数据 FIFO: 完整 Ethernet 帧（含 padding/FCS）接收完毕后才入队。
// udp_rxend 仅表示真实 UDP payload 结束，不能用它提前启动回复。
// 溢出自愈: 数据/元数据 FIFO 满时清空两者并丢弃当前帧剩余数据, 避免永久错位
	wire								rx_fifo_full;
	wire								amt_fifo_empty;
	wire								amt_fifo_full;
	reg									rx_drop;						// 溢出后丢弃本帧剩余数据, 帧结束恢复
	wire								rx_fifo_clear		= ( udp_rxdv && rx_fifo_full ) || ( udp_rxframe_done && amt_fifo_full );
	wire								amt_rdreq			= udp_txstart && !udp_txbusy;			// TX 启动时出队一个帧长度
	wire								amt_wrreq			= udp_rxframe_done && !rx_drop;

	assign		udp_txstart		= !amt_fifo_empty;

fifo#(
	.DATA_WIDTH('d8),
	.DEPTH('d2048)
)							u2_fifo_data (
	.rstn								( rstn		),
	.clock								( clk			),
	.clear								( rx_fifo_clear	),
	.data								( udp_rxdata	),
	.rdreq								( udp_txreq		),
	.wrreq								( udp_rxdv && !rx_drop ),
	.full								( rx_fifo_full	),
	.q									( udp_txdata	)
);

fifo#(
	.DATA_WIDTH('d16),
	.DEPTH('d64)
)							u3_fifo_amt (
	.rstn								( rstn		),
	.clock								( clk			),
	.clear								( rx_fifo_clear	),
	.data								( udp_rxamount	),
	.rdreq								( amt_rdreq		),
	.wrreq								( amt_wrreq		),
	.empty								( amt_fifo_empty),
	.full								( amt_fifo_full	),
	.q									( udp_txamount	)
);

always @ ( posedge clk or negedge rstn ) begin
	if ( !rstn ) begin
		rx_drop <= 1'b0;
	end else if ( rx_fifo_clear ) begin
		rx_drop <= 1'b1;					// 溢出: 丢弃本帧剩余数据
	end else if ( udp_rxframe_done ) begin
		rx_drop <= 1'b0;					// 帧结束, 恢复
	end
end



always @ ( posedge clk or negedge rstn ) begin
	if ( !rstn ) begin
		led <= 2'b0;
	end else if ( udp_rxdv && ( udp_rxdata == 'hA1 ) ) begin
		led <= ~led;
	end
end



endmodule
