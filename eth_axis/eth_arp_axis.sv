// eth_arp_axis: 以太网 ARP 处理 + 发送仲裁 (普通端口版)
// RX: 所有网络帧透传给 udp_axis_rx(由其过滤), 本模块并行解析 ARP:
//     扫描式前导同步(容忍帧首多余数据/前导长度变化),
//     收到发给本机的 ARP 请求(CRC32 校验通过)后学习对端 MAC/IP 并自动回复
// TX: 仲裁 ARP 回复与 udp_axis_tx 的网络帧, 输出到 rmii_axis
// tlast 为帧电平(帧内高电平), 网络流带 tready 反压
module eth_arp_axis(
    input  wire         sys_clk,
    input  wire         sys_rst_n,

    // 网络接收流(来自 rmii_axis)
    input  wire [7:0]   rx_net_tdata,
    input  wire         rx_net_tvalid,
    input  wire         rx_net_tlast,
    // 转发给 udp_axis_rx
    output wire [7:0]   udp_rx_tdata,
    output wire         udp_rx_tvalid,
    output wire         udp_rx_tlast,
    // 来自 udp_axis_tx 的网络发送流
    input  wire [7:0]   udp_tx_tdata,
    input  wire         udp_tx_tvalid,
    input  wire         udp_tx_tlast,
    output wire         udp_tx_tready,
    // 输出到 rmii_axis 的网络发送流
    output reg  [7:0]   tx_net_tdata,
    output reg          tx_net_tvalid,
    output reg          tx_net_tlast,
    input  wire         tx_net_tready,

    output reg  [47:0]  pc_mac_addr,       // 学习到的对端 MAC
    output reg  [31:0]  pc_ip_addr,        // 学习到的对端 IP
    output wire         arp_req_pulse,     // 调试: 收到有效 ARP 请求(1拍脉冲)
    output wire         arp_reply_pulse    // 调试: ARP 回复发送完毕(1拍脉冲)
);

    parameter BOARD_MAC_ADDR = 48'h00_11_22_33_44_55;
    parameter BOARD_IP_ADDR  = 32'hA9_FE_01_17;

