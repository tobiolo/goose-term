// The terminal core: a VT parser, the screen grids and the scrollback.
//
// The parser is the DEC/ANSI state machine (vt100.net/emu/dec_ansi_parser) as
// vte 0.15 implements it, and the screen follows alacritty_terminal 0.26 rule
// for rule, quirks included, so the two give the same screen for the same
// bytes (tests/DUMP.md says what "the same" means).
//
// The data layout:
// - A cell is 6 bytes: a code point with flag bits, and a 16-bit style id.
//   Styles (colors and attributes) are interned in one table, so changing the
//   pen costs a lookup and writing a cell costs 6 bytes.
// - Both screens' rows live in one array of cells. `rowmap` gives the
//   physical row behind each row, so scrolling rotates a few row numbers and
//   moves no cells.
// - Scrollback lines are copied out of the screen without their trailing
//   blanks, into 16K-cell pages taken from a reusable pool. A ring of line
//   records keeps exactly `hist_cap` lines; a page goes back to the pool when
//   its last line is evicted.
// - Zero-width characters are rare: a cell that has any points at an entry
//   of `marks`, which holds the base character and up to MAXMARKS marks, and
//   links to another entry for more.

import std;
import dictionary;

namespace vt;

// --- cells and styles ------------------------------------------------------------

struct Cell { cp: u32, style: u16 }

let CP_MASK = 0x1FFFFF;
let F_WIDE = 0x200000;       // the first half of a wide character
let F_SPACER = 0x400000;     // the second half
let F_LEAD = 0x800000;       // a blank left where a wide character did not fit
let F_WRAP = 0x1000000;      // the row wrapped after this cell
let F_MARKS = 0x2000000;     // the low bits index `marks`
let F_HALVES = 0x600000;     // F_WIDE | F_SPACER

// A color: 0 is the default, C_INDEXED | n a palette entry, C_RGB | 0xrrggbb.
let C_INDEXED = 0x1000000;
let C_RGB = 0x2000000;

// Attribute bits. The underline kind (1 single .. 5 dashed) is bits 8..10.
let A_BOLD = 1;
let A_DIM = 2;
let A_ITALIC = 4;
let A_INVERSE = 16;
let A_HIDDEN = 32;
let A_STRIKE = 64;
let A_UL_SHIFT = 8;
let A_UL_MASK = 0x700;

struct Style { fg: u32, bg: u32, ul: u32, flags: u16 }

fn ::hash(s: Style) -> u64 {
    ::hash_combine(::hash_combine(::hash(s.fg), ::hash(s.bg)), ::hash_combine(::hash(s.ul), ::hash(s.flags)))
}

var styles: Style[>..] = [];
var style_ids = dictionary<Style, u16> {};

fn intern(s: Style) -> u16 {
    let id = style_ids.get(s);
    if id { return id; }
    if styles.len > 65535 { abort("vt: more than 65536 styles"); }
    let n = styles.len as u16;
    styles.push(s);
    style_ids.insert(s, n);
    return n;
}

let MAXMARKS = 6;
let NO_MARKS: u32 = 0xFFFFFFFF;
struct Marks { base: u32, n: u8, m: u32[MAXMARKS], more: u32 }
var marks: Marks[>..] = [];

// --- the screens --------------------------------------------------------------------

struct Cursor { y: i64, x: i64, wrap: bool, pen: Style, g: u8[4] }

let CS_ASCII: u8 = 0;
let CS_DEC: u8 = 1;

var cols = 0;
var nrows = 0;
var cells: Cell[>..] = [];      // 2 * nrows rows of cols cells: the primary screen, then the alternate
var rowmap: i64[>..] = [];      // 2 * nrows: the physical row behind each row
var scr = 0;                    // 0 on the primary screen, nrows on the alternate
var cur: Cursor;                // the active screen's cursor
var icur: Cursor;               // the inactive screen's
var saved: Cursor[2];           // DECSC, per screen
var active_g = 0;               // SI/SO: which of cur.g is in use
var top = 0;                    // the scrolling region, [top, bot)
var bot = 0;
var tabs: bool[>..] = [];

var autowrap = true;
var origin = false;
var insert_mode = false;
var cursor_visible = true;
var cursor_shape = 0;
var app_cursor = false;
var bracketed_paste = false;

// The pen as a style id, and the style of erased cells (the pen's background
// only), each worked out when first needed after the pen changes.
var pen_id: u16 = 0;
var pen_ok = true;
var blank_id: u16 = 0;
var blank_ok = true;

fn pen() -> u16 {
    if !pen_ok { pen_id = intern(cur.pen); pen_ok = true; }
    return pen_id;
}

fn blank() -> u16 {
    if !blank_ok { blank_id = intern(Style { fg: 0, bg: cur.pen.bg, ul: 0, flags: 0 }); blank_ok = true; }
    return blank_id;
}

fn pen_changed() { pen_ok = false; blank_ok = false; }

fn alt() -> bool { scr != 0 }

// Each physical row's cells past used[row] are blank, default style, no
// flags, so the scrollback can trim them without looking. row() hands out
// the whole row for writing; the hot writers say how far they wrote instead.
var used: i64[>..] = [];

fn peek(y: i64) -> const Cell[:] {
    let b = rowmap[scr + y] * cols;
    return cells[b..b + cols];
}

fn row_to(y: i64, end: i64) -> Cell[:] {
    let p = rowmap[scr + y];
    if used[p] < end { used[p] = min(end, cols); }
    let b = p * cols;
    return cells[b..b + cols];
}

