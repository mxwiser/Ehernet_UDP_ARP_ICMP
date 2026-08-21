`include "hc595.svh"
module HC595PWM #(
    parameter CHIP_NUMBERS = 2
)(
    input  logic   rstn,
    input  logic   clk,
    hc595  hc595_serial
);
logic   stcp;
logic   shcp;
logic    oen;
logic     ds;

assign hc595_serial.stcp = stcp;
assign hc595_serial.shcp = shcp;
assign hc595_serial.oen  =  oen;
assign hc595_serial.ds   =   ds;


always_ff @(posedge clk or negedge rstn)begin
    if(!rstn) begin
        stcp =0;
        shcp =0;
        oen  =1;
        ds   =0;
    end else begin

    end
end




/**

**/

endmodule