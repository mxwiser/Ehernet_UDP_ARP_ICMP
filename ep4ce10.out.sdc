# EP4CE10 + RTL8201F 100BASE-TX MII timing constraints
#
# Reference: RTL8201F/RTL8201FL/RTL8201FN Datasheet, Rev. 1.4
#   Table 51: MII Transmission Cycle Timing
#   Table 52: MII Reception Cycle Timing
#
# The values below are the PHY pin timing limits. PCB trace delays default to
# 0 ns because no routed trace-length data is available. Replace the PCB delay
# variables below with measured min/max values when they are known.

set_time_format -unit ns -decimal_places 3

# -----------------------------------------------------------------------------
# Clocks
# -----------------------------------------------------------------------------

create_clock -name {sys_clk} -period 20.000 -waveform {0.000 10.000} [get_ports {clk}]

# RTL8201F MII clocks are 25 MHz at 100 Mbps. TXC and RXC are PHY outputs.
# The datasheet specifies a nominal 40 ns period and 14..26 ns high/low time.
# Only rising edges are used by the current RTL, so the nominal waveform is
# sufficient for the rising-edge setup/hold checks.
create_clock -name {tx_clk} -period 40.000 -waveform {0.000 20.000} [get_ports {mii_txc}]
create_clock -name {rx_clk} -period 40.000 -waveform {0.000 20.000} [get_ports {mii_rxc}]

# Let TimeQuest add the device/model clock uncertainty for every corner.
derive_clock_uncertainty

# The board oscillator, MII TXC, and MII RXC have no specified phase
# relationship. All transfers between these domains use asynchronous FIFOs.
set_clock_groups -asynchronous \
    -group [get_clocks {sys_clk}] \
    -group [get_clocks {tx_clk}] \
    -group [get_clocks {rx_clk}]

# -----------------------------------------------------------------------------
# RTL8201F 100 Mbps MII timing limits
# -----------------------------------------------------------------------------

set MII_PERIOD_NS          40.000
set MII_RX_SETUP_NS        10.000
set MII_RX_HOLD_NS         10.000
set MII_TX_SETUP_NS        10.000
set MII_TX_HOLD_NS          0.000

# PCB flight times at minimum/maximum operating conditions.
# RXCLK/RXD travel from PHY to FPGA. TXCLK travels from PHY to FPGA, while
# TXD/TXEN travel back from FPGA to PHY.
set MII_RX_CLK_PCB_MIN_NS    0.000
set MII_RX_CLK_PCB_MAX_NS    0.000
set MII_RX_DATA_PCB_MIN_NS   0.000
set MII_RX_DATA_PCB_MAX_NS   0.000
set MII_TX_CLK_PCB_MIN_NS    0.000
set MII_TX_CLK_PCB_MAX_NS    0.000
set MII_TX_DATA_PCB_MIN_NS   0.000
set MII_TX_DATA_PCB_MAX_NS   0.000

# -----------------------------------------------------------------------------
# MII receive: RTL8201F -> FPGA
# -----------------------------------------------------------------------------

# Table 52 guarantees RXD/RXDV valid for 10 ns before and 10 ns after each
# RXCLK rising edge. Expressed as an arrival window from the preceding rising
# edge, this is:
#   earliest transition = RX hold                         = 10 ns
#   latest arrival       = period - RX setup             = 30 ns
# PCB terms account for the relative PHY-to-FPGA clock/data flight times.
set_input_delay -clock [get_clocks {rx_clk}] -max \
    [expr {$MII_PERIOD_NS - $MII_RX_SETUP_NS + \
           $MII_RX_DATA_PCB_MAX_NS - $MII_RX_CLK_PCB_MIN_NS}] \
    [get_ports {mii_rxdv mii_rxd[*]}]

set_input_delay -clock [get_clocks {rx_clk}] -min \
    [expr {$MII_RX_HOLD_NS + $MII_RX_DATA_PCB_MIN_NS - \
           $MII_RX_CLK_PCB_MAX_NS}] \
    [get_ports {mii_rxdv mii_rxd[*]}]

# -----------------------------------------------------------------------------
# MII transmit: FPGA -> RTL8201F
# -----------------------------------------------------------------------------

# Table 51 requires TXD/TXEN setup >= 10 ns and hold >= 0 ns at the TXCLK
# rising edge. For set_output_delay, -max is the receiver setup requirement;
# -min is the negative receiver hold requirement. Since TXCLK first travels
# PHY-to-FPGA and TXD/TXEN then travel FPGA-to-PHY, both PCB flight times are
# included in the external output-delay model.
set_output_delay -clock [get_clocks {tx_clk}] -max \
    [expr {$MII_TX_SETUP_NS + $MII_TX_CLK_PCB_MAX_NS + \
           $MII_TX_DATA_PCB_MAX_NS}] \
    [get_ports {mii_txd[*] mii_txen}]

set_output_delay -clock [get_clocks {tx_clk}] -min \
    [expr {$MII_TX_CLK_PCB_MIN_NS + $MII_TX_DATA_PCB_MIN_NS - \
           $MII_TX_HOLD_NS}] \
    [get_ports {mii_txd[*] mii_txen}]

# rstn is intentionally asynchronous in the RTL. UART and inactive MDIO/MDC
# paths are outside the RTL8201F MII source-synchronous interface constraints.
