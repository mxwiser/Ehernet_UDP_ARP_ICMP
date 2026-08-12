# EP4CE10 + 100M Ethernet Project

Ethernet communication project based on Cyclone IV E (EP4CE10F17C8) + LAN8720A (RMII), featuring UDP RX/TX loopback, ICMP echo (ping) and ARP reply, IPv4 only.

## Features

- 100M Ethernet PHY interface via RMII (50 MHz), LAN8720A
- MII PHY bridge also provided (`phy_mii_axis.sv`, 25 MHz, e.g. for RTL8201 etc.)
- ARP request receive and reply (learns PC MAC/IP automatically)
- ICMP echo request receive and echo reply (ping supported)
- UDP RX/TX; top-level `udp_loop` echoes received UDP data back to PC
- Frame-level AXI-Stream bus, decoupled from the PHY interface
- Clock domain crossing: async CDC FIFOs (`rx_cdc_fifo_axis` / `tx_cdc_fifo_axis`, based on `dcfifo`) separate the system clock from the PHY clock
- GMII bridge not included; implement it yourself if needed

## Directory Structure

```
├── udp_loop.sv            Top level: UDP loopback
├── mpll.v                 PLL clock (optional)
├── eth_axis/              AXIS-based sources
│   ├── udp.sv             UDP/ARP/ICMP stack integration + CDC (replaces legacy eth_rmii.sv)
│   ├── eth_axis.sv        ARP + ICMP echo handling
│   ├── udp_axis_rx.sv     UDP receive parser
│   ├── udp_axis_tx.sv     UDP transmit framing
│   ├── tx_fifo_axis.sv    TX frame buffering and arbitration
│   ├── phy_rmii_axis.sv   RMII PHY <-> AXIS bridge (LAN8720A)
│   ├── phy_mii_axis.sv    MII PHY <-> AXIS bridge (optional)
│   ├── rx_cdc_fifo_axis.sv  RX clock domain crossing FIFO (AXIS)
│   ├── tx_cdc_fifo_axis.sv  TX clock domain crossing FIFO (AXIS, with arbitration)
│   ├── dcfifo.sv          Asynchronous (dual clock) FIFO
│   ├── fifo.sv            Synchronous FIFO
│   ├── CRC32_D8.sv        CRC32 (per byte)
│   └── axis.svh           AXIS interface definition
└── ETH_old/               Legacy GMII-style Verilog (reference only, not compiled)
```

## Data Path

```
LAN8720A ──RMII──> phy_rmii_axis ──AXIS──> rx_cdc_fifo_axis ──AXIS──> udp_axis_rx ──> UDP parse
                                          (rmii_clk -> sys_clk)               │
LAN8720A <──RMII── phy_rmii_axis <──AXIS──< tx_cdc_fifo_axis <──AXIS──<── ARP/ICMP reply / UDP TX
                                          (sys_clk -> rmii_clk)
```

Clock domains: `sys_clk` (system logic) and `rmii_clk` (PHY side) are asynchronous; all AXIS crossings go through CDC FIFOs.

Frame boundary convention: AXIS `tlast` is a level signal (high = in frame, falling edge = frame end); RX side ignores `tready`, TX side is backpressured by the PHY bridge.

## Usage

- Project: `ep4ce10.qsf`, top-level `udp_loop`, device EP4CE10F17C8
- Board IP: 10.10.1.10 (see `BOARD_IP_ADDR` in `eth_axis/udp.sv`)
- Test: set PC to same subnet (e.g. 10.10.1.x), `ping 10.10.1.10` to verify ICMP/ARP; send UDP via a network tool to see the loopback
- MII bridge is included but not instantiated in the top level; switch to it by replacing `phy_rmii_axis` in `udp_loop.sv` (transparent pass-through: preamble/SFD/CRC handled by upper layer)
- GMII bridge is not provided; implement it yourself following the AXIS conventions above if needed

---

# EP4CE10 + 100M 以太网工程

