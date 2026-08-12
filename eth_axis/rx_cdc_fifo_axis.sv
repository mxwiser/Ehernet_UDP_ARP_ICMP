`include "axis.svh"

// rx_cdc_fifo_axis: RX 数据通路跨时钟域 (rmii_clk -> clk)
// s_rx 在 rmii_clk 域(来自 rmii_axis), m_rx 在 clk 域(送往 udp_axis_rx / eth_axis)
// tlast 为帧电平信号(高电平 = 帧内), 逐字节与 tdata 一起存入异步 FIFO,
// 读侧原样还原 tlast 电平, 帧边界不失真
// dcfifo 内部用格雷码指针 + 双触发器同步, 消除跨时钟域亚稳态, 自动映射为 M9K

module rx_cdc_fifo_axis(
    input logic rstn,
    input logic clk,
    input logic rmii_clk,
    axis.slave s_rx,
    axis.master m_rx
);

    parameter DEPTH = 1024;

    logic        wr_full;
    logic        rd_empty;
    logic [8:0]  rd_q;
    logic        rd_req;
    logic        out_valid;
    logic [7:0]  out_data;
    logic        out_last;

// ================================ 写侧: rmii_clk 域 ================================
    assign s_rx.tready = !wr_full;

    dcfifo #(
        .width                     (9),
        .rwidth                    (9),
        .depth                     (DEPTH)
    ) u_rx_dcfifo (
        .wrclk   (rmii_clk),
        .rst     (1'b0),
        .wrreq   (s_rx.tvalid && !wr_full),
        .data    ({s_rx.tlast, s_rx.tdata}),
        .wrfull  (wr_full),
        .rdclk   (clk),
        .aclr    (!rstn),
        .rdreq   (rd_req),
        .q       (rd_q),
        .rdempty (rd_empty)
    );

// ================================ 读侧: clk 域 ================================
// rd_req 为高时, 该拍 rd_q 即为本拍被弹出的数据, 直接寄存进输出寄存器
// out_valid && tready 时输出与弹出同拍进行, 支持背靠背连续传输
    assign rd_req = !rd_empty && (!out_valid || m_rx.tready);

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            out_valid <= 1'b0;
            out_data  <= 8'h0;
            out_last  <= 1'b0;
        end else if (rd_req) begin
            out_valid <= 1'b1;
            out_data  <= rd_q[7:0];
            out_last  <= rd_q[8];
        end else if (out_valid && !m_rx.tready) begin
            out_valid <= out_valid;
        end else begin
            out_valid <= 1'b0;
        end
    end

    assign m_rx.tvalid = out_valid;
    assign m_rx.tdata  = out_data;
    assign m_rx.tlast  = out_last;
    assign m_rx.tuser  = 1'b0;

endmodule
