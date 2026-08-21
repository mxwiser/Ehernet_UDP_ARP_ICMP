`include "hc595.svh"
module udp_cmd_process(
    input  logic                    clk,
    input  logic                    rstn,
    input  wire                     udp_rxstart,
    input  wire						udp_rxframe_done,
	input  wire						udp_rxdv,
	input  wire [7:0]				udp_rxdata,
	input  wire [15:0]				udp_rxamount,
	pc_head.slave					udp_rx_head,
    hc595                           hc595_s1
);

HC595PWM u1_hc595(
    .clk            (clk),
    .rstn           (rstn),
    .hc595_serial (hc595_s1)
);

endmodule
