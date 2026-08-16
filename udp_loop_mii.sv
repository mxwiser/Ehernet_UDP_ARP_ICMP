`include "axis.svh"


// PC 发来的 UDP 数据经 eth_axis 解析后存入 FIFO, 回环发回 PC
module udp_loop_mii (
	output  logic                       uart_txd,
	input   logic                       uart_rxd,
	input	logic						rstn,
	output  logic	[1:0]				led,
	input	logic                       clk,

	//MII
	input   logic   					mii_rxdv,
	input   logic	[3:0]				mii_rxd,
	input	logic						mii_rxc,
	output	logic						mii_txen,
	output  logic	[3:0]				mii_txd,
	input   logic   					mii_txc

);

	wire								udp_rxstart;
	wire								udp_rxend;
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

phy_mii_axis							u_phy_mii_axis (
	.rstn								( rstn		),
	.tx_clk								( mii_txc	),
	.txd								( mii_txd	),
	.txen								( mii_txen	),
	.rx_clk								( mii_rxc	),
	.rxd								( mii_rxd	),
	.rxdv								( mii_rxdv	),
	.m_phy_rx							( m_phy_rx	),
	.s_phy_tx							( s_phy_tx	)
);

udp		u1_udp (
	.sys_rst_n							( rstn		    ),
	.sys_clk							( clk			),
	.m_phy_rx							( m_phy_rx      ),
	.s_phy_tx                           ( s_phy_tx      ),
	.tx_clk								( mii_txc		),
	.rx_clk								( mii_rxc		),	
	.udp_rxstart						( udp_rxstart	),
	.udp_rxend							( udp_rxend		),
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
// 帧元数据 FIFO: 每帧长度随 udp_rxend 入队, TX 启动时出队, 多帧积压时长度与数据仍一一对应
// 溢出自愈: 数据/元数据 FIFO 满时清空两者并丢弃当前帧剩余数据, 避免永久错位
	wire								rx_fifo_full;
	wire								amt_fifo_empty;
	wire								amt_fifo_full;
	reg									rx_drop;						// 溢出后丢弃本帧剩余数据, 帧结束恢复
	wire								rx_fifo_clear		= ( udp_rxdv && rx_fifo_full ) || ( udp_rxend && amt_fifo_full );
	wire								amt_rdreq			= udp_txstart && !udp_txbusy;			// TX 启动时出队一个帧长度
	wire								amt_wrreq			= udp_rxend && !rx_drop;

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
	end else if ( udp_rxend ) begin
		rx_drop <= 1'b0;					// 帧结束, 恢复
	end
end


//user test
// always @ ( posedge clk or negedge rstn ) begin
// 	if ( !rstn ) begin
// 		led <= 2'b0;
// 	end else if ( udp_rxdv && ( udp_rxdata == 'hA1 ) ) begin
// 		led <= ~led;
// 	end
// end

logic [7:0] uart_data;
logic uart_rxdv;
uart_rx u_uart_rx(
	.rstn   	  (rstn),
	.clk		  (clk),
	.o_tvalid     (uart_rxdv),
	.o_tdata	  (uart_data),
	.i_uart_rx    (uart_rxd)
);

always_ff@(posedge clk)begin
	if(uart_rxdv&&(uart_data=='hA1))begin
		led <= ~led;
	end
end

endmodule