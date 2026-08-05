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

logic[23:0] blink0;
logic[1:0]  rled;
assign led = rled;

// 调试 LED:
//   LED[0]: 收到任意网络帧(亮 200ms)
//   LED[1]: 每帧结束后按解析阶段闪烁 dbg_stage 次(250ms/次):
//           1=前导通过 2=MAC通过 3=类型通过 4=IP通过 5=UDP头通过 6=数据输出
always_ff@(posedge rmii_clk or negedge sys_rst_n)begin
    if(sys_rst_n == 1'b0)begin
        blink0 <= 24'd0;
    end else begin
        if (dbg_frame_rx)     blink0 <= 24'd10_000_000;
        else if (blink0 != 24'd0) blink0 <= blink0 - 24'd1;
    end
end

reg [2:0]  stage_left;
reg [23:0] stage_timer;
reg        stage_on;
assign rled[0] = (blink0 != 24'd0);
assign rled[1] = stage_on;

always @ ( posedge rmii_clk or negedge sys_rst_n ) begin
    if ( !sys_rst_n ) begin
        stage_left  <= 3'd0;
        stage_timer <= 24'd0;
        stage_on    <= 1'b0;
    end else if ( dbg_stage_vld && (stage_left == 3'd0) && !stage_on && (dbg_stage != 3'd0) ) begin
        stage_left  <= dbg_stage;
        stage_on    <= 1'b1;
        stage_timer <= 24'd12_500_000;      // 亮 250ms
    end else if ( stage_left != 3'd0 || stage_on ) begin
        if ( stage_timer == 24'd0 ) begin
            if ( stage_on ) begin
                if ( stage_left == 3'd1 ) begin
                    // 最后一闪结束, 完全熄灭
                    stage_left  <= 3'd0;
                    stage_on    <= 1'b0;
                    stage_timer <= 24'd0;
                end else begin
                    stage_on    <= 1'b0;    // 灭 250ms
                    stage_timer <= 24'd12_500_000;
                end
            end else begin
                stage_left  <= stage_left - 3'd1;
                stage_on    <= 1'b1;
                stage_timer <= 24'd12_500_000;
            end
        end else begin
            stage_timer <= stage_timer - 24'd1;
        end
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
	wire	[7:0]					udp_tx_tdata_loop;
	wire							dbg_frame_rx;
	wire							dbg_udp_rx_net;
	wire	[2:0]					dbg_stage;
	wire							dbg_stage_vld;
	wire	[47:0]					dbg_des_mac;
	wire							dbg_udp_ok;
	wire							dbg_ip_ok;
	wire							dbg_da_ok;

eth_axis							u1_eth_axis (
	.sys_rst_n						( sys_rst_n		),
	.rmii_clk						( rmii_clk		),
	.rmii_rxdv						( rmii_rxdv		),
	.rmii_rxdata					( rmii_rxdata	),
	.rmii_txen						( rmii_txen		),
	.rmii_txdata					( rmii_txdata	),
	.rmii_rst						( rmii_rst		),
	.udp_rx_tdata					( udp_rx_tdata	),
	.udp_rx_tvalid					( udp_rx_tvalid	),
	.udp_rx_tlast					( udp_rx_tlast	),
	.udp_rx_tready					( 1'b1			),
	.udp_rx_amount					( udp_rx_amount	),
	.udp_tx_tdata					( udp_tx_tdata	),
	.udp_tx_tvalid					( udp_tx_tvalid	),
	.udp_tx_tlast					( udp_tx_tlast	),
	.udp_tx_tready					( udp_tx_tready	),
	.udp_tx_amount					( udp_tx_amount	),
	.dbg_frame_rx					( dbg_frame_rx	),
	.dbg_arp_req					( 				),
	.dbg_arp_reply					( 				),
	.dbg_udp_rx						( 				),
	.dbg_udp_tx						( 				),
	.dbg_udp_rx_net					( dbg_udp_rx_net	),
	.dbg_stage						( dbg_stage		),
	.dbg_stage_vld					( dbg_stage_vld	),
	.dbg_des_mac					( dbg_des_mac	),
	.dbg_udp_ok						( dbg_udp_ok	),
	.dbg_ip_ok						( dbg_ip_ok		),
	.dbg_da_ok						( dbg_da_ok		)
);

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
	.q		( udp_tx_tdata_loop	)
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

//=============================================================
// 测试模式: 每 0.5s 自动发送一包 UDP 诊断帧(8 字节载荷), 绕过接收解析
// 载荷含义:
//   字节0~5 = 最近一帧收到的目的 MAC(可能被 LLDP 干扰, 以字节6/7为准)
//   字节6   = 收到帧总数(自复位以来, 含 LLDP 等)
//   字节7   = {udp_ok, ip_ok, da_ok, 00, stage}
//             udp_ok(bit7): 任一帧解析成功过(到达 UDP 数据段)
//             ip_ok(bit6):  任一帧目的 IP 匹配本机(169.254.1.23)
//             da_ok(bit5):  任一帧目的 MAC 匹配本机/广播
//             stage(bit2:0): 最近一帧达到的阶段
//=============================================================
reg [24:0] tst_tick;
reg        tst_active;
reg [2:0]  tst_cnt;
reg [7:0]  frame_cnt;
reg [7:0]  tst_byte;

always @ ( posedge rmii_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		tst_tick   <= 25'd0;
		tst_active <= 1'b0;
		tst_cnt    <= 3'd0;
		frame_cnt  <= 8'd0;
	end else begin
		if ( dbg_frame_rx ) frame_cnt <= frame_cnt + 8'd1;
		tst_tick <= tst_tick + 25'd1;
		if ( tst_active ) begin
			if ( udp_tx_tready && (tst_cnt == 3'd7) ) begin
				tst_active <= 1'b0;             // 8 字节数据已送出
			end else if ( udp_tx_tready ) begin
				tst_cnt <= tst_cnt + 3'd1;
			end
		end else if ( tst_tick == 25'd24_999_999 ) begin
			tst_active <= 1'b1;
			tst_cnt    <= 3'd0;
		end
	end
end

wire [63:0] dbg_payload = { dbg_des_mac, frame_cnt,
                            {dbg_udp_ok, dbg_ip_ok, dbg_da_ok, 2'b00, dbg_stage} };

always @* begin
	case ( tst_cnt )
		3'd0:    tst_byte = dbg_payload[63:56];
		3'd1:    tst_byte = dbg_payload[55:48];
		3'd2:    tst_byte = dbg_payload[47:40];
		3'd3:    tst_byte = dbg_payload[39:32];
		3'd4:    tst_byte = dbg_payload[31:24];
		3'd5:    tst_byte = dbg_payload[23:16];
		3'd6:    tst_byte = dbg_payload[15:8];
		default: tst_byte = dbg_payload[7:0];
	endcase
end

assign udp_tx_tdata  = tst_active ? tst_byte : udp_tx_tdata_loop;
assign udp_tx_tvalid = tst_active ? 1'b1  : (fwd && !fifo_empty);
assign udp_tx_tlast  = tst_active ? 1'b1  : (fwd && !fifo_empty);
assign udp_tx_amount = tst_active ? 16'd8 : udp_tx_amount_r;

endmodule
