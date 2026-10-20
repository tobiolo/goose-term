# The canonical dump

Every row ends the same way: it reads the whole input, feeds it to its
terminal in `--chunk` byte pieces (65536 by default, as a pty read might
deliver it), and then prints eight lines on stdout:

```
bytes N               the input's length
size ROWS COLS        the terminal's size (39 x 174 by default)
cursor Y X            the cursor, 0-based
history N             the scrollback lines shown (see below)
history_text H        FNV-1a 64 over the text line of each scrollback line, oldest first
history_attr H        ... over the attribute line of each scrollback line
screen_text H         ... over the text line of each screen row, top to bottom
screen_attr H         ... over the attribute line of each screen row
```

Each line hashed is followed by `"\n"`, also hashed. Two rows agree when they
print the same eight lines. `--dump FILE` also writes every line in
the clear (`H text` / `  attrs` for scrollback, `S text` / `  attrs` for the
screen). `tests/diff.py` diffs those files when the checksums differ.

## Which lines

The screen is the active screen: the alternate one while mode 1049 is set.
The scrollback is the active screen's, as alacritty keeps it. So it is
empty while the alternate screen is up, and has at most `--history` lines
(10000 by default). A scrollback line shorter than the terminal is padded
with default blank cells.

## The text line of a row

For each cell, left to right:

- The right half of a wide character is skipped. So is the blank that
  stands in the last column when a wide character wrapped to the next line
  (alacritty's `LEADING_WIDE_CHAR_SPACER`).
- An empty cell and a tab are written as a space, and any other character
  as UTF-8.
- The zero-width characters attached to the cell follow it, in the order
  they arrived.

Trailing spaces are then removed.

## The attribute line of a row

Run-length encoded: one `COUNT*FG/BG/BITS,` per run of equal cells, over all
`COLS` cells.

- FG and BG are `d` (the default color), `iN` (palette entry N, 0-255) or
  `#rrggbb`.
- The FG of a blank cell (a space, an empty cell, or either spacer) is
  always `d`. Terminals differ in what they keep there and it cannot be
  seen.
- BITS is the sum of: bold 1, dim 2, italic 4, underline of any kind 8,
  reverse 16, hidden 32, strikeout 64. Blink and the underline color are
  not compared. libvterm has no dim, so its row never sets 2.

## What the rows do to get there

- alacritty (`baselines/alacritty_row/src/main.rs`): a `Term` behind
  `vte::ansi::Processor`. After the last chunk it calls
  `parser.stop_sync`, so a synchronized update still open at the end is
  applied, as alacritty does when its timeout fires.
- libvterm (`baselines/libvterm_row.c`): `VTermScreen` with the alternate
  screen on. It keeps its scrollback the way Neovim does, as a ring of copied
  lines from `sb_pushline`.
- Goose (`core/vt_row.goose`): the core keeps its own scrollback.
