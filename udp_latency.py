import socket
import struct
import time
import select
import argparse
import sys
#python udp_latency.py --mode burst --burst 1000 --rounds 3
BOARD_IP   = "10.10.1.10"  # 板子IP
BOARD_PORT = 9001          # 板子端口 (FPGA 回环时作为源端口发回)
LOCAL_IP   = "10.10.1.11"  # 电脑IP   (源IP)
LOCAL_PORT = 9001          # 电脑端口 (源端口)
MAGIC      = 0xAA55AA55


def make_payload(seq):
    return struct.pack(">II", MAGIC, seq & 0xFFFFFFFF)


def drain_once(s, outstanding, recv_map):
    """非阻塞接收一次, 匹配的 seq 记入 recv_map, 从 outstanding 移除"""
    got = 0
    while True:
        try:
            data, addr = s.recvfrom(4096)
        except BlockingIOError:
            break
        if addr[0] != BOARD_IP or addr[1] != BOARD_PORT or len(data) < 8:
            continue
        magic, rseq = struct.unpack(">II", data[:8])
        if magic != MAGIC:
            continue
        if rseq in outstanding:
            outstanding.discard(rseq)
            recv_map[rseq] = time.monotonic()
            got += 1
    return got


def recv_until(s, outstanding, recv_map, deadline):
    """在 deadline 前持续接收 (select 超时取 max(0,...), 不会为负阻塞)"""
    while outstanding:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        readable, _, _ = select.select([s], [], [], max(0, remaining))
        if not readable:
            break
        drain_once(s, outstanding, recv_map)


def run_burst(s, args):
    print(f"burst 模式: 每轮 {args.burst} 包, 共 {args.rounds} 轮, "
          f"等待回包窗口 {args.timeout}s")
    seq = 1
    total_sent = 0
    total_lost = 0
    all_rtt = []
    for r in range(1, args.rounds + 1):
        outstanding = set()
        send_times = {}
        t0 = time.monotonic()
        for i in range(args.burst):
            s.sendto(make_payload(seq), (BOARD_IP, BOARD_PORT))
            outstanding.add(seq & 0xFFFFFFFF)
            send_times[seq & 0xFFFFFFFF] = time.monotonic()
            seq += 1
        recv_map = {}
        recv_until(s, outstanding, recv_map, t0 + args.timeout)
        sent = args.burst
        lost = sent - len(recv_map)
        total_sent += sent
        total_lost += lost
        rtt = [recv_map[k] - send_times[k] for k in recv_map]
        all_rtt += rtt
        pct = lost / sent * 100
        line = (f"round {r}: sent={sent} recv={sent - lost} lost={lost} "
                f"loss={pct:.2f}%")
        if rtt:
            line += (f"  rtt min/avg/max = {min(rtt) * 1000:.3f}/"
                     f"{sum(rtt) / len(rtt) * 1000:.3f}/{max(rtt) * 1000:.3f} ms")
        print(line)
        time.sleep(args.round_gap)
    print_stats(total_sent, total_lost, all_rtt)


def run_flood(s, args):
    print(f"flood 模式: {args.pps} pps, 持续 {args.duration}s")
    interval = 1.0 / args.pps
    seq = 1
    sent = 0
    received = 0
    outstanding = set()
    recv_map = {}
    t_start = time.monotonic()
    deadline = t_start + args.duration
    next_send = t_start
    last_report = t_start
    while True:
        now = time.monotonic()
        if now >= deadline:
            break
        drain_once(s, outstanding, recv_map)
        if now >= next_send:
            try:
                s.sendto(make_payload(seq), (BOARD_IP, BOARD_PORT))
                outstanding.add(seq & 0xFFFFFFFF)
                seq += 1
                sent += 1
            except BlockingIOError:
                pass
            next_send += interval
            if next_send < now:          # 落后太多不追赶, 避免突发
                next_send = now + interval
        else:
            time.sleep(min(0.001, next_send - now))
        if now - last_report >= 1.0:     # 每秒进度
            lost = sent - len(recv_map)
            pct = lost / sent * 100 if sent else 0
            print(f"  t={now - t_start:.1f}s sent={sent} recv={sent - lost} "
                  f"loss={pct:.2f}%")
            last_report = now
    lost = sent - len(recv_map)
    print_stats(sent, lost, [])


def print_stats(sent, lost, rtt):
    pct = lost / sent * 100 if sent else 0
    print(f"\n--- {BOARD_IP} UDP {args.mode} statistics ---")
    print(f"{sent} packets sent, {sent - lost} received, {pct:.2f}% packet loss")
    if rtt:
        print(f"rtt min/avg/max = {min(rtt) * 1000:.3f}/"
              f"{sum(rtt) / len(rtt) * 1000:.3f}/{max(rtt) * 1000:.3f} ms")
    if lost:
        print("提示: 丢包可能来自 PC 端 socket 发送缓冲溢出(尤其高频), "
              "建议用 Wireshark 确认丢包前包是否真的发上了网线")


def main():
    global args
    parser = argparse.ArgumentParser(description="FPGA UDP 回环测试 (burst/flood)")
    parser.add_argument("--mode", choices=["burst", "flood"], default="burst")
    parser.add_argument("--port", type=int, default=None,
                        help="发给板卡的目的端口(回包源端口=该端口, 默认8080, "
                             "正点原子工具默认发9000)")
    parser.add_argument("--burst", type=int, default=1000, help="burst 每轮发包数")
    parser.add_argument("--rounds", type=int, default=3, help="burst 轮数")
    parser.add_argument("--timeout", type=float, default=1.0, help="每轮回包等待窗口(秒)")
    parser.add_argument("--round-gap", type=float, default=0.2, help="轮间间隔(秒)")
    parser.add_argument("--pps", type=float, default=1000, help="flood 发包速率(包/秒)")
    parser.add_argument("--duration", type=float, default=10, help="flood 持续时间(秒)")
    args = parser.parse_args()
    global BOARD_PORT
    if args.port is not None:
        BOARD_PORT = args.port

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((LOCAL_IP, LOCAL_PORT))
    s.setblocking(False)

    print(f"UDP 测试 {BOARD_IP}:{BOARD_PORT} <- {LOCAL_IP}:{LOCAL_PORT}")
    try:
        if args.mode == "burst":
            run_burst(s, args)
        else:
            run_flood(s, args)
    except KeyboardInterrupt:
        print("\n中断")
    finally:
        s.close()


if __name__ == "__main__":
    main()
