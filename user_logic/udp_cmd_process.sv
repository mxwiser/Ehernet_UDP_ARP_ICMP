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
    hc595                           hc595_s1,
    hc595                           hc595_s2
);

HC595PWM #(
    .CHIP_NUMBERS (2),
    .CLK_FREQ_HZ  (50_000_000),
    .PWM_FREQ_HZ  (1_000),
    .PWM_LEVELS   (10)
) u1_hc595 (
    .clk           (clk),
    .rstn          (rstn),
    // TODO: drive these three ports from the UDP command decoder.
    .pwm_wr_en     (1'b0),
    .pwm_wr_addr   ('0),
    .pwm_wr_duty   ('0),
    .init_done     (),
    .hc595_serial (hc595_s1)
);

HC595PWM #(
    .CHIP_NUMBERS (2),
    .CLK_FREQ_HZ  (50_000_000),
    .PWM_FREQ_HZ  (1_000),
    .PWM_LEVELS   (10)
) u2_hc595 (
    .clk           (clk),
    .rstn          (rstn),
    // TODO: drive these three ports from the UDP command decoder.
    .pwm_wr_en     (1'b0),
    .pwm_wr_addr   ('0),
    .pwm_wr_duty   ('0),
    .init_done     (),
    .hc595_serial (hc595_s2)
);



endmodule
