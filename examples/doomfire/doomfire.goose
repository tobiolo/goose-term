// SPDX-License-Identifier: GPL-3.0-or-later (it follows DOOM-fire-zig, which is GPL-3.0; see THIRD_PARTY.md)
//
// DOOM-fire-zig (const-void/DOOM-fire-zig, commit eb0631b) in Goose: the
// frame-rate test of vizenc/terminal-benchmark. The fire's rules, palette
// and output are DOOM-fire-zig's:
// - a half block per cell, two fire pixels high;
// - a color written only when it differs from the cell before;
// - "\n" after each row;
// - the whole frame in one write, minus its last byte, as DOOM-fire-zig
//   does;
// - then its status line with the frames per second so far.
// A write blocks while the terminal is behind, so the frame rate is how
// fast the terminal takes the frames in.
//
//   doomfire [--seconds N] [--out FILE]
//
// It runs until a key (or Ctrl+C), or for N seconds, and then writes the
// average frames per second to FILE, as a number on a line.

import std;
import os;

extern "mx_tty_size" fn tty_size(cols: i64&, rows: i64&) -> i32;
extern "mx_tty_raw" fn tty_raw();
extern "mx_tty_restore" fn tty_restore();
extern "mx_tty_key" fn tty_key() -> i32;
extern "mx_tty_quit_signal" fn tty_quit_signal() -> i32;

let PALETTE: u8[26] = [0, 233, 234, 52, 53, 88, 89, 94, 95, 96, 130, 131, 132, 133, 172, 214, 215,
                       220, 220, 221, 3, 226, 227, 230, 195, 230];

fn main() {
    var seconds = -1.0;
    var out_path: u8[>..] = [];
    let a = args();
    var i = 1;
    while i < a.len {
        guard i + 1 < a.len else { abort(str("doomfire: ", a[i], " needs a value")); }
        if a[i] == "--out" { out_path.append(a[i + 1]); }
        else if a[i] == "--seconds" {
            let n, ok = parse_int(a[i + 1]);
            guard ok else { abort(str("doomfire: not a number: ", a[i + 1])); }
            seconds = n;
        } else { abort(str("doomfire: unknown option ", a[i])); }
        i += 2;
    }
    var cols = 80;
    var rows = 24;
    if tty_size(cols, rows) == 0 { abort("doomfire: stdout is not a terminal"); }
    tty_raw();

    let w = cols;
    let h = rows * 2;
    let white = PALETTE.len - 1;
    var fire: u8[>..] = [];
    fire.resize(w * h, 0);
    for x in w { fire[(h - 1) * w + x] = white as u8; }
    var r = rng { 1 };
    // Escape strings per color, as DOOM-fire-zig keeps them.
    var fg: u8[>..] = [];
    var bg: u8[>..] = [];
    var fg_at: i64[257] = [0; 257];
    var bg_at: i64[257] = [0; 257];
    for c in 256 {
        fg_at[c] = fg.len;
        fg.append("\x1b[38;5;");
        format(fg, c, "m");
        bg_at[c] = bg.len;
        bg.append("\x1b[48;5;");
        format(bg, c, "m");
    }
    fg_at[256] = fg.len;
    bg_at[256] = bg.len;

    var buf: u8[>..] = [];
    // DOOM-fire-zig's terminal setup, then its reset for the fire.
    buf.append("\x1b[?1049h\x1b[?25l\x1b[1;1H\x1b[48;5;0m\x1b[38;5;15m\x1b[2J");
    buf.append("\x1b[1;1H\x1b[0m\x1b[48;5;0m\x1b[38;5;15m\x1b[2J");
    write_stdout(buf);
    flush_stdout();
    var prev_hi = 0;
    var prev_lo = 0;
    var frames = 0;
    let t0 = time();
    var fps = 0.0;
    loop {
        if tty_key() >= 0 || tty_quit_signal() != 0 { break; }
        if seconds >= 0.0 && time() - t0 >= seconds { break; }
        // Spread the fire, column by column, bottom row the source.
        for x in w {
            for y in h {
                let idx = y * w + x;
                let px = fire[idx];
                if px == 0 && idx >= w {
                    fire[idx - w] = 0;
                } else {
                    let rnd = r.rand_int(4);
                    let dst = if idx >= rnd + 1 { idx - rnd + 1 } else { idx };
                    if dst >= w {
                        fire[dst - w] = if px > (rnd & 1) { px - (rnd & 1) as u8 } else { 0 };
                    }
                }
            }
        }
        buf.clear();
        buf.append("\x1b[H");
        buf.append(bg[bg_at[0]..bg_at[1]]);
        buf.append(fg[fg_at[0]..fg_at[1]]);
        var y = 0;
        while y < h {
            for x in w {
                let hi = fire[y * w + x] as i64;
                let lo = fire[(y + 1) * w + x] as i64;
                if lo != prev_lo { let c = PALETTE[lo]; buf.append(bg[bg_at[c]..bg_at[c + 1]]); }
                if hi != prev_hi { let c = PALETTE[hi]; buf.append(fg[fg_at[c]..fg_at[c + 1]]); }
                buf.append("▀");
                prev_hi = hi;
                prev_lo = lo;
            }
            buf.push('\n');
            y += 2;
        }
        write_stdout(buf[..buf.len - 1]);
        frames += 1;
        fps = frames / (time() - t0);
        buf.clear();
        buf.append(fg[fg_at[0]..fg_at[1]]);
        buf.append("mem: [ ");
        format_flt(buf, fps, 2);
        buf.append(" fps ]");
        write_stdout(buf);
        flush_stdout();
    }
    buf.clear();
    buf.append("\x1b[0m\x1b[?25h\x1b[?1049l");
    write_stdout(buf);
    flush_stdout();
    tty_restore();
    if out_path.len > 0 {
        var line: u8[>..] = [];
        format_flt(line, fps, 2);
        line.push('\n');
        guard write_file(out_path, line) else { abort(str("doomfire: cannot write ", out_path)); }
    }
}
