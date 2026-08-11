`include "axis.svh"

// gmii_axis: GMII PHY <-> AXI-Stream 透明转换
// 数据通路: ETH核 <-> AXIS <-> GMII
// 帧边界约定(tlast 为电平信号):
//   tlast 高电平 = 帧开始/帧内, 上升沿 = 帧开始
//   tlast 低电平 = 帧结束,     下降沿 = 帧结束
// RX: m_gmii_rx_axis_net 忽略 tready, 字节有效时拉高 tvalid
//     RXDV 拉低后进入采样窗口, 窗口内补采的字节照常 tvalid 送出
// TX: s_gmii_tx_axis_net 由本模块产生 tready 反压
// 透传模式: 前导码/SFD/CRC 均由上层负责
// GMII 时序: 8bit 数据总线, 每字节 1 拍 @ 125 MHz (1 Gbps)
// TX 数据通路为 1 拍流水: accept 拍锁存字节, 下一拍输出, 帧内无气泡

module gmii_axis(
    input   wire            rstn,
    input   wire            gmii_clk,                   // 125 MHz
    // PHY RX
    input   wire            gmii_rxdv,
    input   wire    [7:0]   gmii_rxd,
    // PHY TX
    output  reg             gmii_txen,
    output  wire    [7:0]   gmii_txd,
    output  wire            gmii_rst,                   // PHY 复位, 恒高
    // AXIS
    axis.master             m_gmii_rx_axis_net,         // tlast: 帧电平; 忽略 tready
    axis.slave              s_gmii_tx_axis_net          // tlast: 帧电平; 下降沿结束
);

    parameter RX_TAIL_CLKS  = 4'd0;                     // RXDV 拉低后继续采样确认帧结束的时钟数
                                                        // GMII 规范 RXDV 在末字节后一拍才拉低, 0 即可;
                                                        // 若所用 PHY 提前拉低, 改 1~2 补采尾部字节
    parameter TX_IFG_CLKS   = 8'd12;                    // 帧间间隔 96 bit time @ 125MHz, 0 为不强制

//=============================================================
// RX: 8bit 字节每拍一个, 跳过帧前空闲 0
//     帧尾处理: RXDV 拉低后进入采样窗口, 窗口内补采的字节
//     照常 tvalid 送出, 窗口结束确认无剩余数据后才拉低 tlast
//=============================================================
    logic       rx_started;
    logic       rx_in_frame;
    logic       rx_tail;
    logic [3:0] rx_tail_cnt;
    logic [7:0] rx_shift;
    logic       rx_byte_valid;

    assign m_gmii_rx_axis_net.tlast  = rx_in_frame;
    assign m_gmii_rx_axis_net.tvalid = rx_byte_valid;
    assign m_gmii_rx_axis_net.tdata  = rx_shift;
    assign m_gmii_rx_axis_net.tuser  = 1'b0;

    always_ff @(posedge gmii_clk or negedge rstn) begin
        if (!rstn) begin
            rx_started    <= 1'b0;
            rx_in_frame   <= 1'b0;
            rx_tail       <= 1'b0;
            rx_tail_cnt   <= 4'd0;
            rx_shift      <= 8'h0;
            rx_byte_valid <= 1'b0;
        end else begin
            rx_byte_valid <= 1'b0;
            if (!gmii_rxdv) begin
                if (rx_tail) begin
                    // 采样窗口内, 继续补采剩余字节
                    if (rx_tail_cnt != 4'd0) begin
                        rx_tail_cnt   <= rx_tail_cnt - 4'd1;
                        rx_shift      <= gmii_rxd;
                        rx_byte_valid <= 1'b1;
                    end else begin
                        // 窗口结束, 确认帧结束
                        rx_tail     <= 1'b0;
                        rx_in_frame <= 1'b0;
                        rx_started  <= 1'b0;
                    end
                end else if (rx_in_frame) begin
                    // RXDV 先拉低: 进入采样窗口
                    rx_tail     <= 1'b1;
                    rx_tail_cnt <= (RX_TAIL_CLKS == 4'd0) ? 4'd0 : RX_TAIL_CLKS - 4'd1;
                    if (RX_TAIL_CLKS != 4'd0) begin
                        rx_shift      <= gmii_rxd;
                        rx_byte_valid <= 1'b1;
                    end
                end
                // 未成帧, 保持空闲
            end else if (rx_in_frame) begin
                // RXDV 高电平, 正常采样
                rx_shift      <= gmii_rxd;
                rx_byte_valid <= 1'b1;
            end else if (!rx_started) begin
                if (gmii_rxd != 8'h00) begin
                    rx_started    <= 1'b1;
                    rx_in_frame   <= 1'b1;
                    rx_shift      <= gmii_rxd;
                    rx_byte_valid <= 1'b1;
                end
            end
        end
    end

//=============================================================
// TX: 8bit 字节 -> 8bit 总线, 每字节 1 拍发出
//     数据通路为 1 拍流水: accept 拍锁存字节, 下一拍输出,
//     帧内 tready 恒高, 字节连续发出无气泡
//     若 tvalid 中途断流则本帧作废丢弃
// tready 同一拍读取 tdata
//=============================================================
    logic       tx_buf_valid;
    logic [7:0] tx_shift;
    logic [7:0] tx_ifg_cnt;
    logic       tx_abort;
    logic       tx_frame_active;

    wire tx_accept = s_gmii_tx_axis_net.tvalid && s_gmii_tx_axis_net.tlast &&
                     !tx_abort && (tx_ifg_cnt == 8'd0);

    assign s_gmii_tx_axis_net.tready = tx_abort || ( (tx_ifg_cnt == 8'd0) &&
                                      (s_gmii_tx_axis_net.tlast || !tx_frame_active) );
    assign gmii_txd = tx_shift;
    assign gmii_rst = 1'b1;

    always_ff @(posedge gmii_clk or negedge rstn) begin
        if (!rstn) begin
            tx_buf_valid    <= 1'b0;
            tx_shift        <= 8'h0;
            gmii_txen       <= 1'b0;
            tx_ifg_cnt      <= 8'd0;
            tx_abort        <= 1'b0;
            tx_frame_active <= 1'b0;
        end else begin
            if (tx_ifg_cnt != 8'd0)
                tx_ifg_cnt <= tx_ifg_cnt - 8'd1;

            if (tx_abort) begin
                // 丢弃本帧剩余数据, 直到 tlast 下降
                if (!s_gmii_tx_axis_net.tlast) begin
                    tx_abort        <= 1'b0;
                    tx_frame_active <= 1'b0;
                    tx_ifg_cnt      <= TX_IFG_CLKS;
                end
            end else if (tx_accept) begin
                tx_shift        <= s_gmii_tx_axis_net.tdata;
                tx_buf_valid    <= 1'b1;
                tx_frame_active <= 1'b1;
                gmii_txen       <= 1'b1;
            end else if (tx_buf_valid) begin
                // 本拍字节正在总线输出, 下一拍为空闲/帧结束/中止
                tx_buf_valid <= 1'b0;
                if (!s_gmii_tx_axis_net.tlast) begin
                    tx_frame_active <= 1'b0;
                    gmii_txen       <= 1'b0;
                    tx_ifg_cnt      <= TX_IFG_CLKS;
                end else begin
                    // tvalid 断流, 帧已无法恢复, 中止发送
                    gmii_txen <= 1'b0;
                    tx_abort  <= 1'b1;
                end
            end
        end
    end

endmodule
