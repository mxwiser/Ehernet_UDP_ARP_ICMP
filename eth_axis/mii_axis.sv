`include "axis.svh"

module mii_axis(
    input  logic        rstn,
    //mii tx
    input  logic        tx_clk,
    output logic[3:0]   txd,
    output logic        txen,
    //mii rx
    input logic         rx_clk,
    input logic[3:0]    rxd,
    input logic         rxdv,
    axis.master         m_phy_rx,
    axis.slave          s_phy_tx
);

endmodule