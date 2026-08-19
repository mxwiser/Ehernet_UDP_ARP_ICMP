import socket
import struct
import time
import select

BOARD_IP   = "10.10.1.10"  #板子IP
BOARD_PORT = 8090          #板子端口
LOCAL_IP   = "10.10.1.11"  #电脑IP   （源IP）
LOCAL_PORT = 9090          #电脑端口 （源端口）
TIMEOUT_S  = 5             #等待回包超时
INTERVAL_S = 0.005         #每10毫秒测一次
PAYLOAD_SIZE = 8           #UDP payload size in bytes; minimum 8


def ping_once(s, seq):
    payload = struct.pack(">II", 0xAA55AA55, seq)
    payload += bytes(PAYLOAD_SIZE - len(payload))
    start = time.monotonic()
    s.sendto(payload, (BOARD_IP, BOARD_PORT))
    wrong = []

    while time.monotonic() - start < TIMEOUT_S:
        readable, _, _ = select.select([s], [], [], TIMEOUT_S - (time.monotonic() - start))
        if not readable:
            break
        data, addr = s.recvfrom(2048)
        if addr[0] != BOARD_IP or len(data) < 8:
            wrong.append((addr, len(data), data))
            continue
        magic, rseq = struct.unpack(">II", data[:8])
        if magic == 0xAA55AA55 and rseq == seq:
            return time.monotonic() - start, None
        wrong.append((addr, len(data), data))
    return None, wrong


def main():
    if not 8 <= PAYLOAD_SIZE <= 65507:
        raise ValueError("PAYLOAD_SIZE must be between 8 and 65507 bytes")

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((LOCAL_IP, LOCAL_PORT))
    s.setblocking(False)

    print(
        f"UDP ping {BOARD_IP}:{BOARD_PORT}, payload {PAYLOAD_SIZE} bytes, "
        f"interval {INTERVAL_S}s, timeout {TIMEOUT_S}s"
    )

    seq = 1
    sent = 0
    lost = 0
    times = []
    deadline = time.monotonic()
    try:
        while True:
            rtt, wrong = ping_once(s, seq)
            sent += 1
            if rtt is None:
                lost += 1
                print(f"reply from {BOARD_IP}: seq={seq} timeout")
                if wrong:
                    print(f"  got {len(wrong)} wrong reply(s):")
                    for addr, ln, data in wrong[:5]:
                        head = data[:8].hex(" ")
                        try:
                            magic, rseq = struct.unpack(">II", data[:8])
                            info = f"magic=0x{magic:08X} rseq={rseq}"
                        except struct.error:
                            info = "payload too short"
                        print(f"    from {addr[0]}:{addr[1]} len={ln} {info} [{head}...]")
                    if len(wrong) > 5:
                        print(f"    ... and {len(wrong) - 5} more")
            else:
                times.append(rtt)
                ms = rtt * 1000
                print(f"reply from {BOARD_IP}: seq={seq} time={ms:.3f} ms")

            delay = deadline + INTERVAL_S - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            deadline += INTERVAL_S
            seq += 1
    except KeyboardInterrupt:
        pass
    finally:
        s.close()

    loss = lost / sent * 100 if sent else 0
    print(f"\n--- {BOARD_IP} UDP ping statistics ---")
    print(f"{sent} packets transmitted, {sent - lost} received, {loss:.1f}% packet loss")
    if times:
        print(f"rtt min/avg/max = {min(times) * 1000:.3f}/{sum(times) / len(times) * 1000:.3f}/{max(times) * 1000:.3f} ms")


if __name__ == "__main__":
    main()