fn row(y: i64) -> Cell[:] { return row_to(y, cols); }

// The blank cells of the current blank style, to copy from.
var blank_row: Cell[>..] = [];
var blank_row_style: u16 = 0;

fn clear_cells(r: Cell[:], a: i64, b: i64) {
    let st = blank();
    if st != blank_row_style {
        fill(blank_row, Cell { cp: 0, style: st });
        blank_row_style = st;
    }
    copy_into(r[a..b], blank_row[a..b]);
}

fn reset_row(y: i64) {
    let p = rowmap[scr + y];
    let b = p * cols;
    if blank() == 0 {
        // Past used[p] the row is already default blanks.
        clear_cells(cells[b..b + cols], 0, used[p]);
        used[p] = 0;
    } else {
        clear_cells(cells[b..b + cols], 0, cols);
        used[p] = cols;
    }
}

// --- scrollback -------------------------------------------------------------------

let PAGE = 16384;
struct Page { cells: Cell[PAGE] }
let NO_PAGE: u32 = 0xFFFFFFFF;
struct Line { page: u32, off: u16, len: u16 }

reusable var pages: Page[>..] = [];
var page_live: i64[>..] = [];   // lines held in each page
var page_cur = -1;              // the page new lines go into
var page_fill = PAGE;
var hist: Line[>..] = [];       // a ring of hist_len lines, the oldest at hist_head
var hist_cap = 10000;
var hist_head = 0;
var hist_len = 0;

fn release(p: u32) {
    guard p != NO_PAGE;
    page_live[p] -= 1;
    if page_live[p] == 0 && p != page_cur { pages.free(p as i64); }
}

// A cell that the end of a scrollback line can drop: blank, default style, no flags.
fn trimmable(c: Cell) -> bool { (c.cp == 0 || c.cp == ' ') && c.style == 0 }

fn push_history(y: i64) {
    guard hist_cap > 0;
    let r = peek(y);
    var n = used[rowmap[scr + y]];
    while n > 0 && trimmable(r[n - 1]) { n -= 1; }
    if hist_len == hist_cap {
        release(hist[hist_head].page);
        hist_head = (hist_head + 1) % hist_cap;
        hist_len -= 1;
    }
    var rec = Line { page: NO_PAGE, off: 0, len: 0 };
    if n > 0 {
        if page_fill + n > PAGE {
            if page_cur >= 0 && page_live[page_cur] == 0 { pages.free(page_cur); }
            page_cur = pages.alloc_index(default<Page>());
            while page_live.len <= page_cur { page_live.push(0); }
            page_fill = 0;
        }
        copy_into(pages[page_cur].cells[page_fill..page_fill + n], r[..n]);
        rec = Line { page: page_cur as u32, off: page_fill as u16, len: n as u16 };
        page_live[page_cur] += 1;
        page_fill += n;
    }
    let slot = (hist_head + hist_len) % hist_cap;
    if slot < hist.len { hist[slot] = rec; } else { hist.push(rec); }
    hist_len += 1;
}

fn clear_history() {
    for p in page_live.len {
        if page_live[p] > 0 || p == page_cur { pages.free(p); page_live[p] = 0; }
    }
    page_cur = -1;
    page_fill = PAGE;
    hist_head = 0;
    hist_len = 0;
}

// The cells of scrollback line k, 0 the oldest; trailing blanks are not stored.
fn history_line(k: i64) -> const Cell[:] {
    let rec = hist[(hist_head + k) % hist_cap];
    if rec.page == NO_PAGE { return cells[0..0]; }
    let off = rec.off as i64;
    return pages[rec.page].cells[off..off + rec.len];
}

// --- setup ---------------------------------------------------------------------------

fn default_tabs() {
    for &t, i in tabs { t = i % 8 == 0; }
}

fn init(c: i64, r: i64, history: i64) {
    assert(c >= 2 && r > 0 && c <= 65535);
    cols = c;
    nrows = r;
    hist_cap = history;
    styles.push(default<Style>());
    style_ids.insert(default<Style>(), 0);
    cells.resize(2 * r * c, Cell { cp: 0, style: 0 });
    for i in 2 * r { rowmap.push(i); }
    used.resize(2 * r, 0);
    blank_row.resize(c, Cell { cp: 0, style: 0 });
    tabs.resize(c, false);
    default_tabs();
    top = 0;
    bot = r;
}

// --- cursor motion ---------------------------------------------------------------------

fn goto(line: i64, col: i64) {
    var y = line;
    var maxy = nrows - 1;
    if origin { y += top; maxy = bot - 1; }
    cur.y = max(min(y, maxy), 0);
    cur.x = max(min(col, cols - 1), 0);
    cur.wrap = false;
}

fn linefeed() {
    let next = cur.y + 1;
    if next == bot { scroll_up(top, 1); } else if next < nrows { cur.y = next; }
}

fn carriage_return() { cur.x = 0; cur.wrap = false; }

fn backspace() {
    if cur.x > 0 { cur.x -= 1; cur.wrap = false; }
}

fn wrapline() {
    guard autowrap;
    row_to(cur.y, cur.x + 1)[cur.x].cp |= F_WRAP;
    if cur.y + 1 >= bot { linefeed(); } else { cur.y += 1; }
    cur.x = 0;
    cur.wrap = false;
}

fn reverse_index() {
    if cur.y == top { scroll_down(top, 1); } else { cur.y = max(cur.y - 1, 0); }
}

fn put_tab() {
    if cur.wrap { wrapline(); return; }
    loop {
        if cur.x + 1 == cols { break; }
        cur.x += 1;
        if tabs[cur.x] { break; }
    }
}

