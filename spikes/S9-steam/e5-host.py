#!/usr/bin/env python3
"""E5 host side: round trips over the hot-added `seemless.steam` port.

  e5-host.py SOCK [N]

Connects to the chardev's unix socket, waits until the guest echo
(e5-guest.ps1) answers, then sends N messages of each size and waits for
each one to come back whole before sending the next. Prints p50/p90/p99/max
in microseconds and the throughput of the largest size.
"""
import os, socket, statistics, sys, time

SIZES = [16, 256, 4096, 65536]


def recv_exact(s, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise SystemExit('socket closed')
        buf += chunk
    return bytes(buf)


def main():
    path = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)

    # Wait for the guest echo: send a probe every second until it comes back.
    s.settimeout(1.0)
    probe = b'S9E5PING'
    t0 = time.time()
    while True:
        s.sendall(probe)
        try:
            if recv_exact(s, len(probe)) == probe:
                break
        except socket.timeout:
            if time.time() - t0 > 600:
                raise SystemExit('no echo from the guest after 10 min')
    s.settimeout(30)
    # Drain late echoes of earlier probes.
    s.settimeout(0.5)
    try:
        while s.recv(65536):
            pass
    except socket.timeout:
        pass
    s.settimeout(30)
    print(f'guest echo answered after {time.time() - t0:.1f} s')

    for size in SIZES:
        msg = os.urandom(size)
        for _ in range(50):  # warm-up
            s.sendall(msg); recv_exact(s, size)
        rtts = []
        start = time.perf_counter()
        for _ in range(n):
            t = time.perf_counter_ns()
            s.sendall(msg)
            if recv_exact(s, size) != msg:
                raise SystemExit(f'corrupt echo at size {size}')
            rtts.append((time.perf_counter_ns() - t) / 1000)
        total = time.perf_counter() - start
        q = statistics.quantiles(rtts, n=100)
        mbps = 2 * size * n / total / 1e6
        print(f'size {size:6d} B  n={n}  p50 {q[49]:8.1f} us  p90 {q[89]:8.1f}  '
              f'p99 {q[98]:8.1f}  max {max(rtts):8.1f}  ({mbps:.1f} MB/s both ways)')


if __name__ == '__main__':
    main()
