// udp_axis_rx: 网络 AXIS 流 -> UDP 数据 AXIS 流 (普通端口版)
// 网络流为透传模式(含前导码/SFD/CRC), tlast 为帧电平(帧内高电平)
// 只处理目的为本机的 IPv4/UDP 帧, 其余帧(广播、ARP、非UDP)一律丢弃
// 应用层输出仅含 UDP 数据, tlast 为数据报电平, 忽略 tready(无背压)
module udp_axis_rx(
    input  wire         sys_clk,
    input  wire         sys_rst_n,

    // 网络接收流(来自 eth_arp_axis)
    input  wire [7:0]   axis_s_tdata,
    input  wire         axis_s_tvalid,
    input  wire         axis_s_tlast,
    output wire         axis_s_tready,

    // UDP 数据输出(应用层)
    output wire [7:0]   axis_m_tdata,
    output wire         axis_m_tvalid,
    output wire         axis_m_tlast,
    input  wire         axis_m_tready,

    output reg  [15:0]  udp_rx_amount,       // 本包 UDP 数据长度
    output reg  [15:0]  pc_port,             // 学习到的对端端口
    output reg  [15:0]  board_port,          // 本机目的端口

    output wire         udp_rx_pulse         // 调试: 解析出 UDP 数据并输出(每字节1拍)
);

    parameter BOARD_MAC_ADDR = 48'h00_11_22_33_44_55;
    parameter BOARD_IP_ADDR  = 32'hA9_FE_01_17;

    localparam IDLE = 4'd0, SFD = 4'd1, MAC = 4'd2, TYPE = 4'd3, IP = 4'd4,
               UDP = 4'd5, DATA = 4'd6, CRC = 4'd7, DROP = 4'd8;

    reg [3:0]  state;
    reg [2:0]  cnt_pre;
    reg [3:0]  cnt_mac;
    reg [1:0]  cnt_type;
    reg [5:0]  cnt_ip;
    reg [2:0]  cnt_udp;
    reg [15:0] cnt_data;
    reg [1:0]  cnt_crc;
    reg        tlast_d;

    reg [47:0] des_mac;
    reg [31:0] des_ip;
    reg [15:0] src_port;
    reg [15:0] des_port;
    reg [15:0] udp_len;
    reg [5:0]  ip_header_len;
    reg [15:0] data_len;

    wire rx_frame_end = tlast_d && !axis_s_tlast;

    // RX 无背压
    assign axis_s_tready = 1'b1;
    assign axis_m_tdata  = axis_s_tdata;
    assign axis_m_tvalid = (state == DATA) && axis_s_tvalid;
    assign axis_m_tlast  = (state == DATA);
    assign udp_rx_pulse  = (state == DATA) && axis_s_tvalid;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            tlast_d <= 1'b0;
        end else begin
            tlast_d <= axis_s_tlast;
        end
    end

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            state <= IDLE;
        end else if (rx_frame_end) begin
            state <= IDLE;
        end else case (state)
            IDLE: begin
                if (axis_s_tvalid) begin
                    if (axis_s_tdata == 8'h55) begin
                        if (cnt_pre == 3'd6) begin
                            state <= SFD;
                        end else begin
                            cnt_pre <= cnt_pre + 3'd1;
                        end
                    end else begin
                        cnt_pre <= 3'd0;
                    end
                end
            end
            SFD: begin
                if (axis_s_tvalid) begin
                    if (axis_s_tdata == 8'hD5) begin
                        state <= MAC;
                    end else if (axis_s_tdata == 8'h55) begin
                        state <= SFD;            // 多余的前导 0x55, 继续等 D5
                    end else begin
                        state <= DROP;
                    end
                end
            end
            MAC: begin
                if (axis_s_tvalid) begin
                    case (cnt_mac)
                        4'd0:  des_mac[47:40] <= axis_s_tdata;
                        4'd1:  des_mac[39:32] <= axis_s_tdata;
                        4'd2:  des_mac[31:24] <= axis_s_tdata;
                        4'd3:  des_mac[23:16] <= axis_s_tdata;
                        4'd4:  des_mac[15:8]  <= axis_s_tdata;
                        4'd5:  des_mac[7:0]   <= axis_s_tdata;
                        default: ;              // SA 字节不关心
                    endcase
                    if (cnt_mac == 4'd11) begin
                        if (des_mac == BOARD_MAC_ADDR) begin
                            state <= TYPE;
                        end else begin
                            state <= DROP;
                        end
                    end else begin
                        cnt_mac <= cnt_mac + 4'd1;
                    end
                end
            end
            TYPE: begin
                if (axis_s_tvalid) begin
                    if (cnt_type == 2'd0) begin
                        if (axis_s_tdata != 8'h08) begin
                            state <= DROP;
                        end
                    end else begin
                        if (axis_s_tdata != 8'h00) begin
                            state <= DROP;
                        end else begin
                            state <= IP;
                        end
                    end
                    cnt_type <= cnt_type + 2'd1;
                end
            end
            IP: begin
                if (axis_s_tvalid) begin
                    if (cnt_ip == 6'd0 && (axis_s_tdata[7:4] != 4'h4 || axis_s_tdata[3:0] < 4'd5)) begin
                        state <= DROP;
                    end else if (cnt_ip == 6'd9 && axis_s_tdata != 8'd17) begin
                        state <= DROP;
                    end else if (cnt_ip == 6'd19 && {des_ip[31:8], axis_s_tdata} != BOARD_IP_ADDR) begin
                        state <= DROP;
                    end else if (cnt_ip == ip_header_len - 6'd1) begin
                        state <= UDP;
                    end else begin
                        cnt_ip <= cnt_ip + 6'd1;
                    end

                    case (cnt_ip)
                        6'd0:  ip_header_len <= {2'b00, axis_s_tdata[3:0]} << 2;
                        6'd16: des_ip[31:24] <= axis_s_tdata;
                        6'd17: des_ip[23:16] <= axis_s_tdata;
                        6'd18: des_ip[15:8]  <= axis_s_tdata;
                        6'd19: des_ip[7:0]   <= axis_s_tdata;
                    endcase
                end
            end
            UDP: begin
                if (axis_s_tvalid) begin
                    case (cnt_udp)
                        3'd0: src_port[15:8] <= axis_s_tdata;
                        3'd1: src_port[7:0]  <= axis_s_tdata;
                        3'd2: des_port[15:8] <= axis_s_tdata;
                        3'd3: des_port[7:0]  <= axis_s_tdata;
                        3'd4: udp_len[15:8]  <= axis_s_tdata;
                        3'd5: udp_len[7:0]   <= axis_s_tdata;
                    endcase
                    if (cnt_udp == 3'd7) begin
                        state <= DATA;
                        data_len      <= udp_len - 16'd8;
                        udp_rx_amount <= udp_len - 16'd8;
                        pc_port       <= src_port;
                        board_port    <= des_port;
                    end else begin
                        cnt_udp <= cnt_udp + 3'd1;
                    end
                end
            end
            DATA: begin
                if (axis_s_tvalid) begin
                    if (cnt_data == data_len - 16'd1) begin
                        state <= CRC;
                    end else begin
                        cnt_data <= cnt_data + 16'd1;
                    end
                end
            end
            CRC: begin
                if (axis_s_tvalid) begin
                    if (cnt_crc == 2'd3) begin
                        state <= IDLE;
                    end else begin
                        cnt_crc <= cnt_crc + 2'd1;
                    end
                end
            end
            default: state <= IDLE;
        endcase
    end

endmodule
