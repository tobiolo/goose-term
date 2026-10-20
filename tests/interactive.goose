// What the core does for an interactive front end, which the benchmark
// dumps never see: replies to DSR and DA, the OSC title, mouse modes, and
// resizing. Prints "ok" and exits 0, or aborts at the first failure.
//
//   goose build tests/interactive.goose -o .out/bin/interactive && .out/bin/interactive

import std;
import vt from "../core";

fn text(y: i64) -> u8[>..] {
    var out: u8[>..] = [];
    for c in vt::peek(y) {
        let cp = c.cp & vt::CP_MASK;
        if c.cp & vt::F_SPACER != 0 { continue; }
        push_utf8(out, if cp == 0 { ' ' } else { cp });
    }
    while out.len > 0 && out[out.len - 1] == ' ' { out.resize(out.len - 1); }
    return out;
}

fn expect(what: const u8[:], got: const u8[:], want: const u8[:]) {
    if got != want { abort(str(what, ": got \"", got, "\", want \"", want, "\"")); }
}

fn expect_int(what: const u8[:], got: i64, want: i64) {
    if got != want { abort(str(what, ": got ", got, ", want ", want)); }
}

fn main() {
    vt::init(10, 4, 100);

    // DSR and DA.
    vt::feed("ab\x1b[2;3H\x1b[6n\x1b[5n\x1b[c\x1b[>c\x1b[?6n");
    expect("replies", vt::replies, "\x1b[2;3R\x1b[0n\x1b[?6c\x1b[>0;2600;1c");
    vt::replies.clear();

    // OSC titles, ended by BEL or by ST, and one that is not a title.
    vt::feed("\x1b]0;one\x07");
    expect("title", vt::title, "one");
    vt::title_changed = false;
    vt::feed("\x1b]2;two words\x1b\\");
    expect("title", vt::title, "two words");
    vt::title_changed = false;
    vt::feed("\x1b]7;file://host/tmp\x07");
    expect("title", vt::title, "two words");
    if vt::title_changed { abort("OSC 7 changed the title"); }

    // Mouse modes.
    vt::feed("\x1b[?1002h\x1b[?1006h");
    expect_int("mouse", vt::mouse_mode, 1002);
    if !vt::sgr_mouse { abort("1006 not set"); }
    vt::feed("\x1b[?1000l");
    expect_int("mouse after 1000l", vt::mouse_mode, 1002);
    vt::feed("\x1b[?1002l\x1b[?1006l");
    expect_int("mouse off", vt::mouse_mode, 0);

    // Resizing. Four lines on a 4-row screen, the cursor on the last.
    vt::feed("\x1b[H\x1b[2J1111111111\r\n22\r\n33\r\n44");
    // (ED 2 on the primary screen moved the old rows into the scrollback.)
    let h0 = vt::hist_len;
    // Narrower: rows are cut; fewer rows: the top ones go to the scrollback.
    vt::resize(5, 2);
    expect("row 0", text(0), "33");
    expect("row 1", text(1), "44");
    expect_int("history", vt::hist_len - h0, 2);
    expect_int("cursor y", vt::cur.y, 1);
    expect_int("cursor x", vt::cur.x, 2);
    // Wider and taller: rows padded, the new ones blank, the cursor kept.
    vt::resize(12, 5);
    expect("row 0", text(0), "33");
    expect("row 2", text(2), "");
    expect_int("cursor y", vt::cur.y, 1);
    vt::feed("x\r\nnext");
    expect("row 1", text(1), "44x");
    expect("row 2", text(2), "next");
    // Writing to the full new width works, and wrapping too.
    vt::feed("\r\n123456789012345");
    expect("row 3", text(3), "123456789012");
    expect("row 4", text(4), "345");

    // The alternate screen keeps its own cursor through a resize.
    vt::feed("\x1b[?1049h\x1b[3;4Halt");
    vt::resize(8, 2);
    if !vt::alt() { abort("left the alternate screen"); }
    expect_int("alt cursor y", vt::cur.y, 1);
    expect("alt row 1", text(1), "   alt");
    vt::feed("\x1b[?1049l");
    expect_int("primary rows", vt::nrows, 2);
    expect("primary row 1", text(1), "345");

    // A wide character cut in half by a narrower screen goes.
    vt::feed("\x1b[H\x1b[2Jabc中");
    vt::resize(4, 2);
    expect("cut wide", text(0), "abc");
    vt::resize(6, 2);
    vt::feed("\x1b[1;5H中");
    expect("wide again", text(0), "abc 中");

    print("ok");
}
