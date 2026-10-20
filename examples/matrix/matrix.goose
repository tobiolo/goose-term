// Digital rain, in any terminal that takes 24-bit color: gterm, alacritty,
// xterm, ... Each column has a drop falling at its own speed. The cell it
// reaches lights up white-green, and every lit cell fades a little each
// frame, so each drop leaves a trail; now and then a lit character changes.
// Only cells whose shade changed are written, so a frame costs a few
// kilobytes whatever the size of the terminal.
//
//   matrix [--fps N] [--density PERCENT] [--kana] [--seconds N]
//
// Any key quits (or Ctrl+C). --kana rains half-width katakana, as in the
// film, for a font that has them; the default is Latin, digits, Greek and
// symbols, which gterm's DejaVu Sans Mono draws. --seconds stops by itself.

import std;
import os;

extern "mx_tty_size" fn tty_size(cols: i64&, rows: i64&) -> i32;
extern "mx_tty_raw" fn tty_raw();
extern "mx_tty_restore" fn tty_restore();
extern "mx_tty_key" fn tty_key() -> i32;
extern "mx_tty_quit_signal" fn tty_quit_signal() -> i32;

let LATIN = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ$+-*/=%\"'#&_(),.;:?!\\|{}<>[]^~";
let SHADES = 12;                // shades of green, from dark to the head's white

struct Drop { y: f32, speed: f32, wait: i64 }

var cols = 0;
var rows = 0;
var glyph: u32[>..] = [];       // the character of each cell
var level: u8[>..] = [];        // how lit each cell is, 0 dark to 255 a head
var shown: u8[>..] = [];        // the shade each cell was last drawn in
var drops: Drop[>..] = [];
var pool: u32[>..] = [];
var r = rng { 0x5EED };
var out: u8[>..] = [];

fn random_glyph() -> u32 { pool[r.rand_int(pool.len)] }

fn new_drop(first: bool) -> Drop {
    return Drop {
        // At the start, drops are already anywhere on the screen.
        y: if first { -(r.rand_int(rows * 2) as f32) } else { -(r.rand_int(rows) as f32) },
        speed: 0.3 + r.rand_flt() as f32 * 0.9,
        wait: if first { r.rand_int(rows * 3) } else { r.rand_int(40) },
    };
}

fn setup(c: i64, rws: i64) {
    cols = c;
    rows = rws;
    let n = cols * rows;
    glyph.resize(0);
    level.resize(0);
    shown.resize(0);
    glyph.resize(n, ' ');
    level.resize(n, 0);
    shown.resize(n, 0);
    drops.resize(0);
    for x in cols { drops.push(new_drop(true)); }
    out.append("\x1b[0m\x1b[2J");
}

// The color of a shade: black to green, the brightest a pale head.
fn color(shade: i64) {
    if shade == SHADES {
        out.append("\x1b[38;2;220;255;220m");
        return;
    }
    let g = 40 + shade * 200 / (SHADES - 1);
    let rb = if shade > SHADES - 3 { 60 } else { 0 };
    out.append("\x1b[38;2;");
    format(out, rb, ";", g, ";", rb / 2, "m");
}

fn step(density: i64) {
    for x in cols {
        let d .= drops[x];
        if d.wait > 0 { d.wait -= 1; continue; }
        let before = d.y as! i64;
        d.y += d.speed;
        let now = d.y as! i64;
        // Light every cell the head passed this frame.
        for y in max(before + 1, 0)..min(now + 1, rows) {
            let i = y * cols + x;
            glyph[i] = random_glyph();
            level[i] = 255;
        }
        if now >= rows + 20 {
            d = new_drop(false);
            // Fewer drops where the density is low: some wait longer.
            if r.rand_int(100) >= density { d.wait += r.rand_int(rows * 3); }
        }
    }
    for i in level.len {
        let v = level[i] as i64;
        if v == 0 { continue; }
        // The head turns green as it moves on; the trail fades.
        let next = if v == 255 { 230 } else { max(v - 6 - r.rand_int(3), 0) };
        level[i] = next as u8;
        if v > 40 && r.rand_int(400) == 0 { glyph[i] = random_glyph(); shown[i] = 255; }
    }
}

fn draw() {
    var last_shade = -1;
    var at = -1;                // the cell the terminal's cursor is on, -1 unknown
    for i in level.len {
        let v = level[i] as i64;
        let shade = if v == 255 { SHADES } else if v == 0 { 0 } else { 1 + v * (SHADES - 1) / 231 };
        let s = shade as u8;
        if s == shown[i] { continue; }
        shown[i] = s;
        if at != i {
            out.append("\x1b[");
            format(out, i / cols + 1, ";", i % cols + 1, "H");
        }
        if shade == 0 {
            out.push(' ');
        } else {
            if shade != last_shade { color(shade); last_shade = shade; }
            push_utf8(out, glyph[i]);
        }
        // The last column leaves the cursor in place (pending wrap).
        at = if (i + 1) % cols == 0 { -1 } else { i + 1 };
    }
}

fn flush() {
    if out.len > 0 { write_stdout(out); flush_stdout(); out.clear(); }
}

fn main() {
    var fps = 30;
    var density = 45;
    var kana = false;
    var seconds = -1;
    let a = args();
    var i = 1;
    while i < a.len {
        let s = a[i];
        if s == "--kana" { kana = true; i += 1; continue; }
        guard i + 1 < a.len else { abort(str("matrix: ", s, " needs a value")); }
        let n, ok = parse_int(a[i + 1]);
        guard ok else { abort(str("matrix: not a number: ", a[i + 1])); }
        if s == "--fps" { fps = max(n, 1); }
        else if s == "--density" { density = max(min(n, 100), 1); }
        else if s == "--seconds" { seconds = n; }
        else { abort(str("matrix: unknown option ", s)); }
        i += 2;
    }
    if kana {
        for c in 0xFF66..0xFF9E { pool.push(c as u32); }
        for c in "0123456789" { pool.push(c); }
    } else {
        for c in LATIN { pool.push(c); }
        for c in 0x3B1..0x3CA { pool.push(c as u32); }      // Greek
    }
    r = rng { time_ns() as u64 | 1 };

    var c = 80;
    var rw = 24;
    if tty_size(c, rw) == 0 { abort("matrix: stdout is not a terminal"); }
    tty_raw();
    // The alternate screen, no cursor, no wrapping at the last column.
    out.append("\x1b[?1049h\x1b[?25l\x1b[?7l");
    setup(c, rw);
    let start = time();
    let frame_ms = 1000 / fps;
    loop {
        let t0 = time_ns();
        if tty_key() >= 0 || tty_quit_signal() != 0 { break; }
        if seconds >= 0 && time() - start > seconds { break; }
        var nc = c;
        var nr = rw;
        if tty_size(nc, nr) != 0 && (nc != cols || nr != rows) { setup(nc, nr); }
        step(density);
        draw();
        flush();
        let spent = (time_ns() - t0) / 1000000;
        if spent < frame_ms { sleep_ms(frame_ms - spent); }
    }
    out.append("\x1b[0m\x1b[?7h\x1b[?25h\x1b[?1049l");
    flush();
    tty_restore();
}
