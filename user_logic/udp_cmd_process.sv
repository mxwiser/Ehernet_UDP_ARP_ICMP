`include "pc_head.svh"
module udp_cmd_process(
    input  wire                     udp_rxstart,
    input  wire						udp_rxframe_done,
	input  wire						udp_rxdv,
	input  wire [7:0]				udp_rxdata,
	input  wire [15:0]				udp_rxamount,
	pc_head.slave					udp_rx_head
);


endmodule