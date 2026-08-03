`include "axis.svh"

// rmii_axis: RMII PHY(LAN8720A) <-> AXI-Stream 透明转换
// 数据通路: UDP核 <-> AXIS <-> RMII
// 帧边界约定(tlast 为电平信号):
//   tlast 高电平 = 帧开始/帧内, 上升沿 = 帧开始
//   tlast 低电平 = 帧结束,     下降沿 = 帧结束
// RX: m_rmii_rx_axis_net 忽略 tready, 字节有效时拉高 tvalid
// TX: s_rmii_tx_axis_net 由本模块产生 tready 反压
// 透传模式: 前导码/SFD/CRC 均由上层负责, 本模块不删减任何数据

module rmii_axis(
    input   wire            rstn,
    input   wire            rmii_clk,                   // 50 MHz
    // PHY RX
    input   wire            rmii_crs_dv,
    input   wire    [1:0]   rmii_rxdata,
    // PHY TX
    output  reg             rmii_txen,
    output  wire    [1:0]   rmii_txdata,
    output  wire            rmii_rst,                   // PHY 复位, 恒高
    // AXIS
    axis.master             m_rmii_rx_axis_net,         // tlast: 帧电平; 忽略 tready
    axis.slave              s_rmii_tx_axis_net          // tlast: 帧电平; 下降沿结束
);

    parameter TX_IFG_CLKS   = 8'd48;                    // 帧间间隔 96 bit time @ 50MHz, 0 为不强制

//=============================================================
// RX: 2bit 数据组(4 个时钟拼 1 字节) -> 8bit 字节, 跳过帧前空闲 0
//=============================================================
    logic       rx_started;
    logic       rx_in_frame;
    logic [1:0] rx_nib_cnt;
    logic [7:0] rx_shift;

    assign m_rmii_rx_axis_net.tlast  = rx_in_frame;
    assign m_rmii_rx_axis_net.tvalid = rx_in_frame && (rx_nib_cnt == 2'd3);
    assign m_rmii_rx_axis_net.tdata  = rx_shift;
    assign m_rmii_rx_axis_net.tuser  = 1'b0;

    always_ff @(posedge rmii_clk or negedge rstn) begin
        if (!rstn) begin
            rx_started  <= 1'b0;
            rx_in_frame <= 1'b0;
            rx_nib_cnt  <= 2'd0;
            rx_shift    <= 8'h0;
        end else if (!rmii_crs_dv) begin
            rx_started  <= 1'b0;
            rx_in_frame <= 1'b0;
            rx_nib_cnt  <= 2'd0;
        end else if (!rx_started) begin
            if (rmii_rxdata != 2'b00) begin
                rx_started  <= 1'b1;
                rx_in_frame <= 1'b1;
                rx_nib_cnt  <= 2'd0;
                rx_shift    <= {6'b00, rmii_rxdata};
            end
        end else begin
            case (rx_nib_cnt)
                2'd0:    rx_shift <= {rx_shift[7:4], rmii_rxdata, rx_shift[1:0]};
                2'd1:    rx_shift <= {rx_shift[7:6], rmii_rxdata, rx_shift[3:0]};
                2'd2:    rx_shift <= {rmii_rxdata, rx_shift[5:0]};
                default: rx_shift <= {rx_shift[7:2], rmii_rxdata};
            endcase
            rx_nib_cnt <= (rx_nib_cnt == 2'd3) ? 2'd0 : rx_nib_cnt + 2'd1;
        end
    end

//=============================================================
// TX: 8bit 字节 -> 2bit 数据组, 每字节 4 拍发出
//     帧内数据必须连续, 若 tvalid 中途断流则本帧作废丢弃
//=============================================================
    logic       tx_buf_valid;
    logic [1:0] tx_nib_cnt;
    logic [7:0] tx_shift;
    logic [7:0] tx_ifg_cnt;
    logic       tx_abort;

    wire tx_can_accept = (tx_nib_cnt == 2'd3) || !tx_buf_valid;
    wire tx_accept = s_rmii_tx_axis_net.tvalid && s_rmii_tx_axis_net.tlast &&
                     (tx_ifg_cnt == 8'd0) && tx_can_accept;

    assign s_rmii_tx_axis_net.tready = tx_abort || (tx_can_accept && (tx_ifg_cnt == 8'd0));
    assign rmii_txdata = tx_shift[1:0];
    assign rmii_rst    = 1'b1;

    always_ff @(posedge rmii_clk or negedge rstn) begin
        if (!rstn) begin
            tx_buf_valid <= 1'b0;
            tx_nib_cnt   <= 2'd0;
            tx_shift     <= 8'h0;
            rmii_txen    <= 1'b0;
            tx_ifg_cnt   <= 8'd0;
            tx_abort     <= 1'b0;
        end else begin
            if (tx_ifg_cnt != 8'd0)
                tx_ifg_cnt <= tx_ifg_cnt - 8'd1;

            if (tx_abort) begin
                // 丢弃本帧剩余数据, 直到 tlast 下降
                if (!s_rmii_tx_axis_net.tlast) begin
                    tx_abort   <= 1'b0;
                    tx_ifg_cnt <= TX_IFG_CLKS;
                end
            end else if (tx_accept) begin
                tx_shift     <= s_rmii_tx_axis_net.tdata;
                tx_nib_cnt   <= 2'd0;
                tx_buf_valid <= 1'b1;
                rmii_txen    <= 1'b1;
            end else if (tx_buf_valid) begin
                if (tx_nib_cnt == 2'd3) begin
                    tx_buf_valid <= 1'b0;
                    tx_nib_cnt   <= 2'd0;
                    tx_shift     <= 8'h0;
                    if (!s_rmii_tx_axis_net.tlast) begin
                        rmii_txen  <= 1'b0;
                        tx_ifg_cnt <= TX_IFG_CLKS;
                    end else begin
                        // tvalid 断流, 帧已无法恢复, 中止发送
                        rmii_txen <= 1'b0;
                        tx_abort  <= 1'b1;
                    end
                end else begin
                    tx_shift   <= {2'b00, tx_shift[7:2]};
                    tx_nib_cnt <= tx_nib_cnt + 2'd1;
                end
            end
        end
    end

endmodule