基于 Cyclone IV E (EP4CE10F17C8) + LAN8720A (RMII) 的百兆以太网通信工程,实现 UDP 收发回环、ICMP 回显(Ping)与 ARP 应答,支持 IPv4。

## 功能

- 以太网 100M 收发,物理层采用 RMII 接口(50 MHz),PHY 为 LAN8720A
- 同时提供 MII 物理层转换(`phy_mii_axis.sv`,25 MHz,可用于 RTL8201 等)
- ARP 请求接收与应答(自动学习 PC 的 MAC/IP)
- ICMP Echo 请求接收与回显回复(支持 `ping`)
- UDP 接收/发送,`udp_loop` 顶层实现 UDP 数据回环(PC 发包 → 板卡原样返回)
- 帧级 AXI-Stream 总线,与具体 PHY 接口解耦
- 跨时钟域: 通过异步 CDC FIFO(`rx_cdc_fifo_axis` / `tx_cdc_fifo_axis`,基于 `dcfifo`)隔离系统时钟与 PHY 时钟
- GMII 转换未提供,如需使用请自行实现

## 目录结构

```
├── udp_loop.sv            顶层: UDP 回环
├── mpll.v                 PLL 时钟(可选)
├── eth_axis/              AXIS 版本源码
│   ├── udp.sv             UDP/ARP/ICMP 协议栈整合 + 跨时钟域处理(替代旧版 eth_rmii.sv)
│   ├── eth_axis.sv        ARP + ICMP 回显处理
│   ├── udp_axis_rx.sv     UDP 接收解析
│   ├── udp_axis_tx.sv     UDP 发送组帧
│   ├── tx_fifo_axis.sv    TX 帧缓存与仲裁
│   ├── phy_rmii_axis.sv   RMII 物理层 <-> AXIS 转换(LAN8720A)
│   ├── phy_mii_axis.sv    MII 物理层 <-> AXIS 转换(可选)
│   ├── rx_cdc_fifo_axis.sv  RX 跨时钟域 FIFO(AXIS)
│   ├── tx_cdc_fifo_axis.sv  TX 跨时钟域 FIFO(AXIS,含仲裁)
│   ├── dcfifo.sv          异步(双时钟)FIFO
│   ├── fifo.sv            同步 FIFO
│   ├── CRC32_D8.sv        CRC32 校验(逐字节)
│   └── axis.svh           AXIS 接口定义
└── ETH_old/               旧版 GMII 风格 Verilog(仅参考,不参与编译)
```

## 数据通路

```
LAN8720A ──RMII──> phy_rmii_axis ──AXIS──> rx_cdc_fifo_axis ──AXIS──> udp_axis_rx ──> UDP 解析
                                          (rmii_clk -> sys_clk)               │
LAN8720A <──RMII── phy_rmii_axis <──AXIS──< tx_cdc_fifo_axis <──AXIS──<── ARP/ICMP 应答 / UDP 发送
                                          (sys_clk -> rmii_clk)
```

时钟域: `sys_clk`(系统逻辑)与 `rmii_clk`(PHY 侧)异步,AXIS 跨域均经 CDC FIFO。

帧边界约定: AXIS 的 `tlast` 为电平信号(高 = 帧内,下降沿 = 帧结束);RX 侧忽略 `tready`,TX 侧由物理层模块反压。

## 使用

- 工程: `ep4ce10.qsf`,顶层 `udp_loop`,器件 EP4CE10F17C8
- 板卡 IP: 10.10.1.10(见 `eth_axis/udp.sv` 的 `BOARD_IP_ADDR`)
- 测试: PC 配置同网段 IP(如 10.10.1.x),`ping 10.10.1.10` 验证 ICMP/ARP;UDP 助手发包即可回环
- MII 转换已提供但未在顶层例化;如需使用,在 `udp_loop.sv` 中替换 `phy_rmii_axis` 即可(透传模式: 前导码/SFD/CRC 由上层负责)
- GMII 转换未提供,如需使用请按上述 AXIS 帧约定自行实现
