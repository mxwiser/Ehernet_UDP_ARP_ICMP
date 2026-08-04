// eth_axis: 以太网 UDP 顶层 (普通端口版)
// 数据通路:
//   RMII PHY <-> rmii_axis <-> eth_arp_axis <-> udp_axis_rx/udp_axis_tx <-> 应用层
// 应用层接口(AXIS 普通信号):
//   udp_rx_*  : 收到的 UDP 数据(仅数据, 无 IP/UDP 头),
//               tlast 为数据报电平, 忽略 tready
//   udp_tx_*  : 待发送的 UDP 数据, tlast 为数据报电平, 带 tready 反压
//   udp_rx_amount/udp_tx_amount: UDP 数据长度(不含 8 字节 UDP 头)
// ARP 自动应答, 对端 MAC/IP 由 eth_arp_axis 学习, 对端端口由 udp_axis_rx 学习
module eth_axis(
    input  wire        sys_rst_n,
    input  wire        rmii_clk,
    input  wire        rmii_rxdv,
    input  wire [1:0]  rmii_rxdata,
    output wire        rmii_txen,
    output wire [1:0]  rmii_txdata,
    output wire        rmii_rst,

    // UDP 应用层 AXIS
    output wire [7:0]  udp_rx_tdata,
    output wire        udp_rx_tvalid,
    output wire        udp_rx_tlast,
    input  wire        udp_rx_tready,          // 当前忽略
    output wire [15:0] udp_rx_amount,
    input  wire [7:0]  udp_tx_tdata,
    input  wire        udp_tx_tvalid,
    input  wire        udp_tx_tlast,
    output wire        udp_tx_tready,
    input  wire [15:0] udp_tx_amount,

    // 调试输出(1拍脉冲)
    output reg         dbg_frame_rx,    // 收到一个完整帧
    output wire        dbg_arp_req,     // 收到有效 ARP 请求
    output wire        dbg_arp_reply,   // ARP 回复发送完毕
    output wire        dbg_udp_rx,      // 解析出 UDP 数据并输出
    output wire        dbg_udp_tx       // UDP 回复帧发送完毕
);

    // 网络层信号
    wire [7:0]  rx_net_tdata;
    wire        rx_net_tvalid;
    wire        rx_net_tlast;
    wire [7:0]  tx_net_tdata;
    wire        tx_net_tvalid;
    wire        tx_net_tlast;
    wire        tx_net_tready;

    // ARP <-> UDP 核
    wire [7:0]  udp_rx_net_tdata;
    wire        udp_rx_net_tvalid;
    wire        udp_rx_net_tlast;
    wire [7:0]  udp_tx_net_tdata;
    wire        udp_tx_net_tvalid;
    wire        udp_tx_net_tlast;
    wire        udp_tx_net_tready;

    wire [47:0] pc_mac_addr;
    wire [31:0] pc_ip_addr;
    wire [15:0] pc_port;
    wire [15:0] board_port;

    // 帧结束脉冲(调试)
    reg net_rx_tlast_d;
    always @(posedge rmii_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            net_rx_tlast_d <= 1'b0;
            dbg_frame_rx   <= 1'b0;
        end else begin
            net_rx_tlast_d <= rx_net_tlast;
            dbg_frame_rx   <= net_rx_tlast_d && !rx_net_tlast;
        end
    end

    rmii_axis u_rmii_axis(
        .rstn           ( sys_rst_n     ),
        .rmii_clk       ( rmii_clk      ),
        .rmii_crs_dv    ( rmii_rxdv     ),
        .rmii_rxdata    ( rmii_rxdata   ),
        .rmii_txen      ( rmii_txen     ),
        .rmii_txdata    ( rmii_txdata   ),
        .rmii_rst       ( rmii_rst      ),
        .m_rx_tdata     ( rx_net_tdata  ),
        .m_rx_tvalid    ( rx_net_tvalid ),
        .m_rx_tlast     ( rx_net_tlast  ),
        .s_tx_tdata     ( tx_net_tdata  ),
        .s_tx_tvalid    ( tx_net_tvalid ),
        .s_tx_tlast     ( tx_net_tlast  ),
        .s_tx_tready    ( tx_net_tready )
    );

    eth_arp_axis u_arp(
        .sys_clk        ( rmii_clk          ),
        .sys_rst_n      ( sys_rst_n         ),
        .rx_net_tdata   ( rx_net_tdata      ),
        .rx_net_tvalid  ( rx_net_tvalid     ),
        .rx_net_tlast   ( rx_net_tlast      ),
        .udp_rx_tdata   ( udp_rx_net_tdata  ),
        .udp_rx_tvalid  ( udp_rx_net_tvalid ),
        .udp_rx_tlast   ( udp_rx_net_tlast  ),
        .udp_tx_tdata   ( udp_tx_net_tdata  ),
        .udp_tx_tvalid  ( udp_tx_net_tvalid ),
        .udp_tx_tlast   ( udp_tx_net_tlast  ),
        .udp_tx_tready  ( udp_tx_net_tready ),
        .tx_net_tdata   ( tx_net_tdata      ),
        .tx_net_tvalid  ( tx_net_tvalid     ),
        .tx_net_tlast   ( tx_net_tlast      ),
        .tx_net_tready  ( tx_net_tready     ),
        .pc_mac_addr    ( pc_mac_addr       ),
        .pc_ip_addr     ( pc_ip_addr        ),
        .arp_req_pulse  ( dbg_arp_req       ),
        .arp_reply_pulse( dbg_arp_reply     )
    );

    udp_axis_rx u_udp_rx(
        .sys_clk        ( rmii_clk          ),
        .sys_rst_n      ( sys_rst_n         ),
        .axis_s_tdata   ( udp_rx_net_tdata  ),
        .axis_s_tvalid  ( udp_rx_net_tvalid ),
        .axis_s_tlast   ( udp_rx_net_tlast  ),
        .axis_s_tready  (                   ),
        .axis_m_tdata   ( udp_rx_tdata      ),
        .axis_m_tvalid  ( udp_rx_tvalid     ),
        .axis_m_tlast   ( udp_rx_tlast      ),
        .axis_m_tready  ( udp_rx_tready     ),
        .udp_rx_amount  ( udp_rx_amount     ),
        .pc_port        ( pc_port           ),
        .board_port     ( board_port        ),
        .udp_rx_pulse   ( dbg_udp_rx        )
    );

    udp_axis_tx u_udp_tx(
        .sys_clk        ( rmii_clk          ),
        .sys_rst_n      ( sys_rst_n         ),
        .axis_s_tdata   ( udp_tx_tdata      ),
        .axis_s_tvalid  ( udp_tx_tvalid     ),
        .axis_s_tlast   ( udp_tx_tlast      ),
        .axis_s_tready  ( udp_tx_tready     ),
        .udp_tx_amount  ( udp_tx_amount     ),
        .axis_m_tdata   ( udp_tx_net_tdata  ),
        .axis_m_tvalid  ( udp_tx_net_tvalid ),
        .axis_m_tlast   ( udp_tx_net_tlast  ),
        .axis_m_tready  ( udp_tx_net_tready ),
        .pc_mac_addr    ( pc_mac_addr       ),
        .pc_ip_addr     ( pc_ip_addr        ),
        .pc_port        ( pc_port           ),
        .board_port     ( board_port        ),
        .udp_tx_done    ( dbg_udp_tx        )
    );

endmodule
