module ip_conf #(
    parameter logic [47:0] DEFAULT_BOARD_MAC_ADDR = 48'h60_A8_01_33_44_55,
    parameter logic [31:0] DEFAULT_BOARD_IP_ADDR  = 32'hC0_A8_01_0A
)(
    input  wire         clk,
    input  wire         rstn,
    output logic [47:0] board_mac_addr,
    output logic [31:0] board_ip_addr
);

always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        board_mac_addr <= DEFAULT_BOARD_MAC_ADDR;
        board_ip_addr  <= DEFAULT_BOARD_IP_ADDR;
    end else begin

    end
end

endmodule
