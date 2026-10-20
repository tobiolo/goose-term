// The Goose row: feed a recorded byte stream to the terminal core in chunks,
// as a pty read would deliver it, then print the canonical dump that every
// row prints (tests/DUMP.md).
//
//   vt_row <input> [--cols N] [--rows N] [--history N] [--chunk N] [--dump FILE]

import std;
import os;
import .vt;

fn fnv(h: u64&, s: const u8[:]) {
    for b in s { h = (h ^ b) * 1099511628211; }
}

fn color(out: u8[>..]&, c: u32) {
    if c == 0 { out.push('d'); return; }
    if c & vt::C_RGB != 0 {
        out.push('#');
        format_uint(out, c & 0xFFFFFF, 16, 6, '0');
        return;
    }
    out.push('i');
    format(out, c & 255);
}

fn is_blank_cp(c: u32) -> bool { c == 0 || c == ' ' }

// The canonical attribute text of one cell.
fn attr(out: u8[>..]&, c: vt::Cell) {
    let s = vt::styles[c.style];
    var base = c.cp & vt::CP_MASK;
    if c.cp & vt::F_MARKS != 0 { base = vt::marks[c.cp & vt::CP_MASK].base; }
    let blank = is_blank_cp(base) || c.cp & (vt::F_SPACER | vt::F_LEAD) != 0;
    if blank { out.push('d'); } else { color(out, s.fg); }
    out.push('/');
    color(out, s.bg);
    var bits = s.flags & (vt::A_BOLD | vt::A_DIM | vt::A_ITALIC | vt::A_INVERSE | vt::A_HIDDEN | vt::A_STRIKE);
    if s.flags & vt::A_UL_MASK != 0 { bits |= 8; }
    out.push('/');
    format(out, bits);
}

// One row, its cells blankcellded with default blanks to the screen width, as its
// text line and its attribute line.
fn row_lines(r: const vt::Cell[:], text: u8[>..]&, attrs: u8[>..]&) {
    text.clear();
    attrs.clear();
    let blankcell = vt::Cell { cp: 0, style: 0 };
    for x in vt::cols {
        let c = if x < r.len { r[x] } else { blankcell };
        if c.cp & (vt::F_SPACER | vt::F_LEAD) != 0 { continue; }
        if c.cp & vt::F_MARKS != 0 {
            var k: u32 = c.cp & vt::CP_MASK;
            let base = vt::marks[k].base;
            push_utf8(text, if is_blank_cp(base) { ' ' } else { base });
            loop {
                let m = vt::marks[k];
                for q in m.n { push_utf8(text, m.m[q]); }
                guard m.more != vt::NO_MARKS else { break; }
                k = m.more;
            }
        } else {
            let b = c.cp & vt::CP_MASK;
            push_utf8(text, if is_blank_cp(b) { ' ' } else { b });
        }
    }
    var n = text.len;
    while n > 0 && text[n - 1] == ' ' { n -= 1; }
    text.resize(n);
    var prev: u8[>..] = [];
    var one: u8[>..] = [];
    var run = 0;
    for x in vt::cols {
        one.clear();
        attr(one, if x < r.len { r[x] } else { blankcell });
        if run > 0 && one != prev {
            format(attrs, run, "*", prev, ",");
            run = 0;
        }
        if run == 0 { prev.clear(); prev.append(one); }
        run += 1;
    }
    format(attrs, run, "*", prev, ",");
}

fn main() {
    let t0 = clock_ns();
    let a = args();
    var cols = 174;
    var rows = 39;
    var history = 10000;
    var chunk = 65536;
    var dump_path: u8[>..] = [];
    var input: u8[>..] = [];
    var i = 1;
    while i < a.len {
        let s = a[i];
        if s == "--dump" {
            i += 1;
            dump_path.append(a[i]);
        } else if s == "--cols" || s == "--rows" || s == "--history" || s == "--chunk" {
            i += 1;
            let v, ok = parse_int(a[i]);
            guard ok else { abort(str("not a number: ", a[i])); }
            if s == "--cols" { cols = v; } else if s == "--rows" { rows = v; }
            else if s == "--history" { history = v; } else { chunk = v; }
        } else {
            input.clear();
            input.append(s);
        }
        i += 1;
    }
    guard input.len > 0 else { abort("usage: vt_row <input> [--cols N] [--rows N] [--history N] [--chunk N] [--dump FILE]"); }

    var data: u8[>..] = [];
    guard read_file(input, data) else { abort(str("cannot read ", input)); }
    let t1 = clock_ns();

    vt::init(cols, rows, history);
    var off = 0;
    while off < data.len {
        let end = min(off + chunk, data.len);
        vt::feed(data[off..end]);
        off = end;
    }
    let t2 = clock_ns();

    var text: u8[>..] = [];
    var attrs: u8[>..] = [];
    var full: u8[>..] = [];
    let want_dump = dump_path.len > 0;
    var ht: u64 = 14695981039346656037;
    var ha: u64 = 14695981039346656037;
    var st: u64 = 14695981039346656037;
    var sa: u64 = 14695981039346656037;
    // The dump shows the active screen's history: the alternate screen has none.
    let shown = if vt::alt() { 0 } else { vt::hist_len };
    for k in shown {
        row_lines(vt::history_line(k), text, attrs);
        fnv(ht, text); fnv(ht, "\n");
        fnv(ha, attrs); fnv(ha, "\n");
        if want_dump { format(full, "H ", text, "\n  ", attrs, "\n"); }
    }
    for y in rows {
        row_lines(vt::peek(y), text, attrs);
        fnv(st, text); fnv(st, "\n");
        fnv(sa, attrs); fnv(sa, "\n");
        if want_dump { format(full, "S ", text, "\n  ", attrs, "\n"); }
    }
    if want_dump { guard write_file(dump_path, full) else { abort("cannot write the dump"); } }
    let t3 = clock_ns();

    write_stderr(str("phases_ms read ", (t1 - t0) / 100000 / 10.0, " feed ", (t2 - t1) / 100000 / 10.0,
                     " dump ", (t3 - t2) / 100000 / 10.0, " teardown 0.0\n"));
    print("bytes ", data.len);
    print("size ", rows, " ", cols);
    print("cursor ", vt::cur.y, " ", vt::cur.x);
    print("history ", shown);
    print("history_text ", ht);
    print("history_attr ", ha);
    print("screen_text ", st);
    print("screen_attr ", sa);
}
