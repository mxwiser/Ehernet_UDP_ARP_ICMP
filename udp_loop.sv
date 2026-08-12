`include "axis.svh"

// udp_loop: EP4CE10 + LAN8720A UDP 回环 (AXIS 版本)
// PC 发来的 UDP 数据经 eth_axis 解析后存入 FIFO, 回环发回 PC
module udp_loop (
	input	logic						sys_rst_n,
	output  logic	[1:0]				led,
	input	logic                       clk,
	input	logic						rmii_clk,
	input	logic					   	rmii_rxdv,
	input	logic	[1:0]				rmii_rxdata,
	output	logic						rmii_txen,
	output	logic	[1:0]				rmii_txdata,
	output	logic						rmii_rst
);

	wire								udp_rxstart;
	wire								udp_rxend;
	wire								udp_rxdv;
	wire	[7:0]						udp_rxdata;
	wire	[15:0]						udp_rxamount;
	wire	[15:0]						udp_rxnum;
	reg									udp_txstart;
	reg		[15:0]						udp_txamount;
	wire	[7:0]						udp_txdata;
	wire								udp_txreq;
	wire								udp_txbusy;

axis								m_phy_rx();
axis								s_phy_tx();

phy_rmii_axis							u_phy_rmii_axis (
	.rstn								( sys_rst_n			),
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
	.sys_rst_n							( sys_rst_n		),
	.sys_clk							( clk			),
	.m_phy_rx							( m_phy_rx      ),
	.s_phy_tx                           ( s_phy_tx      ),
	.tx_clk								( rmii_clk		),
	.rx_clk								( rmii_clk      ),	
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

fifo#(
	.DATA_WIDTH('d8),
	.DEPTH('d1024)
)							u2_fifo_1024_d8 (
	.rstn								( sys_rst_n		),
	.clock								( clk			),
	.clear								( 1'b0			),
	.data								( udp_rxdata	),
	.rdreq								( udp_txreq		),
	.wrreq								( udp_rxdv		),
	.q									( udp_txdata	)
);

always @ ( posedge clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		udp_txstart <= 1'b0;
	end else if ( udp_rxend ) begin
		udp_txstart <= 1'b1;
	end else begin
		udp_txstart <= 1'b0;
	end
end

always @ ( posedge clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		udp_txamount <= 16'd0;
	end else if ( udp_rxstart ) begin
		udp_txamount <= udp_rxamount;
	end else begin
		udp_txamount <= udp_txamount;
	end
end


//user test
always @ (posedge clk) begin
	if((udp_rxdata=='hA1) &&udp_rxdv)
		led <= !led;
end


endmodule