fn forward_tabs(n: i64) {
    for k in n {
        if cur.x == cols - 1 { break; }
        var c = cur.x;
        for i in cur.x + 1..cols { c = i; if tabs[i] { break; } }
        cur.x = c;
    }
}

fn backward_tabs(n: i64) {
    for k in n {
        if cur.x == 0 { break; }
        var c = cur.x;
        var i = cur.x - 1;
        while i >= 0 { if tabs[i] { c = i; break; } i -= 1; }
        cur.x = c;
    }
}

// --- scrolling ----------------------------------------------------------------------------

// Rotate rowmap[a, b) of the active screen left by p.
fn rotate_rows(a: i64, b: i64, p: i64) {
    let m = rowmap[scr + a..scr + b];
    if p == 1 {
        // The common case, one line: a shift.
        let first = m[0];
        for i in m.len - 1 { m[i] = m[i + 1]; }
        m[m.len - 1] = first;
        return;
    }
    reverse(m[..p]);
    reverse(m[p..]);
    reverse(m);
}

// alacritty's Grid::scroll_up over [s, e): lines leave at the top (into the
// scrollback when the region starts at the top of the primary screen) and
// blank lines enter at the bottom.
fn grid_scroll_up(s: i64, e: i64, p: i64) {
    if e - s <= p && s != 0 {
        for y in s..e { reset_row(y); }
        return;
    }
    if p == 0 { return; }
    if s == 0 && !alt() { for y in p { push_history(y); } }
    rotate_rows(s, e, p);
    for y in e - p..e { reset_row(y); }
}

fn grid_scroll_down(s: i64, e: i64, p: i64) {
    if e - s <= p {
        for y in s..e { reset_row(y); }
        return;
    }
    if p == 0 { return; }
    rotate_rows(s, e, e - s - p);
    for y in s..s + p { reset_row(y); }
}

fn scroll_up(origin_line: i64, n: i64) {
    let p = min(n, max(bot - top, 0));
    grid_scroll_up(origin_line, bot, p);
}

fn scroll_down(origin_line: i64, n: i64) {
    let p = min(min(n, max(bot - top, 0)), bot - origin_line);
    grid_scroll_down(origin_line, bot, p);
}

// --- writing characters --------------------------------------------------------------------

var preceding: u32 = 0;         // the last character printed, for REP
var has_preceding = false;

fn charset_map(c: u32) -> u32 {
    guard cur.g[active_g] == CS_DEC && c >= 0x5F && c <= 0x7E else { return c; }
    return DEC_GRAPHICS[c - 0x5F];
}

let DEC_GRAPHICS: u32[32] = [0x20, 0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0xB0,
                             0xB1, 0x2424, 0x240B, 0x2518, 0x2510, 0x250C, 0x2514, 0x253C,
                             0x23BA, 0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534,
                             0x252C, 0x2502, 0x2264, 0x2265, 0x3C0, 0x2260, 0xA3, 0xB7];

// alacritty's write_at_cursor: overwriting half of a wide character blanks the other half.
fn write_cell(y: i64, x: i64, cp: u32, style: u16) {
    let r = row_to(y, x + 2);
    let old = r[x].cp;
    if old & F_HALVES != 0 {
        if old & F_WIDE != 0 && x < cols - 1 {
            r[x + 1].cp &= ~F_SPACER;
        } else if x > 0 {
            let p = r[x - 1].cp;
            r[x - 1].cp = ' ' | (p & (F_SPACER | F_LEAD | F_WRAP));
        }
        if x <= 1 && y > 0 { row(y - 1)[cols - 1].cp &= ~F_LEAD; }
    }
    r[x] = Cell { cp: cp, style: style };
}

fn add_mark(y: i64, x: i64, c: u32) {
    let cell .= row(y)[x];
    if marks.len > CP_MASK { abort("vt: too many cells with zero-width characters"); }
    if cell.cp & F_MARKS != 0 {
        var k: u32 = cell.cp & CP_MASK;
        while marks[k].more != NO_MARKS { k = marks[k].more; }
        if marks[k].n < MAXMARKS {
            let m .= marks[k];
            m.m[m.n] = c;
            m.n += 1;
            return;
        }
        let next = marks.len as u32;
        var m = Marks { base: 0, n: 1, m: [0; MAXMARKS], more: NO_MARKS };
        m.m[0] = c;
        marks.push(m);
        marks[k].more = next;
        return;
    }
    var m = Marks { base: cell.cp & CP_MASK, n: 1, m: [0; MAXMARKS], more: NO_MARKS };
    m.m[0] = c;
    let idx = marks.len as u32;
    marks.push(m);
    cell.cp = (cell.cp & ~CP_MASK) | F_MARKS | idx;
}

let WIDTHS = embed_file("width.bin");

fn width(c: u32) -> i64 {
    if c >= 0x110000 { return 3; }
    let blk = WIDTHS[c >> 8] as i64;
    return WIDTHS[4352 + blk * 256 + (c & 255)];
}

