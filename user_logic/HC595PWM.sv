`include "hc595.svh"

module HC595PWM #(
    parameter integer CHIP_NUMBERS = 2,
    parameter integer CLK_FREQ_HZ  = 50_000_000,
    parameter integer PWM_FREQ_HZ  = 1_000,
    parameter integer PWM_LEVELS   = 10
)(
    input  logic                                             rstn,
    input  logic                                             clk,

    // Write one channel's duty cycle. Valid values are 0 through PWM_LEVELS.
    // Address 0 is QA of the first 74HC595, followed by QB ... QH, then
    // QA of the second 74HC595, and so on.
    input  logic                                             pwm_wr_en,
    input  logic [$clog2(CHIP_NUMBERS * 8)-1:0]              pwm_wr_addr,
    input  logic [$clog2(PWM_LEVELS + 1)-1:0]                pwm_wr_duty,
    output logic                                             init_done,

    hc595.master                                             hc595_serial
);

localparam integer CHANNEL_COUNT = CHIP_NUMBERS * 8;
localparam integer DUTY_WIDTH = $clog2(PWM_LEVELS + 1);
localparam integer PWM_STEP_HZ = PWM_FREQ_HZ * PWM_LEVELS;
localparam integer STEP_CYCLES = CLK_FREQ_HZ / PWM_STEP_HZ;

// Reserve the last few clocks of every PWM step for the latch pulse. The
// remaining time is used for shifting, so SHCP runs only slightly faster than
// the theoretical minimum CHANNEL_COUNT * PWM_STEP_HZ.
localparam integer LATCH_GUARD_CYCLES = 4;
localparam integer SHCP_HALF_CYCLES_CALC =
    (STEP_CYCLES - LATCH_GUARD_CYCLES) / (2 * CHANNEL_COUNT);
localparam integer SHCP_HALF_CYCLES =
    (SHCP_HALF_CYCLES_CALC < 1) ? 1 : SHCP_HALF_CYCLES_CALC;

localparam integer STEP_COUNT_WIDTH =
    (STEP_CYCLES <= 1) ? 1 : $clog2(STEP_CYCLES);
localparam integer SHCP_COUNT_WIDTH =
    (SHCP_HALF_CYCLES <= 1) ? 1 : $clog2(SHCP_HALF_CYCLES);
localparam integer CHANNEL_ADDR_WIDTH = $clog2(CHANNEL_COUNT);

localparam logic [DUTY_WIDTH-1:0] MAX_DUTY = DUTY_WIDTH'(PWM_LEVELS);
localparam logic [DUTY_WIDTH-1:0] LAST_PHASE =
    DUTY_WIDTH'(PWM_LEVELS - 1);

logic [DUTY_WIDTH-1:0] duty_table [0:CHANNEL_COUNT-1];
logic [CHANNEL_COUNT-1:0] shift_data;
logic [DUTY_WIDTH-1:0] pwm_phase;
logic [DUTY_WIDTH-1:0] next_pwm_phase;
logic [STEP_COUNT_WIDTH-1:0] step_count;
logic [SHCP_COUNT_WIDTH-1:0] shcp_count;
logic [CHANNEL_ADDR_WIDTH-1:0] shift_index;
logic serial_active;
logic stcp;
logic shcp;
logic oen;
logic ser;

integer channel_index;

assign hc595_serial.stcp = stcp;
assign hc595_serial.shcp = shcp;
assign hc595_serial.oen  = oen;
assign hc595_serial.ser  = ser;

always_comb begin
    if (pwm_phase == LAST_PHASE)
        next_pwm_phase = '0;
    else
        next_pwm_phase = pwm_phase + 1'b1;
end

// The output pattern for one PWM phase is shifted while the previously
// latched pattern remains visible. STCP updates all 74HC595 outputs at once.
always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        init_done     <= 1'b0;
        pwm_phase     <= '0;
        step_count    <= '0;
        shcp_count    <= '0;
        shift_index   <= CHANNEL_ADDR_WIDTH'(CHANNEL_COUNT - 1);
        serial_active <= 1'b1;
        shift_data    <= '0;
        stcp          <= 1'b0;
        shcp          <= 1'b0;
        oen           <= 1'b1;
        ser           <= 1'b0;

        for (channel_index = 0;
             channel_index < CHANNEL_COUNT;
             channel_index = channel_index + 1) begin
            duty_table[channel_index] <= '0;
        end
    end else begin
        // The write port is always ready. Values above PWM_LEVELS are clamped.
        if (pwm_wr_en && (pwm_wr_addr < CHANNEL_COUNT)) begin
            if (pwm_wr_duty > MAX_DUTY)
                duty_table[pwm_wr_addr] <= MAX_DUTY;
            else
                duty_table[pwm_wr_addr] <= pwm_wr_duty;
        end

        // STCP is normally low and is asserted for one system-clock period.
        stcp <= 1'b0;

        if (step_count == STEP_CYCLES - 1) begin
            step_count <= '0;
            pwm_phase  <= next_pwm_phase;

            // The first latch after reset contains all zeros. Enable the
            // outputs only after that safe value has been latched.
            if (!init_done) begin
                init_done <= 1'b1;
                oen       <= 1'b0;
            end

            // Prepare the next PWM phase. Data is sent from the last channel
            // down to channel zero so address zero arrives at the first QA.
            for (channel_index = 0;
                 channel_index < CHANNEL_COUNT;
                 channel_index = channel_index + 1) begin
                shift_data[channel_index] <=
                    (duty_table[channel_index] > next_pwm_phase);
            end

            ser           <=
                (duty_table[CHANNEL_COUNT-1] > next_pwm_phase);
            shift_index   <= CHANNEL_ADDR_WIDTH'(CHANNEL_COUNT - 1);
            shcp_count    <= '0;
            shcp          <= 1'b0;
            serial_active <= 1'b1;
        end else begin
            step_count <= step_count + 1'b1;

            // Latch after all serial bits have been shifted. The following
            // clock lowers STCP and enables the outputs after initialization.
            if (step_count == STEP_CYCLES - 2)
                stcp <= 1'b1;

            if (serial_active) begin
                if (shcp_count == SHCP_HALF_CYCLES - 1) begin
                    shcp_count <= '0;

                    if (!shcp) begin
                        // 74HC595 shifts SER on the rising edge of SHCP.
                        shcp <= 1'b1;
                    end else begin
                        shcp <= 1'b0;

                        if (shift_index == 0) begin
                            serial_active <= 1'b0;
                        end else begin
                            shift_index <= shift_index - 1'b1;
                            ser <= shift_data[shift_index - 1'b1];
                        end
                    end
                end else begin
                    shcp_count <= shcp_count + 1'b1;
                end
            end
        end
    end
end

endmodule
