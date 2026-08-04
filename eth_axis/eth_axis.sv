`include "axis.svh"

// eth_axis: 以太网 UDP 顶层 (AXIS 版本)
// 数据通路:
//   RMII PHY <-> rmii_axis <-> eth_arp_axis <-> udp_axis_rx/udp_axis_tx <-> 应用层
// 应用层接口(AXIS):
//   m_udp_rx_axis_net: 收到的 UDP 数据(仅数据, 无 IP/UDP 头),
//                      tlast 为数据报电平, 忽略 tready
//   s_udp_tx_axis_net: 待发送的 UDP 数据, tlast 为数据报电平, 带 tready 反压
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
    axis.master        m_udp_rx_axis_net,
    axis.slave         s_udp_tx_axis_net,
    output wire [15:0] udp_rx_amount,
    input  wire [15:0] udp_tx_amount
);

    axis net_rx();
    axis net_tx();
    axis udp_rx_net();
    axis udp_tx_net();

    wire [47:0] pc_mac_addr;
    wire [31:0] pc_ip_addr;
    wire [15:0] pc_port;
    wire [15:0] board_port;

    rmii_axis u_rmii_axis(
        .rstn               ( sys_rst_n     ),
        .rmii_clk           ( rmii_clk      ),
        .rmii_crs_dv        ( rmii_rxdv     ),
        .rmii_rxdata        ( rmii_rxdata   ),
        .rmii_txen          ( rmii_txen     ),
        .rmii_txdata        ( rmii_txdata   ),
        .rmii_rst           ( rmii_rst      ),
        .m_rmii_rx_axis_net ( net_rx        ),
        .s_rmii_tx_axis_net ( net_tx        )
    );

    eth_arp_axis u_arp(
        .sys_clk        ( sys_clk       ),
        .sys_rst_n      ( sys_rst_n     ),
        .s_rx_net       ( net_rx        ),
        .m_udp_rx_net   ( udp_rx_net    ),
        .s_udp_tx_net   ( udp_tx_net    ),
        .m_tx_net       ( net_tx        ),
        .pc_mac_addr    ( pc_mac_addr   ),
        .pc_ip_addr     ( pc_ip_addr    )
    );

    udp_axis_rx u_udp_rx(
        .sys_clk        ( sys_clk            ),
        .sys_rst_n      ( sys_rst_n          ),
        .s_axis         ( udp_rx_net         ),
        .m_axis         ( m_udp_rx_axis_net  ),
        .udp_rx_amount  ( udp_rx_amount      ),
        .pc_port        ( pc_port            ),
        .board_port     ( board_port         )
    );

    udp_axis_tx u_udp_tx(
        .sys_clk        ( sys_clk            ),
        .sys_rst_n      ( sys_rst_n          ),
        .s_axis         ( s_udp_tx_axis_net  ),
        .m_axis         ( udp_tx_net         ),
        .udp_tx_amount  ( udp_tx_amount      ),
        .pc_mac_addr    ( pc_mac_addr        ),
        .pc_ip_addr     ( pc_ip_addr         ),
        .pc_port        ( pc_port            ),
        .board_port     ( board_port         )
    );

endmodule