// alacritty's Term::input: one character.
fn input(c: u32) {
    let w = width(c);
    if w == 3 { return; }
    if w == 0 {
        var x = cur.x;
        if !cur.wrap { x = max(x - 1, 0); }
        if peek(cur.y)[x].cp & F_SPACER != 0 { x = max(x - 1, 0); }
        add_mark(cur.y, x, c);
        return;
    }
    if cur.wrap { wrapline(); }
    if insert_mode && cur.x + w < cols {
        let r = row(cur.y);
        var i = cols - w - 1;
        while i >= cur.x { swap(r[i + w], r[i]); i -= 1; }
    }
    let st = pen();
    if w == 1 {
        write_cell(cur.y, cur.x, charset_map(c), st);
    } else {
        if cur.x + 1 >= cols {
            guard autowrap else { cur.wrap = true; return; }
            write_cell(cur.y, cur.x, charset_map(' ') | F_LEAD, st);
            wrapline();
        }
        write_cell(cur.y, cur.x, charset_map(c) | F_WIDE, st);
        cur.x += 1;
        write_cell(cur.y, cur.x, charset_map(' ') | F_SPACER, st);
    }
    if cur.x + 1 < cols { cur.x += 1; } else { cur.wrap = true; }
}

fn put_char(c: u32) {
    input(c);
    preceding = c;
    has_preceding = true;
}

// A run of printable ASCII (0x20..0x7E), the common case: what input() does
// one byte at a time, a row's worth at a time.
fn print_ascii(s: const u8[:]) {
    guard s.len > 0;
    preceding = s[s.len - 1];
    has_preceding = true;
    if insert_mode || cur.g[active_g] != CS_ASCII {
        for b in s { input(b); }
        return;
    }
    let st = pen();
    var i = 0;
    while i < s.len {
        if cur.wrap {
            wrapline();
            if cur.wrap {
                // Autowrap is off: each byte overwrites the last column.
                write_cell(cur.y, cur.x, s[s.len - 1], st);
                return;
            }
        }
        let x = cur.x;
        let n = min(s.len - i, cols - x);
        write_cell(cur.y, x, s[i], st);
        if n > 1 {
            let r = row_to(cur.y, x + n);
            // Written one at a time, a wide character at x + n - 2 would have
            // lost its spacer before the last byte overwrote it.
            if r[x + n - 2].cp & F_WIDE != 0 { r[x + n - 1].cp &= ~F_SPACER; }
            let src = s[i..i + n];
            let dst = r[x..x + n];
            for k in 1..n - 1 { dst[k] = Cell { cp: src[k], style: st }; }
            write_cell(cur.y, x + n - 1, src[n - 1], st);
        }
        i += n;
        if x + n < cols { cur.x = x + n; } else { cur.x = cols - 1; cur.wrap = true; }
    }
}

// --- editing ------------------------------------------------------------------------------------

fn erase_display(mode: i64) {
    match mode {
        0 => {
            let r = row(cur.y);
            clear_cells(r, cur.x, cols);
            if cur.y < nrows - 1 { for y in cur.y + 1..nrows { reset_row(y); } }
        },
        1 => {
            if cur.y > 1 { for y in cur.y { reset_row(y); } }
            clear_cells(row(cur.y), 0, min(cur.x + 1, cols));
        },
        2 => {
            if alt() { for y in nrows { reset_row(y); } } else { clear_viewport(); }
        },
        3 => { if !alt() && hist_len > 0 { clear_history(); } },
        _ => {},
    }
}

fn empty_cell(c: Cell) -> bool {
    guard c.cp == 0 || c.cp == ' ' else { return false; }
    let s = styles[c.style];
    return s.fg == 0 && s.bg == 0 && s.flags & (A_INVERSE | A_UL_MASK | A_STRIKE) == 0;
}

// alacritty's Grid::clear_viewport: the rows down to the last non-empty one
// go into the scrollback, then every row is blank.
fn clear_viewport() {
    var last = -1;
    var y = nrows - 1;
    while y >= 0 && last < 0 {
        for c in peek(y) { if !empty_cell(c) { last = y; break; } }
        y -= 1;
    }
    let p = last + 1;
    grid_scroll_up(0, nrows, p);
    for k in nrows - p { reset_row(k); }
}

fn erase_line(mode: i64) {
    let r = row(cur.y);
    match mode {
        0 => { if !cur.wrap { clear_cells(r, cur.x, cols); } },
        1 => clear_cells(r, 0, cur.x + 1),
        2 => clear_cells(r, 0, cols),
        _ => {},
    }
}

fn erase_chars(n: i64) { clear_cells(row(cur.y), cur.x, min(cur.x + n, cols)); }

fn delete_chars(n: i64) {
    let r = row(cur.y);
    let count = min(n, cols);
    let start = cur.x;
    let end = min(start + count, cols - 1);
    for k in cols - end { swap(r[start + k], r[end + k]); }
    clear_cells(r, cols - count, cols);
}

fn insert_blank(n: i64) {
    let r = row(cur.y);
    let count = min(n, cols - cur.x);
    let src = cur.x;
    let dst = src + count;
    var k = cols - dst - 1;
    while k >= 0 { swap(r[dst + k], r[src + k]); k -= 1; }
    clear_cells(r, src, dst);
}

fn insert_lines(n: i64) {
    if cur.y >= top && cur.y < bot { scroll_down(cur.y, n); }
}

fn delete_lines(n: i64) {
    let k = min(nrows - cur.y, n);
    if k > 0 && cur.y >= top && cur.y < bot { scroll_up(cur.y, k); }
}

fn set_region(t: i64, b: i64) {
    let bottom = if b == 0 { nrows } else { b };
    guard t < bottom;
    top = min(t - 1, nrows);
    bot = min(bottom, nrows);
    goto(0, 0);
}

fn save_cursor() { saved[if alt() { 1 } else { 0 }] = cur; }

fn restore_cursor() {
    cur = saved[if alt() { 1 } else { 0 }];
    pen_changed();
}

