#!/usr/bin/env python3
"""Pack width_cp.bin (one byte per code point, written by `alacritty_row --width-table`,
from the unicode-width crate alacritty_terminal uses) into width.bin, a two-stage table:
  bytes [0, 4352)          stage 1: the block number of each 256-code-point block
  bytes [4352, 4352+256*n) stage 2: n distinct blocks of 256 widths
Widths: 0 zero-width (joins the previous cell), 1, 2, 3 a control (dropped)."""
import sys
raw = open(sys.argv[1], 'rb').read()
assert len(raw) == 0x110000
blocks, index, stage1 = [], {}, bytearray()
for b in range(0x110000 // 256):
    blk = raw[b * 256:(b + 1) * 256]
    if blk not in index:
        index[blk] = len(blocks)
        blocks.append(blk)
    stage1.append(index[blk])
assert len(blocks) <= 256, len(blocks)
open(sys.argv[2], 'wb').write(bytes(stage1) + b''.join(blocks))
print(f'{len(blocks)} distinct blocks, {len(stage1) + 256 * len(blocks)} bytes')
