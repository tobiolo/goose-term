#!/usr/bin/env python3
"""Record what a vtebench benchmark writes to a terminal of COLSxROWS.

The setup script (if any) and one run of the benchmark script run under a pty
of that size, so `tput` and the tty's output processing (\\n to \\r\\n) are as a
real terminal would have them. The input is the setup's bytes, then the
benchmark's bytes repeated until the input is at least MIN_BYTES long: what a
terminal receives over that many vtebench samples.

  capture.py BENCH_DIR OUT [--cols 174] [--rows 39] [--min-bytes 16777216]
"""
import argparse
import fcntl
import os
import pty
import struct
import termios


def run_in_pty(script, cols, rows):
    pid, fd = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
        os.environ['TERM'] = 'xterm-256color'
        os.environ['LC_ALL'] = 'C.UTF-8'
        os.execv('/bin/sh', ['/bin/sh', script])
    out = bytearray()
    while True:
        try:
            chunk = os.read(fd, 1 << 16)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    os.waitpid(pid, 0)
    os.close(fd)
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('bench')
    ap.add_argument('out')
    ap.add_argument('--cols', type=int, default=174)
    ap.add_argument('--rows', type=int, default=39)
    ap.add_argument('--min-bytes', type=int, default=16 << 20)
    a = ap.parse_args()
    setup = os.path.join(a.bench, 'setup')
    head = run_in_pty(setup, a.cols, a.rows) if os.path.exists(setup) else b''
    body = run_in_pty(os.path.join(a.bench, 'benchmark'), a.cols, a.rows)
    assert body, 'the benchmark wrote nothing'
    reps = max(1, -(-(a.min_bytes - len(head)) // len(body)))
    with open(a.out, 'wb') as f:
        f.write(head)
        for _ in range(reps):
            f.write(body)
    print(f'{os.path.basename(a.out)}: setup {len(head)} B, run {len(body)} B x {reps}')


main()
