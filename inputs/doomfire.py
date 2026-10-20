#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later (it follows DOOM-fire-zig, which is GPL-3.0; see THIRD_PARTY.md)
"""Write what DOOM-fire-zig (const-void/DOOM-fire-zig, commit eb0631b) sends to
a terminal of COLSxROWS, for FRAMES frames.

The bytes follow its showDoomFire: the same palette, the same "only change a
color when it differs from the previous pixel" rule, a half-block per cell,
and "\\r\\n" after each row (the program writes "\\n"; the tty adds the "\\r").
The fire's random spread comes from Python's generator with a fixed seed rather
than Zig's, so the pictures differ but the byte stream has the same shape.

  doomfire.py OUT [--cols 174] [--rows 39] [--frames 250]
"""
import argparse
import random

PALETTE = [0, 233, 234, 52, 53, 88, 89, 94, 95, 96, 130, 131, 132, 133, 172, 214, 215, 220, 220,
           221, 3, 226, 227, 230, 195, 230]
CSI = '\x1b['


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('--cols', type=int, default=174)
    ap.add_argument('--rows', type=int, default=39)
    ap.add_argument('--frames', type=int, default=250)
    ap.add_argument('--seed', type=int, default=1)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    w, h = a.cols, a.rows * 2
    fg = [f'{CSI}38;5;{i}m' for i in range(256)]
    bg = [f'{CSI}48;5;{i}m' for i in range(256)]
    white = len(PALETTE) - 1
    buf = [0] * (w * h)
    for x in range(w):
        buf[(h - 1) * w + x] = white
    out = []
    # term_on, then the fire's own reset.
    out.append(f'{CSI}?1049h{CSI}?25l{CSI}1;1H{CSI}48;5;0m{CSI}38;5;15m{CSI}2J')
    out.append(f'{CSI}1;1H{CSI}0m{CSI}48;5;0m{CSI}38;5;15m{CSI}2J')
    init_frame = f'{CSI}1;1H' + bg[0] + fg[0]
    prev_hi = prev_lo = 0
    for _ in range(a.frames):
        for x in range(w):
            for y in range(h):
                idx = y * w + x
                px = buf[idx]
                if px == 0 and idx >= w:
                    buf[idx - w] = 0
                else:
                    r = rng.randint(0, 3)
                    dst = idx - r + 1 if idx >= r + 1 else idx
                    if dst >= w:
                        buf[dst - w] = px - (r & 1) if px > (r & 1) else 0
        frame = [init_frame]
        for y in range(0, h, 2):
            for x in range(w):
                hi = buf[y * w + x]
                lo = buf[(y + 1) * w + x]
                if lo != prev_lo:
                    frame.append(bg[PALETTE[lo]])
                if hi != prev_hi:
                    frame.append(fg[PALETTE[hi]])
                frame.append('▀')
                prev_hi, prev_lo = hi, lo
            frame.append('\r\n')
        out.append(''.join(frame))
    data = ''.join(out).encode()
    with open(a.out, 'wb') as f:
        f.write(data)
    print(f'doomfire: {a.frames} frames, {len(data)} B')


main()