fn swap_alt() {
    if !alt() {
        icur = cur;
        saved[0] = cur;
        scr = nrows;
        for y in nrows { reset_row(y); }
    } else {
        swap(cur, icur);
        scr = 0;
        pen_changed();
    }
}

fn reset_state() {
    if alt() { swap(cur, icur); scr = 0; }
    active_g = 0;
    cursor_shape = 0;
    clear_history();
    cur = default<Cursor>();
    icur = default<Cursor>();
    saved[0] = default<Cursor>();
    saved[1] = default<Cursor>();
    pen_changed();
    for y in nrows { reset_row(y); }
    scr = nrows;
    for y in nrows { reset_row(y); }
    scr = 0;
    top = 0;
    bot = nrows;
    default_tabs();
    autowrap = true;
    origin = false;
    insert_mode = false;
    cursor_visible = true;
    app_cursor = false;
    bracketed_paste = false;
}

fn decaln() {
    for y in nrows { fill(row(y), Cell { cp: 'E', style: 0 }); }
}

fn deccolm() {
    set_region(1, 0);
    for y in nrows { reset_row(y); }
}

fn set_private_mode(m: u16, on: bool) {
    match m {
        1 => { app_cursor = on; },
        3 => deccolm(),
        6 => { origin = on; if on { goto(0, 0); } },
        7 => { autowrap = on; },
        25 => { cursor_visible = on; },
        1049 => { if on != alt() { swap_alt(); } },
        2004 => { bracketed_paste = on; },
        _ => {},
    }
}

fn set_mode(m: u16, on: bool) {
    if m == 4 { insert_mode = on; }
}

// --- the parser ------------------------------------------------------------------------------

let GROUND = 0;
let ESCAPE = 1;
let ESC_INT = 2;
let CSI_ENTRY = 3;
let CSI_PARAM = 4;
let CSI_INT = 5;
let CSI_IGNORE = 6;
let DCS_ENTRY = 7;
let DCS_PARAM = 8;
let DCS_INT = 9;
let DCS_PASS = 10;
let DCS_IGNORE = 11;
let OSC = 12;
let SOS = 13;

let MAXPARAMS = 32;

var state = GROUND;
var pv: u16[MAXPARAMS] = [0; MAXPARAMS];      // parameter values
var pstart: bool[MAXPARAMS] = [false; MAXPARAMS]; // value i starts a group (";"), else it is a ":" subparameter
var pn = 0;
var param: u16 = 0;
var open = false;               // the last value pushed was followed by ":"
var ignoring = false;
var inter: u8[2] = [0, 0];
var ni = 0;
var partial: u8[4] = [0, 0, 0, 0];   // a UTF-8 sequence cut off by the end of a chunk
var partial_len = 0;

fn reset_params() {
    ni = 0;
    ignoring = false;
    param = 0;
    pn = 0;
    open = false;
}

fn collect(b: u8) {
    if ni == 2 { ignoring = true; } else { inter[ni] = b; ni += 1; }
}

fn param_digit(b: u8) {
    if pn == MAXPARAMS { ignoring = true; return; }
    let v = param as u32 * 10 + (b - '0');
    param = if v > 65535 { 65535 } else { v as u16 };
}

fn push_param(sub: bool) {
    if pn == MAXPARAMS { ignoring = true; return; }
    pv[pn] = param;
    pstart[pn] = !open;
    open = sub;
    pn += 1;
    param = 0;
}

fn finish_params() {
    if pn == MAXPARAMS { ignoring = true; } else { push_param(false); }
}

// The end of the group starting at value g.
fn group_end(g: i64) -> i64 {
    var e = g + 1;
    while e < pn && !pstart[e] { e += 1; }
    return e;
}

var pg = 0;                     // csi_dispatch's walk over the groups

fn next_or(d: i64) -> i64 {
    guard pg < pn else { return d; }
    let v = pv[pg] as i64;
    pg = group_end(pg);
    return if v == 0 { d } else { v };
}

fn execute(b: u8) {
    match b {
        0x09 => put_tab(),
        0x08 => backspace(),
        0x0D => carriage_return(),
        0x0A, 0x0B, 0x0C => linefeed(),
        0x0E => { active_g = 1; },
        0x0F => { active_g = 0; },
        _ => {},
    }
}

fn configure_charset(cs: u8) {
    guard ni == 1;
    match inter[0] {
        '(' => { cur.g[0] = cs; },
        ')' => { cur.g[1] = cs; },
        '*' => { cur.g[2] = cs; },
        '+' => { cur.g[3] = cs; },
        _ => {},
    }
}

fn esc_dispatch(b: u8) {
    if b == 'B' { configure_charset(CS_ASCII); return; }
    if b == '0' { configure_charset(CS_DEC); return; }
    if b == '8' && ni == 1 && inter[0] == '#' { decaln(); return; }
    guard ni == 0;
    match b {
        'D' => linefeed(),
        'E' => { linefeed(); carriage_return(); },
        'H' => { tabs[cur.x] = true; },
        'M' => reverse_index(),
        'c' => reset_state(),
        '7' => save_cursor(),
        '8' => restore_cursor(),
        _ => {},
    }
}

// --- SGR ---------------------------------------------------------------------------------------

