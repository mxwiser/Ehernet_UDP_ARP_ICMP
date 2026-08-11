`include "axis.svh"

// mii_axis: MII PHY <-> AXI-Stream 透明转换
// 数据通路: ETH核 <-> AXIS <-> MII
// 帧边界约定(tlast 为电平信号):
//   tlast 高电平 = 帧开始/帧内, 上升沿 = 帧开始
//   tlast 低电平 = 帧结束,     下降沿 = 帧结束
// RX: m_mii_rx_axis_net 忽略 tready, 字节有效时拉高 tvalid
//     RXDV 拉低后进入采样窗口, 窗口内 tlast 保持高电平继续拼字节,
//     确认无剩余数据后才拉低 tlast
// TX: s_mii_tx_axis_net 由本模块产生 tready 反压
// 透传模式: 前导码/SFD/CRC 均由上层负责
// MII 时序: 4bit 数据总线, 每字节 2 拍, 半字节 MSB 在前
//           100M: 25 MHz, 10M: 2.5 MHz

module mii_axis(
    input   wire            rstn,
    input   wire            mii_clk,                    // 25 MHz @ 100M / 2.5 MHz @ 10M
    // PHY RX
    input   wire            mii_rxdv,
    input   wire    [3:0]   mii_rxd,
    // PHY TX
    output  reg             mii_txen,
    output  wire    [3:0]   mii_txd,
    output  wire            mii_rst,                    // PHY 复位, 恒高
    // AXIS
    axis.master             m_mii_rx_axis_net,          // tlast: 帧电平; 忽略 tready
    axis.slave              s_mii_tx_axis_net           // tlast: 帧电平; 下降沿结束
);

    parameter RX_TAIL_CLKS  = 4'd2;                     // RXDV 拉低后继续采样确认帧结束的时钟数
    parameter TX_IFG_CLKS   = 8'd24;                    // 帧间间隔 96 bit time @ 25MHz, 0 为不强制

//=============================================================
// RX: 4bit 数据组(2 个时钟拼 1 字节) -> 8bit 字节, 跳过帧前空闲 0
//     半字节按 MII 规范 MSB 在前, 先到的半字节放高 4 位
//     帧尾处理: RXDV 拉低后进入采样窗口:
//       - tlast 保持高电平, tvalid 立即拉低
//       - 窗口内继续拼接数据组, 拼满的字节照常 tvalid 送出
//       - 窗口结束确认无剩余数据后, 才拉低 tlast
//=============================================================
    logic       rx_started;
    logic       rx_in_frame;
    logic       rx_tail;
    logic [3:0] rx_tail_cnt;
    logic [1:0] rx_nib_cnt;                             // 半字节计数: 2 个半字节拼 1 字节
    logic [7:0] rx_shift;

    function [7:0] rx_shift_in(input [7:0] sh,
                               input [1:0] cnt,
                               input [3:0] d);
        case (cnt)
            2'd0:    rx_shift_in = {sh[7:4], d};        // 第 2 半字节 -> 低 4 位
            default: rx_shift_in = {d, sh[3:0]};        // 下一字节第 1 半字节 -> 高 4 位
        endcase
    endfunction

    assign m_mii_rx_axis_net.tlast  = rx_in_frame;
    assign m_mii_rx_axis_net.tvalid = rx_in_frame && (rx_nib_cnt == 2'd1);
    assign m_mii_rx_axis_net.tdata  = rx_shift;
    assign m_mii_rx_axis_net.tuser  = 1'b0;

    always_ff @(posedge mii_clk or negedge rstn) begin
        if (!rstn) begin
            rx_started  <= 1'b0;
            rx_in_frame <= 1'b0;
            rx_tail     <= 1'b0;
            rx_tail_cnt <= 4'd0;
            rx_nib_cnt  <= 2'd0;
            rx_shift    <= 8'h0;
        end else if (!mii_rxdv) begin
            if (rx_tail) begin
                // 采样窗口内, 继续拼接剩余数据
                if (rx_tail_cnt != 4'd0) begin
                    rx_tail_cnt <= rx_tail_cnt - 4'd1;
                    rx_shift    <= rx_shift_in(rx_shift, rx_nib_cnt, mii_rxd);
                    rx_nib_cnt  <= (rx_nib_cnt == 2'd1) ? 2'd0 : rx_nib_cnt + 2'd1;
                end else begin
                    // 窗口结束, 确认帧结束, 丢弃未拼满的半字节
                    rx_tail     <= 1'b0;
                    rx_in_frame <= 1'b0;
                    rx_started  <= 1'b0;
                    rx_nib_cnt  <= 2'd0;
                end
            end else if (rx_in_frame) begin
                // RXDV 先拉低: 进入采样窗口, 立即采样本拍剩余数据
                rx_tail     <= 1'b1;
                rx_tail_cnt <= RX_TAIL_CLKS - 4'd1;
                rx_shift    <= rx_shift_in(rx_shift, rx_nib_cnt, mii_rxd);
                rx_nib_cnt  <= (rx_nib_cnt == 2'd1) ? 2'd0 : rx_nib_cnt + 2'd1;
            end
            // 未成帧, 保持空闲
        end else if (rx_in_frame) begin
            // RXDV 高电平, 正常拼接
            rx_shift   <= rx_shift_in(rx_shift, rx_nib_cnt, mii_rxd);
            rx_nib_cnt <= (rx_nib_cnt == 2'd1) ? 2'd0 : rx_nib_cnt + 2'd1;
        end else if (!rx_started) begin
            if (mii_rxd != 4'b0000) begin
                rx_started  <= 1'b1;
                rx_in_frame <= 1'b1;
                rx_nib_cnt  <= 2'd0;
                rx_shift    <= {mii_rxd, 4'b0000};
            end
        end
    end

//=============================================================
// TX: 8bit 字节 -> 4bit 数据组(半字节 MSB 在前), 每字节 2 拍发出
//     帧内数据必须连续, 若 tvalid 中途断流则本帧作废丢弃
// tready 同一拍读取 tdata
//=============================================================
    logic       tx_buf_valid;
    logic [1:0] tx_nib_cnt;
    logic [7:0] tx_shift;
    logic [7:0] tx_ifg_cnt;
    logic       tx_abort;

    wire tx_can_accept = (tx_nib_cnt == 2'd1) || !tx_buf_valid;
    wire tx_accept = s_mii_tx_axis_net.tvalid && s_mii_tx_axis_net.tlast &&
                     (tx_ifg_cnt == 8'd0) && tx_can_accept;

    assign s_mii_tx_axis_net.tready = tx_abort || (tx_can_accept && (tx_ifg_cnt == 8'd0));
    assign mii_txd = tx_shift[7:4];
    assign mii_rst = 1'b1;

    always_ff @(posedge mii_clk or negedge rstn) begin
        if (!rstn) begin
            tx_buf_valid <= 1'b0;
            tx_nib_cnt   <= 2'd0;
            tx_shift     <= 8'h0;
            mii_txen     <= 1'b0;
            tx_ifg_cnt   <= 8'd0;
            tx_abort     <= 1'b0;
        end else begin
            if (tx_ifg_cnt != 8'd0)
                tx_ifg_cnt <= tx_ifg_cnt - 8'd1;

            if (tx_abort) begin
                // 丢弃本帧剩余数据, 直到 tlast 下降
                if (!s_mii_tx_axis_net.tlast) begin
                    tx_abort   <= 1'b0;
                    tx_ifg_cnt <= TX_IFG_CLKS;
                end
            end else if (tx_accept) begin
                tx_shift     <= s_mii_tx_axis_net.tdata;
                tx_nib_cnt   <= 2'd0;
                tx_buf_valid <= 1'b1;
                mii_txen     <= 1'b1;
            end else if (tx_buf_valid) begin
                if (tx_nib_cnt == 2'd1) begin
                    // 低半字节正在总线, 本拍完成 1 字节
                    tx_buf_valid <= 1'b0;
                    tx_nib_cnt   <= 2'd0;
                    tx_shift     <= 8'h0;
                    if (!s_mii_tx_axis_net.tlast) begin
                        mii_txen  <= 1'b0;
                        tx_ifg_cnt <= TX_IFG_CLKS;
                    end else begin
                        // tvalid 断流, 帧已无法恢复, 中止发送
                        mii_txen <= 1'b0;
                        tx_abort  <= 1'b1;
                    end
                end else begin
                    // 高半字节已发出, 左移准备输出低半字节
                    tx_shift   <= {tx_shift[3:0], 4'b0000};
                    tx_nib_cnt <= tx_nib_cnt + 2'd1;
                end
            end
        end
    end

endmodule
