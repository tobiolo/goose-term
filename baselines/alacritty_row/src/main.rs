// The alacritty_terminal row: feed a recorded byte stream to alacritty's
// terminal core (vte parser + Term grid), then print the canonical dump that
// every row prints (tests/DUMP.md).
//
//   alacritty_row <input> [--cols N] [--rows N] [--history N] [--chunk N] [--dump FILE]
//   alacritty_row --width-table FILE    widths of every code point, for core/width.bin

use std::io::Write;
use std::time::Instant;

use alacritty_terminal::event::VoidListener;
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::{Cell, Flags};
use alacritty_terminal::term::{Config, Term};
use alacritty_terminal::vte::ansi::{Color, NamedColor, Processor};
use unicode_width::UnicodeWidthChar;

struct Size {
    cols: usize,
    rows: usize,
}

impl Dimensions for Size {
    fn total_lines(&self) -> usize {
        self.rows
    }
    fn screen_lines(&self) -> usize {
        self.rows
    }
    fn columns(&self) -> usize {
        self.cols
    }
}

struct Fnv(u64);

impl Fnv {
    fn new() -> Self {
        Fnv(14695981039346656037)
    }
    fn bytes(&mut self, b: &[u8]) {
        for &c in b {
            self.0 = (self.0 ^ c as u64).wrapping_mul(1099511628211);
        }
    }
}

fn color(out: &mut String, c: Color) {
    use std::fmt::Write;
    match c {
        Color::Named(n) => {
            let i = n as usize;
            if i < 16 {
                write!(out, "i{}", i).unwrap();
            } else if n == NamedColor::Foreground || n == NamedColor::Background {
                out.push('d');
            } else {
                // Dim and bright variants of the defaults: alacritty's own renderer colors.
                write!(out, "n{}", i).unwrap();
            }
        }
        Color::Indexed(i) => write!(out, "i{}", i).unwrap(),
        Color::Spec(rgb) => write!(out, "#{:02x}{:02x}{:02x}", rgb.r, rgb.g, rgb.b).unwrap(),
    }
}

fn is_spacer(c: &Cell) -> bool {
    c.flags.intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
}

fn attr(out: &mut String, c: &Cell) {
    use std::fmt::Write;
    let blank = c.c == ' ' || c.c == '\t' || c.c == '\0' || is_spacer(c);
    if blank {
        out.push('d');
    } else {
        color(out, c.fg);
    }
    out.push('/');
    color(out, c.bg);
    let f = c.flags;
    let mut bits = 0;
    if f.contains(Flags::BOLD) { bits |= 1; }
    if f.contains(Flags::DIM) { bits |= 2; }
    if f.contains(Flags::ITALIC) { bits |= 4; }
    if f.intersects(Flags::ALL_UNDERLINES) { bits |= 8; }
    if f.contains(Flags::INVERSE) { bits |= 16; }
    if f.contains(Flags::HIDDEN) { bits |= 32; }
    if f.contains(Flags::STRIKEOUT) { bits |= 64; }
    write!(out, "/{}", bits).unwrap();
}

// One row as its text line and its attribute line (tests/DUMP.md).
fn row_lines(term: &Term<VoidListener>, line: Line, text: &mut String, attrs: &mut String) {
    use std::fmt::Write;
    let row = &term.grid()[line];
    let cols = term.columns();
    text.clear();
    attrs.clear();
    for x in 0..cols {
        let c = &row[Column(x)];
        if is_spacer(c) {
            continue;
        }
        // A tab leaves '\t' in the cell it passed; the dump shows it as the blank it is.
        text.push(if c.c == '\0' || c.c == '\t' { ' ' } else { c.c });
        if let Some(zw) = c.zerowidth() {
            text.extend(zw.iter());
        }
    }
    let trimmed = text.trim_end_matches(' ').len();
    text.truncate(trimmed);
    let mut prev = String::new();
    let mut cur = String::new();
    let mut run = 0;
    for x in 0..cols {
        cur.clear();
        attr(&mut cur, &row[Column(x)]);
        if run > 0 && cur != prev {
            write!(attrs, "{}*{},", run, prev).unwrap();
            run = 0;
        }
        if run == 0 {
            std::mem::swap(&mut prev, &mut cur);
        }
        run += 1;
    }
    write!(attrs, "{}*{},", run, prev).unwrap();
}

