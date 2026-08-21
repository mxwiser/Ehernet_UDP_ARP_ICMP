`include "hc595.svh"
module HC595PWM #(
    parameter CHIP_NUMBERS = 2
)(
    input  logic        rstn,
    input  logic        clk,
    hc595.master        hc595_serial
);

localparam integer SHIFT_BITS = CHIP_NUMBERS * 8;
localparam integer COUNT_WIDTH = (SHIFT_BITS <= 1) ? 1 : $clog2(SHIFT_BITS);

typedef enum logic [2:0] {
    INIT_SHIFT_HIGH,
    INIT_SHIFT_LOW,
    INIT_LATCH,
    INIT_ENABLE_OUTPUT,
    INIT_DONE
} init_state_t;

init_state_t init_state;
logic [COUNT_WIDTH-1:0] bit_count;
logic stcp;
logic shcp;
logic oen;
logic ser;

assign hc595_serial.stcp = stcp;
assign hc595_serial.shcp = shcp;
assign hc595_serial.oen  =  oen;
assign hc595_serial.ser  =  ser;

// 74HC595 has no reset input.  Keep its outputs disabled while shifting zeros
// into every device, latch the zeros, and only then enable the outputs.
always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        init_state <= INIT_SHIFT_HIGH;
        bit_count  <= '0;
        stcp       <= 1'b0;
        shcp       <= 1'b0;
        oen        <= 1'b1;
        ser        <= 1'b0;
    end else begin
        case (init_state)
            INIT_SHIFT_HIGH: begin
                ser  <= 1'b0;
                shcp <= 1'b1;

                if (bit_count == SHIFT_BITS - 1) begin
                    init_state <= INIT_LATCH;
                end else begin
                    bit_count  <= bit_count + 1'b1;
                    init_state <= INIT_SHIFT_LOW;
                end
            end

            INIT_SHIFT_LOW: begin
                shcp       <= 1'b0;
                init_state <= INIT_SHIFT_HIGH;
            end

            INIT_LATCH: begin
                shcp       <= 1'b0;
                stcp       <= 1'b1;
                init_state <= INIT_ENABLE_OUTPUT;
            end

            INIT_ENABLE_OUTPUT: begin
                stcp       <= 1'b0;
                oen        <= 1'b0;
                init_state <= INIT_DONE;
            end

            INIT_DONE: begin
                stcp <= 1'b0;
                shcp <= 1'b0;
                oen  <= 1'b0;
                ser  <= 1'b0;
            end

            default: begin
                init_state <= INIT_SHIFT_HIGH;
                bit_count  <= '0;
                stcp       <= 1'b0;
                shcp       <= 1'b0;
                oen        <= 1'b1;
                ser        <= 1'b0;
            end
        endcase
    end
end

endmodule
