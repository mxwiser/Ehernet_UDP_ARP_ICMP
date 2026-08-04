`include "axis.svh"

// udp_axis_tx: UDP 数据 AXIS 流 -> 网络 AXIS 流
// 自动生成前导码/SFD/以太网+IP+UDP 头/填充/CRC32, 完整透传帧
// tlast 为帧电平(帧内高电平), 网络流接受 tready 反压
// 帧内应用数据必须连续, 断流则本帧作废(截断发送)
// 注意: udp_tx_amount 为 UDP 数据长度(不含 8 字节 UDP 头), 最大 1472
module udp_axis_tx(
    input  wire         sys_clk,
    input  wire         sys_rst_n,

    axis.slave          s_axis,              // UDP 数据输入(应用层)
    axis.master         m_axis,              // 网络发送流(到 eth_arp_axis)

    input  wire [15:0]  udp_tx_amount,       // UDP 数据长度
    input  wire [47:0]  pc_mac_addr,         // 对端 MAC(eth_arp_axis 学习)
    input  wire [31:0]  pc_ip_addr,          // 对端 IP(eth_arp_axis 学习)
    input  wire [15:0]  pc_port,             // 对端端口(udp_axis_rx 学习)
    input  wire [15:0]  board_port           // 本机端口(udp_axis_rx 学习)
);

    parameter BOARD_MAC_ADDR = 48'h00_11_22_33_44_55;
    parameter BOARD_IP_ADDR  = 32'hA9_FE_01_17;

//-------------------------------------------------------------
// 帧布局(单字节计数器方式):
//  cnt  0-6  前导码 0x55
//  cnt  7    SFD 0xD5
//  cnt  8-13 目的 MAC
//  cnt 14-19 源 MAC
//  cnt 20-21 类型 0x0800
//  cnt 22-41 IP 头(20B)
//  cnt 42-49 UDP 头(8B)
//  cnt 50...  应用数据 amount 字节
//  之后      填充 pad 字节(短帧补到 64B)
//  之后      4B FCS
//-------------------------------------------------------------
    reg        tx_active;
    reg [15:0] cnt;
    reg [15:0] amount_r;
    reg [15:0] ip_id_r;
    reg [15:0] ip_csum_r;
    reg [31:0] crc32_r;

    reg [15:0] pad_len;
    reg [15:0] payload_end;
    reg [15:0] fcs_start;

    wire [15:0] total_len   = 16'd28 + amount_r + pad_len;
    wire [15:0] total_bytes = fcs_start + 16'd4;

    wire payload_region = tx_active && (cnt >= 16'd50) && (cnt < payload_end);
    wire in_frame_data  = tx_active && (cnt >= 16'd8) && (cnt < fcs_start);
    wire tx_advance     = tx_active && m_axis.tready;
    wire frame_start    = !tx_active && s_axis.tvalid && s_axis.tlast;

    // CRC32_D8 控制
    wire crc_start = tx_advance && (cnt == 16'd8);
    wire crc_end   = tx_advance && (cnt == fcs_start - 16'd1);
    wire crc_en    = tx_advance && in_frame_data;

    // 帧开始时锁存长度参数(此时才用到 udp_tx_amount)
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            amount_r    <= 16'd0;
            pad_len     <= 16'd0;
            payload_end <= 16'd0;
            fcs_start   <= 16'd0;
        end else if (frame_start) begin
            amount_r    <= udp_tx_amount;
            pad_len     <= (udp_tx_amount < 16'd18) ? (16'd18 - udp_tx_amount) : 16'd0;
            payload_end <= 16'd50 + udp_tx_amount;
            fcs_start   <= 16'd50 + udp_tx_amount
                           + ((udp_tx_amount < 16'd18) ? (16'd18 - udp_tx_amount) : 16'd0);
        end
    end

    // IP 头校验和(两次回卷 + 取反), 帧开始时由输入长度直接计算
    wire [15:0] pad_len_in   = (udp_tx_amount < 16'd18) ? (16'd18 - udp_tx_amount) : 16'd0;
    wire [15:0] total_len_in = 16'd28 + udp_tx_amount + pad_len_in;
    wire [15:0] ip_id_next   = ip_id_r + 16'd1;
    wire [31:0] csum_s0 = 32'h0000_4500 + {16'h0, total_len_in} + {16'h0, ip_id_next}
                        + 32'h0000_4000 + 32'h0000_4011
                        + {16'h0, BOARD_IP_ADDR[31:16]} + {16'h0, BOARD_IP_ADDR[15:0]}
                        + {16'h0, pc_ip_addr[31:16]}   + {16'h0, pc_ip_addr[15:0]};
    wire [31:0] csum_s1 = {16'h0, csum_s0[15:0]} + {16'h0, csum_s0[31:16]};
    wire [31:0] csum_s2 = {16'h0, csum_s1[15:0]} + {16'h0, csum_s1[31:16]};
    wire [15:0] ip_checksum = ~csum_s2[15:0];

    // 发送字节选择
    reg [7:0] tx_byte;
    always @* begin
        if (cnt < 16'd7) begin
            tx_byte = 8'h55;
        end else if (cnt == 16'd7) begin
            tx_byte = 8'hD5;
        end else if (cnt < 16'd14) begin
            tx_byte = pc_mac_addr[((cnt - 16'd8) << 3) +: 8];
        end else if (cnt < 16'd20) begin
            tx_byte = BOARD_MAC_ADDR[((cnt - 16'd14) << 3) +: 8];
        end else if (cnt < 16'd22) begin
            tx_byte = (cnt == 16'd20) ? 8'h08 : 8'h00;
        end else if (cnt < 16'd24) begin
            tx_byte = (cnt == 16'd22) ? 8'h45 : 8'h00;
        end else if (cnt < 16'd26) begin
            tx_byte = (cnt == 16'd24) ? total_len[15:8] : total_len[7:0];
        end else if (cnt < 16'd28) begin
            tx_byte = (cnt == 16'd26) ? ip_id_r[15:8] : ip_id_r[7:0];
        end else if (cnt < 16'd30) begin
            tx_byte = (cnt == 16'd28) ? 8'h40 : 8'h00;
        end else if (cnt == 16'd30) begin
            tx_byte = 8'h40;
        end else if (cnt == 16'd31) begin
            tx_byte = 8'h11;
        end else if (cnt < 16'd34) begin
            tx_byte = (cnt == 16'd32) ? ip_csum_r[15:8] : ip_csum_r[7:0];
        end else if (cnt < 16'd38) begin
            tx_byte = BOARD_IP_ADDR[((cnt - 16'd34) << 3) +: 8];
        end else if (cnt < 16'd42) begin
            tx_byte = pc_ip_addr[((cnt - 16'd38) << 3) +: 8];
        end else if (cnt < 16'd44) begin
            tx_byte = (cnt == 16'd42) ? board_port[15:8] : board_port[7:0];
        end else if (cnt < 16'd46) begin
            tx_byte = (cnt == 16'd44) ? pc_port[15:8] : pc_port[7:0];
        end else if (cnt < 16'd48) begin
            tx_byte = (cnt == 16'd46) ? (16'd8 + amount_r)[15:8] : (16'd8 + amount_r)[7:0];
        end else if (cnt < 16'd50) begin
            tx_byte = 8'h00;
        end else if (cnt < fcs_start) begin
            tx_byte = (cnt < payload_end) ? s_axis.tdata : 8'h00;
        end else begin
            tx_byte = crc32_r[((cnt - fcs_start) << 3) +: 8];
        end
    end

    // 输出
    assign m_axis.tvalid = tx_active;
    assign m_axis.tlast  = tx_active;
    assign m_axis.tdata  = tx_byte;
    assign m_axis.tuser  = 1'b0;
    assign s_axis.tready = payload_region && m_axis.tready;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            tx_active  <= 1'b0;
            cnt        <= 16'd0;
            ip_id_r    <= 16'd0;
            ip_csum_r  <= 16'd0;
            crc32_r    <= 32'h0;
        end else if (frame_start) begin
            tx_active  <= 1'b1;
            cnt        <= 16'd0;
            ip_id_r    <= ip_id_next;
            ip_csum_r  <= ip_checksum;
        end else if (tx_active) begin
            if (payload_region && m_axis.tready && !(s_axis.tvalid && s_axis.tlast)) begin
                // 应用数据断流, 帧已无法恢复, 中止
                tx_active <= 1'b0;
            end else if (tx_advance) begin
                if (cnt == total_bytes - 16'd1) begin
                    tx_active <= 1'b0;
                    cnt       <= 16'd0;
                end else begin
                    cnt <= cnt + 16'd1;
                end
            end
            if (crc_end) begin
                crc32_r <= crc32;
            end
        end
    end

    wire [31:0] crc32;
    wire        crc32_valid;

    CRC32_D8 u_crc32_d8(
        .sys_clk       ( sys_clk    ),
        .sys_rst_n     ( sys_rst_n  ),
        .data          ( tx_byte    ),
        .crc_start     ( crc_start  ),
        .crc_en        ( crc_en     ),
        .crc_end       ( crc_end    ),
        .crc32         ( crc32      ),
        .crc32_valid   ( crc32_valid)
    );

endmodule