// vte's parse_sgr_color over the values vals[k..]: 2;r;g;b or 5;n.
// Returns the color, whether there was one, and how many values it read.
fn sgr_color(vals: const u16[:]) -> u32, bool, i64 {
    guard vals.len > 0 else { return 0, false, 0; }
    if vals[0] == 2 {
        var rgb: u32 = 0;
        for k in 1..4 {
            guard k < vals.len else { return 0, false, k; }
            guard vals[k] <= 255 else { return 0, false, k + 1; }
            rgb = rgb << 8 | vals[k];
        }
        return C_RGB | rgb, true, 4;
    }
    if vals[0] == 5 {
        guard vals.len > 1 else { return 0, false, 1; }
        guard vals[1] <= 255 else { return 0, false, 2; }
        return C_INDEXED | (vals[1] as u32), true, 2;
    }
    return 0, false, 1;
}

fn set_ul(kind: u16) { cur.pen.flags = (cur.pen.flags & ~A_UL_MASK) | kind << A_UL_SHIFT; }

fn sgr() {
    var g = 0;
    while g < pn {
        let e = group_end(g);
        let v: u32 = pv[g];
        var next = e;
        if e - g == 1 {
            match v {
                0 => { cur.pen = default<Style>(); },
                1 => { cur.pen.flags |= A_BOLD; },
                2 => { cur.pen.flags |= A_DIM; },
                3 => { cur.pen.flags |= A_ITALIC; },
                4 => set_ul(1),
                7 => { cur.pen.flags |= A_INVERSE; },
                8 => { cur.pen.flags |= A_HIDDEN; },
                9 => { cur.pen.flags |= A_STRIKE; },
                21 => { cur.pen.flags &= ~A_BOLD; },
                22 => { cur.pen.flags &= ~(A_BOLD | A_DIM); },
                23 => { cur.pen.flags &= ~A_ITALIC; },
                24 => set_ul(0),
                27 => { cur.pen.flags &= ~A_INVERSE; },
                28 => { cur.pen.flags &= ~A_HIDDEN; },
                29 => { cur.pen.flags &= ~A_STRIKE; },
                30..38 => { cur.pen.fg = C_INDEXED | (v - 30); },
                39 => { cur.pen.fg = 0; },
                40..48 => { cur.pen.bg = C_INDEXED | (v - 40); },
                49 => { cur.pen.bg = 0; },
                59 => { cur.pen.ul = 0; },
                90..98 => { cur.pen.fg = C_INDEXED | (v - 90 + 8); },
                100..108 => { cur.pen.bg = C_INDEXED | (v - 100 + 8); },
                38, 48, 58 => {
                    // The color's values are the first value of each following group.
                    var firsts: u16[..5] = [];
                    var h = e;
                    while h < pn && firsts.len < 5 { firsts.push(pv[h]); h = group_end(h); }
                    let c, ok, used = sgr_color(firsts);
                    for k in used { next = group_end(next); }
                    if ok {
                        if v == 38 { cur.pen.fg = c; } else if v == 48 { cur.pen.bg = c; } else { cur.pen.ul = c; }
                    }
                },
                _ => {},
            }
        } else if v == 4 {
            let k = if e - g == 2 { pv[g + 1] } else { 1 };
            match k {
                0 => set_ul(0),
                2 => set_ul(2),
                3 => set_ul(3),
                4 => set_ul(4),
                5 => set_ul(5),
                _ => set_ul(1),
            }
        } else if v == 38 || v == 48 || v == 58 {
            // Colon form: 38:5:n, 38:2:r:g:b or 38:2:colorspace:r:g:b.
            let sub = pv[g + 1..e];
            var vals: u16[..4] = [];
            vals.push(sub[0]);
            let from = if sub.len > 4 { 2 } else { 1 };
            for k in from..min(sub.len, from + 3) { vals.push(sub[k]); }
            let c, ok, used = sgr_color(vals);
            if ok {
                if v == 38 { cur.pen.fg = c; } else if v == 48 { cur.pen.bg = c; } else { cur.pen.ul = c; }
            }
        }
        g = next;
    }
    pen_changed();
}

// --- CSI ---------------------------------------------------------------------------------------

fn csi_dispatch(b: u8) {
    guard !ignoring && ni <= 2;
    pg = 0;
    let i0: u8 = if ni > 0 { inter[0] } else { 0 };
    if ni == 0 {
        match b {
            '@' => insert_blank(next_or(1)),
            'A' => goto(cur.y - next_or(1), cur.x),
            'B', 'e' => goto(cur.y + next_or(1), cur.x),
            'b' => {
                if has_preceding {
                    let n = next_or(1);
                    for k in n { input(preceding); }
                }
            },
            'C', 'a' => { cur.x = min(cur.x + next_or(1), cols - 1); cur.wrap = false; },
            'D' => { cur.x = max(cur.x - next_or(1), 0); cur.wrap = false; },
            'd' => goto(next_or(1) - 1, cur.x),
            'E' => goto(cur.y + next_or(1), 0),
            'F' => goto(cur.y - next_or(1), 0),
            'G', '`' => goto(cur.y, next_or(1) - 1),
            'g' => {
                let m = next_or(0);
                if m == 0 { tabs[cur.x] = false; } else if m == 3 { fill(tabs, false); }
            },
            'H', 'f' => { let y = next_or(1); let x = next_or(1); goto(y - 1, x - 1); },
            'h' => { for k in pn { if pstart[k] { set_mode(pv[k], true); } } },
            'l' => { for k in pn { if pstart[k] { set_mode(pv[k], false); } } },
            'I' => forward_tabs(next_or(1)),
            'J' => erase_display(next_or(0)),
            'K' => erase_line(next_or(0)),
            'L' => insert_lines(next_or(1)),
            'M' => delete_lines(next_or(1)),
            'm' => sgr(),
            'P' => delete_chars(next_or(1)),
            'r' => {
                let t = next_or(1);
                var bm = 0;
                if pg < pn { bm = pv[pg]; }
                set_region(t, bm);
            },
            'S' => scroll_up(top, next_or(1)),
            's' => save_cursor(),
            'T' => scroll_down(top, next_or(1)),
            'u' => restore_cursor(),
            'X' => erase_chars(next_or(1)),
            'Z' => backward_tabs(next_or(1)),
            _ => {},
        }
        return;
    }
    if ni == 1 && i0 == '?' {
        match b {
            'h' => { for k in pn { if pstart[k] { set_private_mode(pv[k], true); } } },
            'l' => { for k in pn { if pstart[k] { set_private_mode(pv[k], false); } } },
            'W' => { if next_or(0) == 5 { default_tabs(); } },
            _ => {},
        }
        return;
    }
    if ni == 1 && i0 == ' ' && b == 'q' {
        let s = next_or(0);
        if s <= 6 { cursor_shape = s; }
    }
}