//-------------------------------------------------------------
// RX: 前导扫描 + 同步后逐字节解析
// 同步前: 数连续 0x55, 第 7 个 0x55 后的 0xD5 为 SFD, 同步完成
// 同步后(位置从 DA 首字节计):
//  0-5 DA, 6-11 SA, 12-13 类型, 14-27 ARP头(htype/ptype/hlen/plen/oper),
//  28-31 SPA, 38-41 TPA, 42-59 填充, 60-63 FCS
//-------------------------------------------------------------
    reg        rx_active;          // 帧内(tlast 高)
    reg        rx_synced;          // 已同步到 SFD
    reg [6:0]  rx_cnt;             // 同步后的字节位置
    reg [2:0]  rx_pre_cnt;         // 前导 0x55 计数
    reg        rx_bad;
    reg        rx_arp_req;         // TPA 匹配本机
    reg [47:0] des_mac;
    reg [47:0] src_mac;
    reg [31:0] spa;
    reg [31:0] tpa;
    reg [31:0] rx_crc32_read;
    reg [31:0] rx_crc32_r;
    reg        rx_reply;           // 1 拍脉冲: 需要回复

    reg tlast_d;

    wire rx_frame_start = !tlast_d && rx_net_tlast;
    wire rx_frame_end   = tlast_d && !rx_net_tlast;

    // 透传给 udp_axis_rx
    assign udp_rx_tdata  = rx_net_tdata;
    assign udp_rx_tvalid = rx_net_tvalid;
    assign udp_rx_tlast  = rx_net_tlast;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            tlast_d <= 1'b0;
        end else begin
            tlast_d <= rx_net_tlast;
        end
    end

    // RX CRC32 控制(同步后 DA 到填充结束)
    wire rx_crc_start = rx_net_tvalid && rx_active && rx_synced && (rx_cnt == 7'd0);
    wire rx_crc_end   = rx_net_tvalid && rx_active && rx_synced && (rx_cnt == 7'd59);
    wire rx_crc_en    = rx_net_tvalid && rx_active && rx_synced && (rx_cnt <= 7'd59);

    wire [31:0] rx_crc32_w;
    wire        rx_crc32_valid;

    CRC32_D8 u_rx_crc32(
        .sys_clk       ( sys_clk        ),
        .sys_rst_n     ( sys_rst_n      ),
        .data          ( rx_net_tdata   ),
        .crc_start     ( rx_crc_start   ),
        .crc_en        ( rx_crc_en      ),
        .crc_end       ( rx_crc_end     ),
        .crc32         ( rx_crc32_w     ),
        .crc32_valid   ( rx_crc32_valid )
    );

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            rx_active    <= 1'b0;
            rx_synced    <= 1'b0;
            rx_cnt       <= 7'd0;
            rx_pre_cnt   <= 3'd0;
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
            rx_synced    <= 1'b0;
            rx_cnt       <= 7'd0;
            rx_pre_cnt   <= 3'd0;
            rx_bad       <= 1'b0;
            rx_arp_req   <= 1'b0;
        end else if (rx_frame_start) begin
            rx_active    <= 1'b1;
            rx_synced    <= 1'b0;
            rx_cnt       <= 7'd0;
            rx_pre_cnt   <= 3'd0;
            rx_bad       <= 1'b0;
            rx_arp_req   <= 1'b0;
        end else if (rx_active && rx_net_tvalid) begin
            if (!rx_synced) begin
                // 前导扫描: 数连续 0x55, 第 7 个之后出现 0xD5 即同步
                if (rx_net_tdata == 8'h55) begin
                    if (rx_pre_cnt < 3'd7) begin
                        rx_pre_cnt <= rx_pre_cnt + 3'd1;
                    end
                end else if (rx_net_tdata == 8'hD5 && rx_pre_cnt == 3'd7) begin
                    rx_synced  <= 1'b1;
                    rx_cnt     <= 7'd0;
                    rx_pre_cnt <= 3'd0;
                end else begin
                    rx_pre_cnt <= 3'd0;
                end
            end else begin
                // CRC 校验值锁存(填充最后一字节)
                if (rx_crc_end) begin
                    rx_crc32_r <= rx_crc32_w;
                end

                case (rx_cnt)
                    7'd0:  des_mac[47:40] <= rx_net_tdata;
                    7'd1:  des_mac[39:32] <= rx_net_tdata;
                    7'd2:  des_mac[31:24] <= rx_net_tdata;
                    7'd3:  des_mac[23:16] <= rx_net_tdata;
                    7'd4:  des_mac[15:8]  <= rx_net_tdata;
                    7'd5:  begin
                        des_mac[7:0] <= rx_net_tdata;
                        if ({des_mac[47:8], rx_net_tdata} != 48'hFF_FF_FF_FF_FF_FF &&
                            {des_mac[47:8], rx_net_tdata} != BOARD_MAC_ADDR) begin
                            rx_bad <= 1'b1;
                        end
                    end
                    7'd6:  src_mac[47:40] <= rx_net_tdata;
                    7'd7:  src_mac[39:32] <= rx_net_tdata;
                    7'd8:  src_mac[31:24] <= rx_net_tdata;
                    7'd9:  src_mac[23:16] <= rx_net_tdata;
                    7'd10: src_mac[15:8]  <= rx_net_tdata;
                    7'd11: src_mac[7:0]   <= rx_net_tdata;
                    7'd12: if (rx_net_tdata != 8'h08) rx_bad <= 1'b1;
                    7'd13: if (rx_net_tdata != 8'h06) rx_bad <= 1'b1;
                    7'd14: if (rx_net_tdata != 8'h00) rx_bad <= 1'b1;
                    7'd15: if (rx_net_tdata != 8'h01) rx_bad <= 1'b1;
                    7'd16: if (rx_net_tdata != 8'h08) rx_bad <= 1'b1;
                    7'd17: if (rx_net_tdata != 8'h00) rx_bad <= 1'b1;
                    7'd18: if (rx_net_tdata != 8'h06) rx_bad <= 1'b1;
                    7'd19: if (rx_net_tdata != 8'h04) rx_bad <= 1'b1;
                    7'd20: if (rx_net_tdata != 8'h00) rx_bad <= 1'b1;
                    7'd21: if (rx_net_tdata != 8'h01) rx_bad <= 1'b1;
                    7'd28: spa[31:24] <= rx_net_tdata;
                    7'd29: spa[23:16] <= rx_net_tdata;
                    7'd30: spa[15:8]  <= rx_net_tdata;
                    7'd31: spa[7:0]   <= rx_net_tdata;
                    7'd38: tpa[31:24] <= rx_net_tdata;
                    7'd39: tpa[23:16] <= rx_net_tdata;
                    7'd40: tpa[15:8]  <= rx_net_tdata;
                    7'd41: begin
                        if ({tpa[31:8], rx_net_tdata} == BOARD_IP_ADDR) begin
                            rx_arp_req <= 1'b1;
                        end else begin
                            rx_bad <= 1'b1;
                        end
                    end
                    7'd60: rx_crc32_read[7:0]   <= rx_net_tdata;
                    7'd61: rx_crc32_read[15:8]  <= rx_net_tdata;
                    7'd62: rx_crc32_read[23:16] <= rx_net_tdata;
                    7'd63: begin
                        if (!rx_bad && rx_arp_req && {rx_net_tdata, rx_crc32_read[23:0]} == rx_crc32_r) begin
                            pc_mac_addr <= src_mac;
                            pc_ip_addr  <= spa;
                        end
                    end
                endcase

                rx_cnt <= rx_cnt + 7'd1;
            end
        end
    end

    // arp_req_pulse: CRC32 校验通过且为发给本机的 ARP 请求
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            rx_reply <= 1'b0;
        end else if (rx_active && rx_synced && rx_net_tvalid && (rx_cnt == 7'd63) &&
                     !rx_bad && rx_arp_req &&
                     ({rx_net_tdata, rx_crc32_read[23:0]} == rx_crc32_r)) begin
            rx_reply <= 1'b1;
        end else begin
            rx_reply <= 1'b0;
        end
    end
    assign arp_req_pulse = rx_reply;

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
    reg        arp_done;            // 回复帧结束脉冲

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            arp_pend    <= 1'b0;
            arp_active  <= 1'b0;
            arp_cnt     <= 7'd0;
            arp_crc32_r <= 32'h0;
            tx_des_mac  <= 48'h0;
            tx_des_ip   <= 32'h0;
            arp_done    <= 1'b0;
        end else begin
            arp_done <= 1'b0;
            if (rx_reply && !arp_active) begin
                arp_pend <= 1'b1;
            end
            if (arp_active) begin
                if (arp_cnt == 7'd71 && tx_net_tready) begin
                    arp_active <= 1'b0;
                    arp_pend   <= 1'b0;
                    arp_done   <= 1'b1;
                end else if (tx_net_tready) begin
                    arp_cnt <= arp_cnt + 7'd1;
                end
                if (arp_cnt == 7'd67 && tx_net_tready) begin
                    arp_crc32_r <= arp_crc32_w;
                end
            end else if (arp_pend && !udp_tx_tvalid) begin
                arp_active <= 1'b1;
                arp_cnt    <= 7'd0;
                tx_des_mac <= pc_mac_addr;
                tx_des_ip  <= pc_ip_addr;
            end
        end
    end
    assign arp_reply_pulse = arp_done;

    // TX CRC32 控制
    wire arp_crc_start = arp_active && tx_net_tready && (arp_cnt == 7'd8);
    wire arp_crc_end   = arp_active && tx_net_tready && (arp_cnt == 7'd67);
    wire arp_crc_en    = arp_active && tx_net_tready && (arp_cnt >= 7'd8) && (arp_cnt <= 7'd67);

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
    assign udp_tx_tready = arp_active ? 1'b0 : tx_net_tready;
    assign tx_net_tvalid = arp_active ? 1'b1 : udp_tx_tvalid;
    assign tx_net_tlast  = arp_active ? 1'b1 : udp_tx_tlast;
    assign tx_net_tdata  = arp_active ? arp_tx_byte : udp_tx_tdata;

endmodule
