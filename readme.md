# EP4CE10 + 100M Ethernet Project

Ethernet communication project based on Cyclone IV E (EP4CE10F17C8) + LAN8720A (RMII), featuring UDP RX/TX loopback, ICMP echo (ping) and ARP reply, IPv4 only.

## Features

- 100M Ethernet PHY interface via RMII (50 MHz), LAN8720A
- ARP request receive and reply (learns PC MAC/IP automatically)
- ICMP echo request receive and echo reply (ping supported)
- UDP RX/TX; top-level `udp_loop` echoes received UDP data back to PC
- Frame-level AXI-Stream bus, decoupled from the PHY interface (RMII/MII/GMII)

## Directory Structure

```
├── udp_loop.sv            Top level: UDP loopback
├── mpll.v                 PLL clock (optional)
├── eth_axis/              AXIS-based sources
│   ├── udp.sv             UDP/ARP/ICMP stack integration (replaces legacy eth_rmii.sv)
│   ├── eth_axis.sv        ARP + ICMP echo handling
│   ├── udp_axis_rx.sv     UDP receive parser
│   ├── udp_axis_tx.sv     UDP transmit framing
│   ├── tx_fifo_axis.sv    TX frame buffering and arbitration
│   ├── rmii_axis.sv       RMII PHY <-> AXIS bridge
│   ├── mii_axis.sv        MII PHY <-> AXIS bridge
│   ├── gmii_axis.sv       GMII PHY <-> AXIS bridge
│   ├── fifo.sv            Synchronous FIFO
│   ├── CRC32_D8.sv        CRC32 (per byte)
│   └── axis.svh           AXIS interface definition
└── ETH_old/               Legacy GMII-style Verilog (reference only, not compiled)
```

## Data Path

```
LAN8720A ──RMII──> rmii_axis ──AXIS──> eth_axis/udp_axis_rx ──> UDP parse
                                           │
LAN8720A <──RMII── rmii_axis <──AXIS──<── tx_fifo_axis <── ARP/ICMP reply / UDP TX
```

Frame boundary convention: AXIS `tlast` is a level signal (high = in frame, falling edge = frame end); RX side ignores `tready`, TX side is backpressured by the PHY bridge.

## Usage

- Project: `ep4ce10.qsf`, top-level `udp_loop`, device EP4CE10F17C8
- Board IP: 10.10.1.10 (see `BOARD_IP_ADDR` in `eth_axis/udp.sv`)
- Test: set PC to same subnet (e.g. 10.10.1.x), `ping 10.10.1.10` to verify ICMP/ARP; send UDP via a network tool to see the loopback
- Switching PHY bridge: replace the `rmii_axis` instance in `udp.sv` with `mii_axis` / `gmii_axis`, and adjust clock/pin constraints accordingly

---

# EP4CE10 + 100M 以太网工程

基于 Cyclone IV E (EP4CE10F17C8) + LAN8720A (RMII) 的百兆以太网通信工程,实现 UDP 收发回环、ICMP 回显(Ping)与 ARP 应答,支持 IPv4。

## 功能

- 以太网 100M 收发,物理层采用 RMII 接口(50 MHz),PHY 为 LAN8720A
- ARP 请求接收与应答(自动学习 PC 的 MAC/IP)
- ICMP Echo 请求接收与回显回复(支持 `ping`)
- UDP 接收/发送,`udp_loop` 顶层实现 UDP 数据回环(PC 发包 → 板卡原样返回)
- 帧级 AXI-Stream 总线,与具体 PHY 接口(RMII/MII/GMII)解耦

## 目录结构

```
├── udp_loop.sv            顶层: UDP 回环
├── mpll.v                 PLL 时钟(可选)
├── eth_axis/              AXIS 版本源码
│   ├── udp.sv             UDP/ARP/ICMP 协议栈整合(替代旧版 eth_rmii.sv)
│   ├── eth_axis.sv        ARP + ICMP 回显处理
│   ├── udp_axis_rx.sv     UDP 接收解析
│   ├── udp_axis_tx.sv     UDP 发送组帧
│   ├── tx_fifo_axis.sv    TX 帧缓存与仲裁
│   ├── rmii_axis.sv       RMII 物理层 <-> AXIS 转换
│   ├── mii_axis.sv        MII 物理层 <-> AXIS 转换
│   ├── gmii_axis.sv       GMII 物理层 <-> AXIS 转换
│   ├── fifo.sv            同步 FIFO
│   ├── CRC32_D8.sv        CRC32 校验(逐字节)
│   └── axis.svh           AXIS 接口定义
└── ETH_old/               旧版 GMII 风格 Verilog(仅参考,不参与编译)
```

## 数据通路

```
LAN8720A ──RMII──> rmii_axis ──AXIS──> eth_axis/udp_axis_rx ──> UDP 解析
                                           │
LAN8720A <──RMII── rmii_axis <──AXIS──<── tx_fifo_axis <── ARP/ICMP 应答 / UDP 发送
```

帧边界约定: AXIS 的 `tlast` 为电平信号(高 = 帧内,下降沿 = 帧结束);RX 侧忽略 `tready`,TX 侧由物理层模块反压。

## 使用

- 工程: `ep4ce10.qsf`,顶层 `udp_loop`,器件 EP4CE10F17C8
- 板卡 IP: 10.10.1.10(见 `eth_axis/udp.sv` 的 `BOARD_IP_ADDR`)
- 测试: PC 配置同网段 IP(如 10.10.1.x),`ping 10.10.1.10` 验证 ICMP/ARP;UDP 助手发包即可回环
- 切换 MII/GMII 物理层: 在 `udp.sv` 中替换 `rmii_axis` 实例为 `mii_axis` / `gmii_axis`,并相应调整时钟与引脚约束