// --- feeding bytes ---------------------------------------------------------------------------

// One byte in any state but GROUND (vte's change_state).
fn step(b: u8) {
    match state {
        ESCAPE => {
            if b < 0x20 {
                if b == 0x18 || b == 0x1A { execute(b); state = GROUND; }
                else if b != 0x1B { execute(b); }
            } else if b <= 0x2F { collect(b); state = ESC_INT; }
            else if b == 0x50 { reset_params(); state = DCS_ENTRY; }
            else if b == 0x58 || b == 0x5E || b == 0x5F { state = SOS; }
            else if b == 0x5B { reset_params(); state = CSI_ENTRY; }
            else if b == 0x5D { state = OSC; }
            else if b <= 0x7E { esc_dispatch(b); state = GROUND; }
        },
        ESC_INT => {
            if b < 0x20 { c0_in_seq(b); }
            else if b <= 0x2F { collect(b); }
            else if b <= 0x7E { esc_dispatch(b); state = GROUND; }
            else if b != 0x7F { anywhere(b); }
        },
        CSI_ENTRY => {
            if b < 0x20 { c0_in_seq(b); }
            else if b <= 0x2F { collect(b); state = CSI_INT; }
            else if b <= 0x39 { param_digit(b); state = CSI_PARAM; }
            else if b == 0x3A { push_param(true); state = CSI_PARAM; }
            else if b == 0x3B { push_param(false); state = CSI_PARAM; }
            else if b <= 0x3F { collect(b); state = CSI_PARAM; }
            else if b <= 0x7E { finish_params(); csi_dispatch(b); state = GROUND; }
            else { anywhere(b); }
        },
        CSI_PARAM => {
            if b < 0x20 { c0_in_seq(b); }
            else if b <= 0x2F { collect(b); state = CSI_INT; }
            else if b <= 0x39 { param_digit(b); }
            else if b == 0x3A { push_param(true); }
            else if b == 0x3B { push_param(false); }
            else if b <= 0x3F { state = CSI_IGNORE; }
            else if b <= 0x7E { finish_params(); csi_dispatch(b); state = GROUND; }
            else if b != 0x7F { anywhere(b); }
        },
        CSI_INT => {
            if b < 0x20 { c0_in_seq(b); }
            else if b <= 0x2F { collect(b); }
            else if b <= 0x3F { state = CSI_IGNORE; }
            else if b <= 0x7E { finish_params(); csi_dispatch(b); state = GROUND; }
            else { anywhere(b); }
        },
        CSI_IGNORE => {
            if b < 0x20 { c0_in_seq(b); }
            else if b <= 0x3F {}
            else if b <= 0x7E { state = GROUND; }
            else if b != 0x7F { anywhere(b); }
        },
        DCS_ENTRY => {
            if b < 0x20 { dcs_c0(b); }
            else if b <= 0x2F { collect(b); state = DCS_INT; }
            else if b <= 0x39 { param_digit(b); state = DCS_PARAM; }
            else if b == 0x3A { push_param(true); state = DCS_PARAM; }
            else if b == 0x3B { push_param(false); state = DCS_PARAM; }
            else if b <= 0x3F { collect(b); state = DCS_PARAM; }
            else if b <= 0x7E { state = DCS_PASS; }
            else if b != 0x7F { anywhere(b); }
        },
        DCS_PARAM => {
            if b < 0x20 { dcs_c0(b); }
            else if b <= 0x2F { collect(b); state = DCS_INT; }
            else if b <= 0x39 { param_digit(b); }
            else if b == 0x3A { push_param(true); }
            else if b == 0x3B { push_param(false); }
            else if b <= 0x3F { state = DCS_IGNORE; }
            else if b <= 0x7E { state = DCS_PASS; }
            else if b != 0x7F { anywhere(b); }
        },
        DCS_INT => {
            if b < 0x20 { dcs_c0(b); }
            else if b <= 0x2F { collect(b); }
            else if b <= 0x3F { state = DCS_IGNORE; }
            else if b <= 0x7E { state = DCS_PASS; }
            else if b != 0x7F { anywhere(b); }
        },
        DCS_PASS => {
            if b == 0x18 || b == 0x1A { execute(b); state = GROUND; }
            else if b == 0x1B { reset_params(); state = ESCAPE; }
            else if b == 0x9C { state = GROUND; }
        },
        OSC => {
            if b == 0x07 { state = GROUND; }
            else if b == 0x18 || b == 0x1A { execute(b); state = GROUND; }
            else if b == 0x1B { reset_params(); state = ESCAPE; }
        },
        _ => anywhere(b),          // DCS_IGNORE, SOS
    }
}

