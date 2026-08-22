# EP4CE10 + IP101GRI RMII timing constraints
#
# Clocking in the current top-level design:
#   clkin    : 40 MHz board oscillator -> PLL inclk0
#   PLL c0   : 50 MHz system clock (internal net "clk")
#   PLL c1   : 1 MHz SMI clock (internal clock and output port "mdc")
#   rmii_clk : independent 50 MHz reference supplied by the IP101GRI

set_time_format -unit ns -decimal_places 3

# -----------------------------------------------------------------------------
# Base clocks
# -----------------------------------------------------------------------------

create_clock -name {clkin_40m} \
    -period 25.000 -waveform {0.000 12.500} [get_ports {clkin}]

create_clock -name {rmii_clk_50m} \
    -period 20.000 -waveform {0.000 10.000} [get_ports {rmii_clk}]

# Create the 50 MHz c0 and 1 MHz c1 clocks from the ALTPLL parameters. The
# clkin base clock must exist before this command or TimeQuest cannot associate
# the generated clocks with their 40 MHz master clock.
derive_pll_clocks
derive_clock_uncertainty

# The PHY RMII reference and the board oscillator/PLL clocks have no fixed
# phase relationship. Crossings between these domains are implemented with
# asynchronous FIFOs.
set_clock_groups -asynchronous \
    -group [get_clocks {*pll_inst*}] \
    -group [get_clocks {rmii_clk_50m}]

# -----------------------------------------------------------------------------
# IP101GRI RMII interface, VDDIO = 3.3 V
# -----------------------------------------------------------------------------
# Datasheet receive timing (PHY -> FPGA):
#   RMII_CLK rising edge to CRS_DV/RXD output = 6 ns min, 13 ns max.
# Datasheet transmit timing (FPGA -> PHY):
#   TXEN/TXD setup = 4 ns min, hold = 2 ns min.
#
# These values assume zero relative PCB clock/data trace skew. Add the measured
# data-minus-clock trace delay to these constraints if PCB trace data is known.

set_input_delay -clock [get_clocks {rmii_clk_50m}] \
    -min 6.000 [get_ports {rmii_rxdv rmii_rxdata[*]}]
set_input_delay -clock [get_clocks {rmii_clk_50m}] \
    -max 13.000 [get_ports {rmii_rxdv rmii_rxdata[*]}]

set_output_delay -clock [get_clocks {rmii_clk_50m}] \
    -min -2.000 [get_ports {rmii_txen rmii_txdata[*]}]
set_output_delay -clock [get_clocks {rmii_clk_50m}] \
    -max 4.000 [get_ports {rmii_txen rmii_txdata[*]}]

# The power-on reset is created internally and is intentionally asynchronous
# to the RMII domain. Other board-control inputs have no external timing budget
# in the available hardware documentation and are therefore left unconstrained.
