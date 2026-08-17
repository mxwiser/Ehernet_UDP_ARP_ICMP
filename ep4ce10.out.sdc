## Generated SDC file "ep4ce10.out.sdc"

## Copyright (C) 2025  Altera Corporation. All rights reserved.
## Your use of Altera Corporation's design tools, logic functions 
## and other software and tools, and any partner logic 
## functions, and any output files from any of the foregoing 
## (including device programming or simulation files), and any 
## associated documentation or information are expressly subject 
## to the terms and conditions of the Altera Program License 
## Subscription Agreement, the Altera Quartus Prime License Agreement,
## the Altera IP License Agreement, or other applicable license
## agreement, including, without limitation, that your use is for
## the sole purpose of programming logic devices manufactured by
## Altera and sold by Altera or its authorized distributors.  Please
## refer to the Altera Software License Subscription Agreements 
## on the Quartus Prime software download page.


## VENDOR  "Altera"
## PROGRAM "Quartus Prime"
## VERSION "Version 25.1std.0 Build 1129 10/21/2025 SC Lite Edition"

## DATE    "Tue Aug 11 11:22:12 2026"

##
## DEVICE  "EP4CE10F17C8"
##


#**************************************************************
# Time Information
#**************************************************************

set_time_format -unit ns -decimal_places 3



#**************************************************************
# Create Clock
#**************************************************************

#create_clock -name {clk50m} -period 20.000 -waveform { 0.000 10.000 } [get_ports {rmii_clk}]
create_clock -name {sys_clk} -period 20.000 -waveform { 0.000 10.000 } [get_ports {clk}]
create_clock -name {tx_clk} -period 40.000 -waveform { 0.000 20.000 } [get_ports {mii_txc}]
create_clock -name {rx_clk} -period 40.000 -waveform { 0.000 20.000 } [get_ports {mii_rxc}]
#**************************************************************
# Create Generated Clock
#**************************************************************



#**************************************************************
# Set Clock Latency
#**************************************************************



#**************************************************************
# Set Clock Uncertainty
#**************************************************************



#**************************************************************
# Set Input Delay
#**************************************************************

# MII RX 源同步输入: PHY 以 mii_rxc(rx_clk) 为源同步时钟输出 mii_rxd/mii_rxdv,
# FPGA 内部在 rx_clk 上升沿采样, 故相对 rx_clk 约束建立/保持
# -max: 数据最迟在 rx_clk 沿后 15 ns 到达 (100M MII 周期 40 ns, 留 25 ns 给内部路径)
# -min: 数据最早在 rx_clk 沿后 2 ns 才变化 (保护保持时间, 避免过快翻转)
# 数值按板级典型值估计, 建议按实际 PHY 数据手册的 tpd 与走线延时修正
set_input_delay -clock { rx_clk } -max 15.000 [get_ports { mii_rxdv mii_rxd[*] }]
set_input_delay -clock { rx_clk } -min 2.000 [get_ports { mii_rxdv mii_rxd[*] }]



#**************************************************************
# Set Output Delay
#**************************************************************

# MII TX 源同步输出: FPGA 在 mii_txc(tx_clk) 上升沿驱动 mii_txd/mii_txen,
# PHY 也在 tx_clk 上升沿采样 (边沿对齐), 故相对 tx_clk 约束建立/保持
# -max: 数据最迟在 tx_clk 沿后 10 ns 到达 PHY 采样点 (PHY 建立时间, 周期 40 ns, 留 30 ns 给内部路径+走线)
# -min: 数据最早在 tx_clk 沿后 2 ns 才变化 (保护 PHY 保持时间, 避免采样到跳变中的值)
# 数值按板级典型值估计, 建议按实际 PHY 数据手册的 tsu/th 与走线延时修正
set_output_delay -clock { tx_clk } -max 10.000 [get_ports { mii_txd[*] mii_txen }]
set_output_delay -clock { tx_clk } -min 2.000 [get_ports { mii_txd[*] mii_txen }]



#**************************************************************
# Set Clock Groups
#**************************************************************



#**************************************************************
# Set False Path
#**************************************************************



#**************************************************************
# Set Multicycle Path
#**************************************************************



#**************************************************************
# Set Maximum Delay
#**************************************************************



#**************************************************************
# Set Minimum Delay
#**************************************************************



#**************************************************************
# Set Input Transition
#**************************************************************

