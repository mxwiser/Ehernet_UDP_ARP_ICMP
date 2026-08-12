import socket
import struct
import time
import select

BOARD_IP   = "10.10.1.10"  #板子IP
BOARD_PORT = 8080          #板子端口
LOCAL_IP   = "10.10.1.11"  #电脑IP   （源IP）
LOCAL_PORT = 9000          #电脑端口 （源端口）
SEND_COUNT = 10000
INTERVAL_MS = 1


def drain(s, received):
    while True:
        readable, _, _ = select.select([s], [], [], 0)
        if not readable:
            break
        data, addr = s.recvfrom(2048)
        if addr[0] == BOARD_IP and len(data) >= 8:
            magic, seq = struct.unpack(">II", data[:8])
            if magic == 0xAA55AA55:
                received[seq] = data


def main():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((LOCAL_IP, LOCAL_PORT))
    s.setblocking(False)

    sent = {}
    received = {}

    print(f"send {SEND_COUNT} packets to {BOARD_IP}:{BOARD_PORT}, interval {INTERVAL_MS}ms")

    deadline = time.monotonic()
    for i in range(SEND_COUNT):
        payload = struct.pack(">II", 0xAA55AA55, i) + bytes(16)
        sent[i] = payload
        s.sendto(payload, (BOARD_IP, BOARD_PORT))

        drain(s, received)

        delay = deadline - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        deadline += INTERVAL_MS / 1000

    drain_start = time.time()
    while time.time() - drain_start < 5:
        drain(s, received)
        time.sleep(0.01)

    ok = 0
    bad = 0
    for seq, payload in sent.items():
        if seq not in received:
            continue
        if received[seq] == payload:
            ok += 1
        else:
            bad += 1

    missing = SEND_COUNT - ok - bad
    print(f"total sent: {SEND_COUNT}")
    print(f"reply ok:   {ok}")
    print(f"reply corrupt: {bad}")
    print(f"reply lost: {missing}")
    print(f"loss rate:  {missing / SEND_COUNT * 100:.4f}%")
    if bad:
        print(f"WARNING: {bad} corrupt replies detected")

    s.close()


if __name__ == "__main__":
    main()