fn width_table(path: &str) {
    let mut out = Vec::with_capacity(0x110000);
    for cp in 0..0x110000u32 {
        let w = match char::from_u32(cp) {
            None => 1, // surrogates: the decoder never yields them
            Some(c) => match c.width() {
                None => 3, // a control: dropped
                Some(w) => w as u8,
            },
        };
        out.push(w);
    }
    std::fs::write(path, out).expect("write width table");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() == 3 && args[1] == "--width-table" {
        width_table(&args[2]);
        return;
    }
    let (mut cols, mut rows, mut history, mut chunk) = (174usize, 39usize, 10000usize, 65536usize);
    let mut dump: Option<String> = None;
    let mut input: Option<String> = None;
    let mut i = 1;
    while i < args.len() {
        let a = args[i].as_str();
        let mut num = || {
            i += 1;
            args[i].parse::<usize>().expect("number")
        };
        match a {
            "--cols" => cols = num(),
            "--rows" => rows = num(),
            "--history" => history = num(),
            "--chunk" => chunk = num(),
            "--dump" => {
                i += 1;
                dump = Some(args[i].clone());
            }
            _ => input = Some(a.to_string()),
        }
        i += 1;
    }
    let input = input.expect("usage: alacritty_row <input> [--cols N] [--rows N] [--history N] [--chunk N] [--dump FILE]");

    let t0 = Instant::now();
    let data = std::fs::read(&input).expect("read input");
    let t1 = Instant::now();

    let config = Config { scrolling_history: history, ..Config::default() };
    let mut term = Term::new(config, &Size { cols, rows }, VoidListener);
    let mut parser: Processor = Processor::new();
    for piece in data.chunks(chunk) {
        parser.advance(&mut term, piece);
    }
    // vte holds back the bytes of a synchronized update (?2026h) until it ends;
    // at the end of the input, apply what it still holds.
    parser.stop_sync(&mut term);
    let t2 = Instant::now();

    let grid = term.grid();
    let hist = grid.history_size();
    let mut text = String::new();
    let mut attrs = String::new();
    let (mut ht, mut ha, mut st, mut sa) = (Fnv::new(), Fnv::new(), Fnv::new(), Fnv::new());
    let mut full: Vec<u8> = Vec::new();
    for k in (1..=hist).rev() {
        row_lines(&term, Line(-(k as i32)), &mut text, &mut attrs);
        ht.bytes(text.as_bytes());
        ht.bytes(b"\n");
        ha.bytes(attrs.as_bytes());
        ha.bytes(b"\n");
        if dump.is_some() {
            writeln!(full, "H {}\n  {}", text, attrs).unwrap();
        }
    }
    for y in 0..rows {
        row_lines(&term, Line(y as i32), &mut text, &mut attrs);
        st.bytes(text.as_bytes());
        st.bytes(b"\n");
        sa.bytes(attrs.as_bytes());
        sa.bytes(b"\n");
        if dump.is_some() {
            writeln!(full, "S {}\n  {}", text, attrs).unwrap();
        }
    }
    if let Some(p) = dump {
        std::fs::write(p, full).expect("write dump");
    }
    let cur = grid.cursor.point;
    let t3 = Instant::now();
    drop(term);
    let t4 = Instant::now();
    let ms = |a: Instant, b: Instant| (b - a).as_secs_f64() * 1e3;
    eprintln!(
        "phases_ms read {:.1} feed {:.1} dump {:.1} teardown {:.1}",
        ms(t0, t1), ms(t1, t2), ms(t2, t3), ms(t3, t4)
    );
    println!("bytes {}", data.len());
    println!("size {} {}", rows, cols);
    println!("cursor {} {}", cur.line.0, cur.column.0);
    println!("history {}", hist);
    println!("history_text {}", ht.0);
    println!("history_attr {}", ha.0);
    println!("screen_text {}", st.0);
    println!("screen_attr {}", sa.0);
}
