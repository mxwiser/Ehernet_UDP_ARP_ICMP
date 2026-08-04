`include "axis.svh"

// eth_arp_axis: 以太网 ARP 处理 + 发送仲裁 (AXIS 版本)
// RX: 所有网络帧透传给 udp_axis_rx(由其过滤), 本模块并行解析 ARP:
//     收到发给本机的 ARP 请求(CRC32 校验通过)后学习对端 MAC/IP 并自动回复
// TX: 仲裁 ARP 回复与 udp_axis_tx 的网络帧, 输出到 rmii_axis
// tlast 为帧电平(帧内高电平), 网络流带 tready 反压
module eth_arp_axis(
    input  wire         sys_clk,
    input  wire         sys_rst_n,

    axis.slave          s_rx_net,          // 网络接收流(来自 rmii_axis)
    axis.master         m_udp_rx_net,      // 转发给 udp_axis_rx
    axis.slave          s_udp_tx_net,      // 来自 udp_axis_tx 的网络发送流
    axis.master         m_tx_net,          // 输出到 rmii_axis 的网络发送流

    output reg  [47:0]  pc_mac_addr,       // 学习到的对端 MAC
    output reg  [31:0]  pc_ip_addr         // 学习到的对端 IP
);

    parameter BOARD_MAC_ADDR = 48'h00_11_22_33_44_55;
    parameter BOARD_IP_ADDR  = 32'hA9_FE_01_17;

//-------------------------------------------------------------
// RX: 逐字节位置解析 ARP 请求
// 帧字节位置: 0-6 前导, 7 SFD, 8-13 DA, 14-19 SA, 20-21 类型,
// 22-27 ARP头(htype/ptype/hlen/plen), 28-29 操作码,
// 30-35 SHA, 36-39 SPA, 40-45 THA, 46-49 TPA, 50-67 填充, 68-71 FCS
//-------------------------------------------------------------
    reg        rx_active;
    reg [6:0]  rx_cnt;
    reg        rx_bad;
    reg        rx_arp_req;          // TPA 匹配本机
    reg [47:0] des_mac;
    reg [47:0] src_mac;
    reg [31:0] spa;
    reg [31:0] tpa;
    reg [31:0] rx_crc32_read;
    reg [31:0] rx_crc32_r;
    reg        rx_reply;            // 1 拍脉冲: 需要回复

    reg tlast_d;

    wire rx_frame_start = !tlast_d && s_rx_net.tlast;
    wire rx_frame_end   = tlast_d && !s_rx_net.tlast;

    // RX 无背压
    assign s_rx_net.tready = 1'b1;
    // 透传给 udp_axis_rx
    assign m_udp_rx_net.tdata  = s_rx_net.tdata;
    assign m_udp_rx_net.tvalid = s_rx_net.tvalid;
    assign m_udp_rx_net.tlast  = s_rx_net.tlast;
    assign m_udp_rx_net.tuser  = 1'b0;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            tlast_d <= 1'b0;
        end else begin
            tlast_d <= s_rx_net.tlast;
        end
    end

    // RX CRC32 控制(覆盖 DA 到填充结束)
    wire rx_crc_start = s_rx_net.tvalid && rx_active && (rx_cnt == 7'd8);
    wire rx_crc_end   = s_rx_net.tvalid && rx_active && (rx_cnt == 7'd67);
    wire rx_crc_en    = s_rx_net.tvalid && rx_active && (rx_cnt >= 7'd8) && (rx_cnt <= 7'd67);

    wire [31:0] rx_crc32_w;
    wire        rx_crc32_valid;

    CRC32_D8 u_rx_crc32(
        .sys_clk       ( sys_clk        ),
        .sys_rst_n     ( sys_rst_n      ),
        .data          ( s_rx_net.tdata ),
        .crc_start     ( rx_crc_start   ),
        .crc_en        ( rx_crc_en      ),
        .crc_end       ( rx_crc_end     ),
        .crc32         ( rx_crc32_w     ),
        .crc32_valid   ( rx_crc32_valid )
    );

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            rx_active    <= 1'b0;
            rx_cnt       <= 7'd0;
            rx_bad       <= 1'b0;
            rx_arp_req   <= 1'b0;
            des_mac      <= 48'h0;
            src_mac      <= 48'h0;
            spa          <= 32'h0;
            tpa          <= 32'h0;
            rx_crc32_r   <= 32'h0;
            rx_crc32_read<= 32'h0;
        end else if (rx_frame_end) begin
            rx_active    <= 1'b0;
            rx_cnt       <= 7'd0;
            rx_bad       <= 1'b0;
            rx_arp_req   <= 1'b0;
        end else if (rx_frame_start) begin
            rx_active    <= 1'b1;
            rx_cnt       <= 7'd0;
            rx_bad       <= 1'b0;
            rx_arp_req   <= 1'b0;
        end else if (rx_active && s_rx_net.tvalid) begin
            // CRC 校验值锁存(数据最后一字节)
            if (rx_crc_end) begin
                rx_crc32_r <= rx_crc32_w;
            end

            case (rx_cnt)
                7'd0:  if (s_rx_net.tdata != 8'h55) rx_bad <= 1'b1;
                7'd1:  if (s_rx_net.tdata != 8'h55) rx_bad <= 1'b1;
                7'd2:  if (s_rx_net.tdata != 8'h55) rx_bad <= 1'b1;
                7'd3:  if (s_rx_net.tdata != 8'h55) rx_bad <= 1'b1;
                7'd4:  if (s_rx_net.tdata != 8'h55) rx_bad <= 1'b1;
                7'd5:  if (s_rx_net.tdata != 8'h55) rx_bad <= 1'b1;
                7'd6:  if (s_rx_net.tdata != 8'h55) rx_bad <= 1'b1;
                7'd7:  if (s_rx_net.tdata != 8'hD5) rx_bad <= 1'b1;
                7'd8:  des_mac[47:40] <= s_rx_net.tdata;
                7'd9:  des_mac[39:32] <= s_rx_net.tdata;
                7'd10: des_mac[31:24] <= s_rx_net.tdata;
                7'd11: des_mac[23:16] <= s_rx_net.tdata;
                7'd12: des_mac[15:8]  <= s_rx_net.tdata;
                7'd13: begin
                    des_mac[7:0] <= s_rx_net.tdata;
                    if ({des_mac[47:8], s_rx_net.tdata} != 48'hFF_FF_FF_FF_FF_FF &&
                        {des_mac[47:8], s_rx_net.tdata} != BOARD_MAC_ADDR) begin
                        rx_bad <= 1'b1;
                    end
                end
                7'd14: src_mac[47:40] <= s_rx_net.tdata;
                7'd15: src_mac[39:32] <= s_rx_net.tdata;
                7'd16: src_mac[31:24] <= s_rx_net.tdata;
                7'd17: src_mac[23:16] <= s_rx_net.tdata;
                7'd18: src_mac[15:8]  <= s_rx_net.tdata;
                7'd19: src_mac[7:0]   <= s_rx_net.tdata;
                7'd20: if (s_rx_net.tdata != 8'h08) rx_bad <= 1'b1;
                7'd21: if (s_rx_net.tdata != 8'h06) rx_bad <= 1'b1;
                7'd22: if (s_rx_net.tdata != 8'h00) rx_bad <= 1'b1;
                7'd23: if (s_rx_net.tdata != 8'h01) rx_bad <= 1'b1;
                7'd24: if (s_rx_net.tdata != 8'h08) rx_bad <= 1'b1;
                7'd25: if (s_rx_net.tdata != 8'h00) rx_bad <= 1'b1;
                7'd26: if (s_rx_net.tdata != 8'h06) rx_bad <= 1'b1;
                7'd27: if (s_rx_net.tdata != 8'h04) rx_bad <= 1'b1;
                7'd28: if (s_rx_net.tdata != 8'h00) rx_bad <= 1'b1;
                7'd29: if (s_rx_net.tdata != 8'h01) rx_bad <= 1'b1;
                7'd36: spa[31:24] <= s_rx_net.tdata;
                7'd37: spa[23:16] <= s_rx_net.tdata;
                7'd38: spa[15:8]  <= s_rx_net.tdata;
                7'd39: spa[7:0]   <= s_rx_net.tdata;
                7'd46: tpa[31:24] <= s_rx_net.tdata;
                7'd47: tpa[23:16] <= s_rx_net.tdata;
                7'd48: tpa[15:8]  <= s_rx_net.tdata;
                7'd49: begin
                    if ({tpa[31:8], s_rx_net.tdata} == BOARD_IP_ADDR) begin
                        rx_arp_req <= 1'b1;
                    end else begin
                        rx_bad <= 1'b1;
                    end
                end
                7'd68: rx_crc32_read[7:0]   <= s_rx_net.tdata;
                7'd69: rx_crc32_read[15:8]  <= s_rx_net.tdata;
                7'd70: rx_crc32_read[23:16] <= s_rx_net.tdata;
                7'd71: begin
                    if (!rx_bad && rx_arp_req && {s_rx_net.tdata, rx_crc32_read[23:0]} == rx_crc32_r) begin
                        pc_mac_addr <= src_mac;
                        pc_ip_addr  <= spa;
                    end
                end
            endcase

            rx_cnt <= rx_cnt + 7'd1;
        end
    end

    // rx_reply 脉冲: CRC32 校验通过且为发给本机的 ARP 请求
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            rx_reply <= 1'b0;
        end else if (rx_active && s_rx_net.tvalid && (rx_cnt == 7'd71) &&
                     !rx_bad && rx_arp_req &&
                     ({s_rx_net.tdata, rx_crc32_read[23:0]} == rx_crc32_r)) begin
            rx_reply <= 1'b1;
        end else begin
            rx_reply <= 1'b0;
        end
    end

//-------------------------------------------------------------
// TX: ARP 回复生成
// 帧: 前导8 + DA6 + SA6 + 类型2 + ARP28 + 填充18 + FCS4 = 72B
//-------------------------------------------------------------
    reg        arp_pend;            // 有回复待发
    reg        arp_active;
    reg [6:0]  arp_cnt;
    reg [31:0] arp_crc32_r;
    reg [47:0] tx_des_mac;
    reg [31:0] tx_des_ip;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            arp_pend    <= 1'b0;
            arp_active  <= 1'b0;
            arp_cnt     <= 7'd0;
            arp_crc32_r <= 32'h0;
            tx_des_mac  <= 48'h0;
            tx_des_ip   <= 32'h0;
        end else begin
            if (rx_reply && !arp_active) begin
                arp_pend <= 1'b1;
            end
            if (arp_active) begin
                if (arp_cnt == 7'd71 && m_tx_net.tready) begin
                    arp_active <= 1'b0;
                    arp_pend   <= 1'b0;
                end else if (m_tx_net.tready) begin
                    arp_cnt <= arp_cnt + 7'd1;
                end
                if (arp_cnt == 7'd67 && m_tx_net.tready) begin
                    arp_crc32_r <= arp_crc32_w;
                end
            end else if (arp_pend && !s_udp_tx_net.tvalid) begin
                arp_active <= 1'b1;
                arp_cnt    <= 7'd0;
                tx_des_mac <= pc_mac_addr;
                tx_des_ip  <= pc_ip_addr;
            end
        end
    end

    // TX CRC32 控制
    wire arp_crc_start = arp_active && m_tx_net.tready && (arp_cnt == 7'd8);
    wire arp_crc_end   = arp_active && m_tx_net.tready && (arp_cnt == 7'd67);
    wire arp_crc_en    = arp_active && m_tx_net.tready && (arp_cnt >= 7'd8) && (arp_cnt <= 7'd67);

    wire [31:0] arp_crc32_w;
    wire        arp_crc32_valid;

    CRC32_D8 u_tx_crc32(
        .sys_clk       ( sys_clk      ),
        .sys_rst_n     ( sys_rst_n    ),
        .data          ( arp_tx_byte  ),
        .crc_start     ( arp_crc_start),
        .crc_en        ( arp_crc_en   ),
        .crc_end       ( arp_crc_end  ),
        .crc32         ( arp_crc32_w  ),
        .crc32_valid   ( arp_crc32_valid)
    );

    // ARP 回复字节选择
    reg [7:0] arp_tx_byte;
    always @* begin
        if (arp_cnt < 7'd7) begin
            arp_tx_byte = 8'h55;
        end else if (arp_cnt == 7'd7) begin
            arp_tx_byte = 8'hD5;
        end else if (arp_cnt < 7'd14) begin
            arp_tx_byte = tx_des_mac[(47 - ((arp_cnt - 7'd8) << 3)) -: 8];
        end else if (arp_cnt < 7'd20) begin
            arp_tx_byte = BOARD_MAC_ADDR[(47 - ((arp_cnt - 7'd14) << 3)) -: 8];
        end else if (arp_cnt < 7'd22) begin
            arp_tx_byte = (arp_cnt == 7'd20) ? 8'h08 : 8'h06;
        end else if (arp_cnt < 7'd24) begin
            arp_tx_byte = (arp_cnt == 7'd22) ? 8'h00 : 8'h01;
        end else if (arp_cnt < 7'd26) begin
            arp_tx_byte = (arp_cnt == 7'd24) ? 8'h08 : 8'h00;
        end else if (arp_cnt < 7'd28) begin
            arp_tx_byte = (arp_cnt == 7'd26) ? 8'h06 : 8'h04;
        end else if (arp_cnt < 7'd30) begin
            arp_tx_byte = (arp_cnt == 7'd28) ? 8'h00 : 8'h02;
        end else if (arp_cnt < 7'd36) begin
            arp_tx_byte = BOARD_MAC_ADDR[(47 - ((arp_cnt - 7'd30) << 3)) -: 8];
        end else if (arp_cnt < 7'd40) begin
            arp_tx_byte = BOARD_IP_ADDR[(31 - ((arp_cnt - 7'd36) << 3)) -: 8];
        end else if (arp_cnt < 7'd46) begin
            arp_tx_byte = tx_des_mac[(47 - ((arp_cnt - 7'd40) << 3)) -: 8];
        end else if (arp_cnt < 7'd50) begin
            arp_tx_byte = tx_des_ip[(31 - ((arp_cnt - 7'd46) << 3)) -: 8];
        end else if (arp_cnt < 7'd68) begin
            arp_tx_byte = 8'h00;
        end else begin
            arp_tx_byte = arp_crc32_r[((arp_cnt - 7'd68) << 3) +: 8];
        end
    end

    // 发送仲裁: ARP 回复优先(帧边界切换), 否则透传 udp_axis_tx
    assign s_udp_tx_net.tready = arp_active ? 1'b0 : m_tx_net.tready;
    assign m_tx_net.tvalid = arp_active ? 1'b1 : s_udp_tx_net.tvalid;
    assign m_tx_net.tlast  = arp_active ? 1'b1 : s_udp_tx_net.tlast;
    assign m_tx_net.tdata  = arp_active ? arp_tx_byte : s_udp_tx_net.tdata;
    assign m_tx_net.tuser  = 1'b0;

endmodule