// A C0 control inside an escape or control sequence: executed, except the
// three that end it (vte: 0x18 and 0x1A cancel, 0x1B starts a new escape).
fn c0_in_seq(b: u8) {
    if b == 0x18 || b == 0x1A || b == 0x1B { anywhere(b); } else { execute(b); }
}

// In DCS headers C0 controls are ignored, but the three still end it.
fn dcs_c0(b: u8) {
    if b == 0x18 || b == 0x1A || b == 0x1B { anywhere(b); }
}

fn anywhere(b: u8) {
    if b == 0x18 || b == 0x1A { execute(b); state = GROUND; }
    else if b == 0x1B { reset_params(); state = ESCAPE; }
}

// UTF-8 as Rust's str::from_utf8 sees it at s[i..]: a code point and its
// length (kind 0), an invalid sequence and the length to skip (kind 1), or a
// sequence the end of s cuts short (kind 2).
fn utf8_at(s: const u8[:], i: i64) -> u32, i64, i64 {
    let b0 = s[i];
    var need = 0;
    var lo: u8 = 0x80;
    var hi: u8 = 0xBF;
    var cp: u32 = 0;
    if b0 >= 0xC2 && b0 <= 0xDF { need = 1; cp = b0 & 0x1F; }
    else if b0 >= 0xE0 && b0 <= 0xEF {
        need = 2;
        cp = b0 & 0x0F;
        if b0 == 0xE0 { lo = 0xA0; } else if b0 == 0xED { hi = 0x9F; }
    } else if b0 >= 0xF0 && b0 <= 0xF4 {
        need = 3;
        cp = b0 & 0x07;
        if b0 == 0xF0 { lo = 0x90; } else if b0 == 0xF4 { hi = 0x8F; }
    } else {
        return 0, 1, 1;
    }
    for k in 1..need + 1 {
        guard i + k < s.len else { return 0, k, 2; }
        let c = s[i + k];
        guard c >= lo && c <= hi else { return 0, k, 1; }
        cp = cp << 6 | (c & 0x3F);
        lo = 0x80;
        hi = 0xBF;
    }
    return cp, need + 1, 0;
}

// A decoded character from the ground state: C1 controls are executed
// (alacritty does nothing for them), everything else is printed.
fn ground_char(cp: u32) {
    if cp >= 0x80 && cp <= 0x9F { return; }
    put_char(cp);
}

let TEXT_STOP = byte_set_of_controls();
let ESC_SET = byte_set("\x1b");

fn byte_set_of_controls() -> ByteSet {
    var m: bool[256] = [true; 256];
    for b in 0x20..0x7F { m[b] = false; }
    return byte_set(m);
}

// Bytes in the ground state up to (not including) the next ESC. `cut` says
// the segment ends at the end of the chunk rather than at an ESC.
fn ground(s: const u8[:], cut: bool) {
    var j = 0;
    while j < s.len {
        let k = find_any(s[j..], TEXT_STOP);
        if k < 0 { print_ascii(s[j..]); return; }
        if k > 0 { print_ascii(s[j..j + k]); j += k; }
        let b = s[j];
        if b < 0x80 {
            if b == 0x7F { preceding = b; has_preceding = true; } else { execute(b); }
            j += 1;
            continue;
        }
        let cp, n, kind = utf8_at(s, j);
        if kind == 0 { ground_char(cp); j += n; continue; }
        if kind == 1 {
            if !(n == 1 && b <= 0x9F) { put_char(0xFFFD); }
            j += n;
            continue;
        }
        // Cut short.
        if !cut { put_char(0xFFFD); return; }
        for q in s.len - j { partial[q] = s[j + q]; }
        partial_len = s.len - j;
        return;
    }
}

// vte's advance_partial_utf8, including its habit of consuming, unprinted,
// the valid characters after the first when the 4-byte window ends in an
// incomplete one. Returns the bytes of `data` it used.
fn finish_partial(data: const u8[:]) -> i64 {
    let old = partial_len;
    let take = min(data.len, 4 - old);
    for q in take { partial[old + q] = data[q]; }
    partial_len = old + take;
    let buf = partial[..partial_len];
    // Validate the buffer as from_utf8 would: the first error, if any.
    var i = 0;
    var first_cp: u32 = 0;
    var first_len = 0;
    var err_kind = 0;
    var err_len = 0;
    while i < buf.len {
        if buf[i] < 0x80 {
            if first_len == 0 { first_cp = buf[i]; first_len = 1; }
            i += 1;
            continue;
        }
        let cp, n, kind = utf8_at(buf, i);
        if kind != 0 { err_kind = kind; err_len = n; break; }
        if first_len == 0 { first_cp = cp; first_len = n; }
        i += n;
    }
    if err_kind == 0 {
        put_char(first_cp);
        partial_len = 0;
        return first_len - old;
    }
    if i > 0 {
        put_char(first_cp);
        partial_len = 0;
        return i - old;
    }
    if err_kind == 1 {
        put_char(0xFFFD);
        partial_len = 0;
        return err_len - old;
    }
    return take;
}

fn feed(data: const u8[:]) {
    var i = 0;
    if partial_len != 0 { i += finish_partial(data); }
    let n = data.len;
    while i < n {
        if state == GROUND {
            let rest = data[i..];
            let e = find_any(rest, ESC_SET);
            if e < 0 { ground(rest, true); return; }
            if e > 0 { ground(rest[..e], false); }
            reset_params();
            state = ESCAPE;
            i += e + 1;
        } else {
            step(data[i]);
            i += 1;
        }
    }
}
