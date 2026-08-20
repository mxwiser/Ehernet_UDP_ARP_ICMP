`include "axis.svh"
`include "pc_head.svh"


// PC 发来的 UDP 数据经 eth_axis 解析后存入 FIFO, 回环发回 PC
module udp_loop_mii (
	output  logic                       uart_txd,
	input   logic                       uart_rxd,
	input	logic						rstn,
	output  logic	[1:0]				led,
	input	logic                       clk,

	//smi   
	output  logic  						phy_rst,
	output  logic                       mdc,
	inout   logic						mdio,
	//MII
	input   logic   					mii_rxdv,
	input   logic	[3:0]				mii_rxd,
	input	logic						mii_rxc,
	output	logic						mii_txen,
	output  logic	[3:0]				mii_txd,
	input   logic   					mii_txc

);
    assign  phy_rst = rstn;
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
	pc_head							udp_rx_head();
	pc_head							udp_tx_head();

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

udp	u1_udp (
	.sys_rst_n							( rstn		    ),
	.sys_clk							( clk			),
	.m_phy_rx							( m_phy_rx      ),
	.s_phy_tx                           ( s_phy_tx      ),
	.tx_clk								( mii_txc		),
	.rx_clk								( mii_rxc		),	

	.udp_rxstart						( udp_rxstart	),
	.udp_rxend							( udp_rxend		),
	.udp_rxframe_done					( udp_rxframe_done),
	.udp_rxdv							( udp_rxdv		),
	.udp_rxdata							( udp_rxdata	),
	.udp_rxamount						( udp_rxamount	),//total
	.udp_rxnum							( udp_rxnum		),//count
	.udp_rx_head						( udp_rx_head   ),

	.udp_txstart						( udp_txstart	),
	.udp_txamount						( udp_txamount	),
	.udp_txdata							( udp_txdata	),
	.udp_txreq							( udp_txreq		),
	.udp_txbusy							( udp_txbusy	),
	.udp_tx_head						( udp_tx_head   )
);

// 先缓存完整 UDP 载荷，收到包含 padding/FCS 的整帧结束标志后再启动回传。
// 元数据 FIFO 将长度和目的端信息绑定在一起，保证多帧排队时不会错配。
	wire								data_fifo_full;
	wire								meta_fifo_empty;
	wire								meta_fifo_full;
	wire	[127:0]					rx_meta_data;
	wire	[127:0]					tx_meta_data;
	reg								rx_drop;

	wire								data_fifo_overflow	= udp_rxdv && data_fifo_full;
	wire								meta_fifo_overflow	= udp_rxframe_done && !rx_drop && meta_fifo_full;
	wire								fifo_clear			= data_fifo_overflow || meta_fifo_overflow;
	wire								meta_wrreq			= udp_rxframe_done && !rx_drop;
	wire								meta_rdreq			= udp_txstart && !udp_txbusy;

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

	// FIFO 非空后保持启动请求；发送模块在 !udp_txbusy 时接收一次请求。
	assign udp_txstart = !meta_fifo_empty;

	fifo #(
		.DATA_WIDTH						( 8			),
		.DEPTH							( 2048		)
	) u_fifo_data (
		.rstn							( rstn			),
		.clock							( clk			),
		.clear							( fifo_clear	),
		.data							( udp_rxdata	),
		.rdreq							( udp_txreq	),
		.wrreq							( udp_rxdv && !rx_drop ),
		.empty							( 				),
		.full							( data_fifo_full ),
		.q								( udp_txdata	)
	);

	fifo #(
		.DATA_WIDTH						( 128			),
		.DEPTH							( 64			)
	) u_fifo_meta (
		.rstn							( rstn			),
		.clock							( clk			),
		.clear							( fifo_clear	),
		.data							( rx_meta_data	),
		.rdreq							( meta_rdreq	),
		.wrreq							( meta_wrreq	),
		.empty							( meta_fifo_empty ),
		.full							( meta_fifo_full ),
		.q								( tx_meta_data	)
	);

	// 数据 FIFO 溢出时丢弃当前帧的剩余载荷，待整帧结束后重新对齐。
	always_ff @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			rx_drop <= 1'b0;
		end else if (data_fifo_overflow) begin
			rx_drop <= 1'b1;
		end else if (udp_rxframe_done) begin
			rx_drop <= 1'b0;
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
