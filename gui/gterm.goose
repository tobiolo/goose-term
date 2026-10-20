// gterm: a terminal window around the goose-term core.
//
// A shell runs on a pty (gui/pty.c); what it writes goes through vt::feed,
// and every frame draws the screen, or the scrollback above it, as one
// instanced quad per cell: the cell's background, and the glyph from a font
// atlas that ui bakes, blended over it in the fragment shader. Keys, typed
// text, the mouse wheel and paste go back to the shell as xterm would send
// them.
//
//   gterm [--font FILE.ttf] [--bold FILE.ttf] [--size PX] [--shell PATH] [--exec COMMAND]
//         [--cols N] [--rows N] [--history N]
//         [--type TEXT] [--keys K,K,...] [--seconds N] [--shot FILE.png]
//
// --exec runs `/bin/sh -c COMMAND` instead of the shell, and the window
// closes when it ends.
//
// For tests: --type types TEXT and Enter into the window once the shell has
// been quiet for half a second, --keys then presses keys by SDL's names
// with Ctrl+, Shift+ and Alt+ prefixes ("Up,Ctrl+C,Shift+Tab"), --seconds
// quits that long after, and --shot saves the last frame. A run with GOOSE_GFX_HEADLESS=1 needs no display.
//
// Keys of its own: Shift+PageUp/PageDown/Home/End scroll the scrollback,
// Ctrl+Shift+C copies the selection (drag with the left button),
// Ctrl+Shift+V and Shift+Insert paste, Ctrl+= Ctrl+- Ctrl+0 change the
// font size.

import std;
import os;
import math;
import dictionary;
import gfx from "github.com/aardappel/goose_gfx@6cfa3dec2ef2a6cb19ee71548b38151094e947bd";
import gfx.ui;
import vt from "../core";
import box;

extern "gt_pty_spawn" fn pty_spawn(shell: const u8[:], command: const u8[:], cols: i64, rows: i64) -> i64;
extern "gt_pty_read" fn pty_read(fd: i64, buf: u8[:]) -> i64;
extern "gt_pty_write" fn pty_write(fd: i64, buf: const u8[:]) -> i64;
extern "gt_pty_resize" fn pty_resize(fd: i64, cols: i64, rows: i64, px_w: i64, px_h: i64);
extern "gt_pty_alive" fn pty_alive() -> i32;
extern "gt_pty_close" fn pty_close(fd: i64);
extern "gt_pty_wait" fn pty_wait(fd: i64, ms: i64) -> i32;

// --- colors -------------------------------------------------------------------------------

// Alacritty's default colors.
let DEFAULT_FG: u32 = 0xD8D8D8;
let DEFAULT_BG: u32 = 0x181818;
let CURSOR: u32 = 0xD8D8D8;
let SELECTION: u32 = 0x44475A;
let ANSI: u32[16] = [0x181818, 0xAC4242, 0x90A959, 0xF4BF75, 0x6A9FB5, 0xAA759F, 0x75B5AA, 0xD8D8D8,
                     0x6B6B6B, 0xC55555, 0xAAC474, 0xFECA88, 0x82B8C8, 0xC28CB8, 0x93D3C3, 0xF8F8F8];

var palette: u32[256] = [0; 256];

fn init_palette() {
    for i in 16 { palette[i] = ANSI[i]; }
    let levels: u32[6] = [0, 95, 135, 175, 215, 255];
    for i in 216 {
        palette[16 + i] = levels[i / 36] << 16 | levels[i / 6 % 6] << 8 | levels[i % 6];
    }
    for i in 24 {
        let v: u32 = 8 + 10 * i as u32;
        palette[232 + i] = v << 16 | v << 8 | v;
    }
}

fn resolve(c: u32, dflt: u32) -> u32 {
    if c == 0 { return dflt; }
    if c & vt::C_RGB != 0 { return c & 0xFFFFFF; }
    return palette[c & 255];
}

fn rgba(c: u32) -> u8[4] { [(c >> 16 & 255) as u8, (c >> 8 & 255) as u8, (c & 255) as u8, 255] }

fn dim(c: u32) -> u32 {
    let r = (c >> 16 & 255) * 2 / 3;
    let g = (c >> 8 & 255) * 2 / 3;
    let b = (c & 255) * 2 / 3;
    return r << 16 | g << 8 | b;
}

// --- the font ----------------------------------------------------------------------------

// What the atlas bakes: Latin, punctuation, arrows, math, technical, box
// drawing, blocks, shapes, dingbats, braille and Powerline's symbols.
let RANGES: u32[24] = [0x20, 0x7E, 0xA0, 0x17F, 0x2010, 0x205E, 0x2190, 0x21FF, 0x2200, 0x23FF,
                       0x2500, 0x25FF, 0x2600, 0x26FF, 0x2700, 0x27BF, 0x2800, 0x28FF,
                       0xE0A0, 0xE0B3, 0x3B1, 0x3C9, 0x391, 0x3A9];

let FONTS: const u8[:][6] = [
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf", "/usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
    "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/liberation/LiberationMono-Bold.ttf"];

// A glyph placed in its cell: the pixel rectangle relative to the cell's
// top left, and where it is in the atlas.
struct Glyph { rect: float4, uv: float4 }

var atlas = ui::FontAtlas { 0 };
var regular = ui::Font { 0 };
var bold = ui::Font { 0 };
var atlas_size = int2_0;
var atlas_tex = gfx::Texture { 0 };
var cell_w: f32 = 8.0;
var cell_h: f32 = 16.0;
var glyph_top: f32 = 0.0;      // where the font's line starts in the cell
var underline_y: f32 = 14.0;
var line_w: f32 = 1.0;
var glyphs = dictionary<u32, Glyph> {};

fn load_font(regular_path: const u8[:], bold_path: const u8[:], px: f32) -> bool {
    if atlas.id != 0 {
        ui::destroy(atlas);
        if atlas_tex.id != 0 { gfx::release(atlas_tex); atlas_tex = gfx::Texture { 0 }; }
        glyphs.clear();
    }
    atlas = ui::create_font_atlas();
    let cfg = ui::FontConfig { oversample_h: 1, oversample_v: 1, pixel_snap: true };
    regular = ui::add_font_from_file(atlas, regular_path, px, cfg, RANGES);
    guard regular.id != 0 else { return false; }
    bold = regular;
    if bold_path.len > 0 && file_exists(bold_path) {
        let b = ui::add_font_from_file(atlas, bold_path, px, cfg, RANGES);
        if b.id != 0 { bold = b; }
    }
    guard ui::bake(atlas) else { return false; }
    atlas_size = ui::atlas_size(atlas);
    // Before the window opens there is no device yet: main uploads it then.
    if gfx::open_count() > 0 { upload_atlas(); }
    let info = ui::info(regular);
    let m, _ = ui::find_glyph(regular, 'M');
    cell_w = round(m.xadvance);
    let line = ceil(info.ascent - info.descent);
    cell_h = max(line, ceil(info.height));
    glyph_top = floor((cell_h - line) / 2.0);
    underline_y = min(glyph_top + round(info.ascent) + max(1.0, round(px / 12.0)), cell_h - 1.0);
    line_w = max(1.0, round(px / 14.0));
    return true;
}

fn upload_atlas() {
    atlas_tex = gfx::texture2d(atlas_size.x, atlas_size.y);
    gfx::update_texture(atlas_tex, ui::atlas_pixels(atlas));
}

// Whole pixels, the size of the glyph's image, so it samples texel for texel.
fn place(g: ui::FontGlyph) -> Glyph {
    let w = round((g.u1 - g.u0) * atlas_size.x);
    let h = round((g.v1 - g.v0) * atlas_size.y);
    let x = round(g.x0);
    let y = round(g.y0) + glyph_top;
    return Glyph { rect: float4 { x, y, x + w, y + h }, uv: float4 { g.u0, g.v0, g.u1, g.v1 } };
}

fn glyph(cp: u32, is_bold: bool) -> Glyph {
    let key = cp | (if is_bold { 0x80000000 } else { 0 });
    let have = glyphs.get(key);
    if have { return have; }
    let f = if is_bold { bold } else { regular };
    var g, own = ui::find_glyph(f, cp);
    // A character the atlas lacks is drawn as its '?'.
    if !own { g, own = ui::find_glyph(f, '?'); }
    let out = place(g);
    glyphs.insert(key, out);
    return out;
}

// --- drawing ---------------------------------------------------------------------------------

// One quad: a background rectangle, and a glyph over it (rect empty for none).
struct Inst { pos: float2, size: float2, rect: float4, uv: float4, fg: u8[4], bg: u8[4] }
struct Corner { p: float2 }
struct View { screen: float4 }

let VS = embed_shader("vert", """
    layout(location = 0) in vec2 a_corner;
    layout(location = 1) in vec2 i_pos;
    layout(location = 2) in vec2 i_size;
    layout(location = 3) in vec4 i_rect;
    layout(location = 4) in vec4 i_uv;
    layout(location = 5) in vec4 i_fg;
    layout(location = 6) in vec4 i_bg;
    layout(set = 1, binding = 0) uniform View { vec4 screen; };
    layout(location = 0) out vec2 v_px;
    layout(location = 1) flat out vec4 v_rect;
    layout(location = 2) flat out vec4 v_uv;
    layout(location = 3) flat out vec4 v_fg;
    layout(location = 4) flat out vec4 v_bg;
    void main() {
        vec2 local = a_corner * i_size;
        vec2 p = i_pos + local;
        v_px = local;
        v_rect = i_rect;
        v_uv = i_uv;
        v_fg = i_fg;
        v_bg = i_bg;
        gl_Position = vec4(p.x / screen.x * 2.0 - 1.0, 1.0 - p.y / screen.y * 2.0, 0.0, 1.0);
    }
    """);

let FS = embed_shader("frag", """
    layout(set = 2, binding = 0) uniform sampler2D atlas;
    layout(location = 0) in vec2 v_px;
    layout(location = 1) flat in vec4 v_rect;
    layout(location = 2) flat in vec4 v_uv;
    layout(location = 3) flat in vec4 v_fg;
    layout(location = 4) flat in vec4 v_bg;
    layout(location = 0) out vec4 result;
    void main() {
        float cov = 0.0;
        if (v_rect.z > v_rect.x && v_px.x >= v_rect.x && v_px.y >= v_rect.y &&
            v_px.x < v_rect.z && v_px.y < v_rect.w) {
            vec2 t = (v_px - v_rect.xy) / (v_rect.zw - v_rect.xy);
            cov = texture(atlas, mix(v_uv.xy, v_uv.zw, t)).a;
        }
        result = vec4(mix(v_bg.rgb, v_fg.rgb, cov), 1.0);
    }
    """);

var insts: Inst[>..] = [];
var margin: f32 = 4.0;

fn solid(x: f32, y: f32, w: f32, h: f32, c: u32) {
    let col = rgba(c);
    insts.push(Inst { pos: float2 { x, y }, size: float2 { w, h }, rect: float4_0, uv: float4_0,
                      fg: col, bg: col });
}

// Box drawing and block elements, drawn here rather than by the font, so
// that lines join from cell to cell and blocks fill them: true if cp is one.
fn draw_box(cp: u32, x: f32, y: f32, w: f32, fg: u32, bg: u32) -> bool {
    guard cp >= 0x2500 && cp < 0x25A0 else { return false; }
    let h = cell_h;
    if cp < 0x2580 {
        let a = box::ARMS[cp - 0x2500] as i64;
        guard a != 0 else { return false; }
        solid(x, y, w, h, bg);
        let up = a & 3;
        let right = a >> 2 & 3;
        let down = a >> 4 & 3;
        let left = a >> 6 & 3;
        let vmax = max(thickness(up), thickness(down));
        let hmax = max(thickness(left), thickness(right));
        // Each arm runs from the far side of the crossing line to the edge.
        let hx0 = x + floor((w - vmax) / 2.0);
        let hx1 = hx0 + vmax;
        let vy0 = y + floor((h - hmax) / 2.0);
        let vy1 = vy0 + hmax;
        if right != 0 { arm_h(right, hx0, x + w, y, fg); }
        if left != 0 { arm_h(left, x, hx1, y, fg); }
        if up != 0 { arm_v(up, y, vy1, x, w, fg); }
        if down != 0 { arm_v(down, vy0, y + h, x, w, fg); }
        return true;
    }
    let half_h = floor(h / 2.0);
    let half_w = floor(w / 2.0);
    if cp == 0x2580 { solid(x, y, w, h, bg); solid(x, y, w, half_h, fg); return true; }
    if cp <= 0x2588 {
        let k = round(h * (cp - 0x2580) / 8.0);
        solid(x, y, w, h, bg);
        solid(x, y + h - k, w, k, fg);
        return true;
    }
    if cp <= 0x258F {
        solid(x, y, w, h, bg);
        solid(x, y, round(w * (0x2590 - cp) / 8.0), h, fg);
        return true;
    }
    if cp == 0x2590 { solid(x, y, w, h, bg); solid(x + half_w, y, w - half_w, h, fg); return true; }
    if cp <= 0x2593 {
        solid(x, y, w, h, mix(bg, fg, cp - 0x2590));
        return true;
    }
    if cp == 0x2594 { solid(x, y, w, h, bg); solid(x, y, w, round(h / 8.0), fg); return true; }
    if cp == 0x2595 {
        let k = round(w / 8.0);
        solid(x, y, w, h, bg);
        solid(x + w - k, y, k, h, fg);
        return true;
    }
    // The quadrants: upper left 1, upper right 2, lower left 4, lower right 8.
    let QUADS: u8[10] = [4, 8, 1, 13, 9, 7, 11, 2, 6, 14];
    let q = QUADS[cp - 0x2596];
    solid(x, y, w, h, bg);
    if q & 1 != 0 { solid(x, y, half_w, half_h, fg); }
    if q & 2 != 0 { solid(x + half_w, y, w - half_w, half_h, fg); }
    if q & 4 != 0 { solid(x, y + half_h, half_w, h - half_h, fg); }
    if q & 8 != 0 { solid(x + half_w, y + half_h, w - half_w, h - half_h, fg); }
    return true;
}

// How wide a line of weight k is: light, heavy, or the span of a double.
fn thickness(k: i64) -> f32 {
    if k == 1 { return line_w; }
    if k == 2 { return max(2.0 * line_w, line_w + 1.0); }
    if k == 3 { return 3.0 * line_w; }
    return 0.0;
}

fn arm_h(k: i64, x0: f32, x1: f32, y: f32, c: u32) {
    let t = thickness(k);
    let y0 = y + floor((cell_h - t) / 2.0);
    if k == 3 {
        solid(x0, y0, x1 - x0, line_w, c);
        solid(x0, y0 + 2.0 * line_w, x1 - x0, line_w, c);
    } else {
        solid(x0, y0, x1 - x0, t, c);
    }
}

fn arm_v(k: i64, y0: f32, y1: f32, x: f32, w: f32, c: u32) {
    let t = thickness(k);
    let x0 = x + floor((w - t) / 2.0);
    if k == 3 {
        solid(x0, y0, line_w, y1 - y0, c);
        solid(x0 + 2.0 * line_w, y0, line_w, y1 - y0, c);
    } else {
        solid(x0, y0, t, y1 - y0, c);
    }
}

// a, b mixed in quarters: k of 4 parts b.
fn mix(a: u32, b: u32, k: u32) -> u32 {
    var out: u32 = 0;
    for sh in [16, 8, 0] {
        let ca = a >> sh & 255;
        let cb = b >> sh & 255;
        out |= (ca * (4 - k) + cb * k) / 4 << sh;
    }
    return out;
}

// --- the view ----------------------------------------------------------------------------

var offset = 0;                 // scrollback lines shown above the screen
var sel_on = false;             // a selection, from (sel_y0, sel_x0) to (sel_y1, sel_x1) in view cells
var sel_y0 = 0;
var sel_x0 = 0;
var sel_y1 = 0;
var sel_x1 = 0;
var selecting = false;

let NO_CELLS: vt::Cell[1] = [vt::Cell { cp: 0, style: 0 }];

// The cells of view row y: a scrollback line or a screen row.
fn view_row(y: i64) -> const vt::Cell[:] {
    if !vt::alt() && y < offset {
        let k = vt::hist_len - offset + y;
        if k >= 0 { return vt::history_line(k); }
        return NO_CELLS[0..0];
    }
    return vt::peek(y - offset);
}

fn selected(y: i64, x: i64) -> bool {
    guard sel_on else { return false; }
    var ay = sel_y0;
    var ax = sel_x0;
    var by = sel_y1;
    var bx = sel_x1;
    if by < ay || (by == ay && bx < ax) { swap(ay, by); swap(ax, bx); }
    if y < ay || y > by { return false; }
    if y == ay && x < ax { return false; }
    if y == by && x > bx { return false; }
    return true;
}

fn build(focused: bool) {
    insts.clear();
    let rows = vt::nrows;
    let cols = vt::cols;
    for y in rows {
        let r = view_row(y);
        let py = margin + y * cell_h;
        var x = 0;
        while x < cols {
            var c = vt::Cell { cp: 0, style: 0 };
            if x < r.len { c = r[x]; }
            x += 1;
            if c.cp & vt::F_SPACER != 0 { continue; }
            let st = vt::styles[c.style];
            var cp = c.cp & vt::CP_MASK;
            if c.cp & vt::F_MARKS != 0 { cp = vt::marks[cp].base; }
            if c.cp & vt::F_LEAD != 0 { cp = ' '; }
            let wide = c.cp & vt::F_WIDE != 0;
            var fg = resolve(st.fg, DEFAULT_FG);
            var bg = resolve(st.bg, DEFAULT_BG);
            if st.flags & vt::A_DIM != 0 { fg = dim(fg); }
            if st.flags & vt::A_INVERSE != 0 { swap(fg, bg); }
            if st.flags & vt::A_HIDDEN != 0 { fg = bg; }
            let cx = x - 1;
            let on_cursor = offset == 0 && vt::cursor_visible && y == vt::cur.y && cx == vt::cur.x;
            if on_cursor && focused && vt::cursor_shape <= 2 {
                fg = bg;
                bg = CURSOR;
            } else if selected(y, cx) {
                bg = SELECTION;
            }
            let px = margin + cx * cell_w;
            let w = if wide { 2.0 * cell_w } else { cell_w };
            if !draw_box(cp, px, py, w, fg, bg) {
                var g = Glyph { rect: float4_0, uv: float4_0 };
                if cp > ' ' { g = glyph(cp, st.flags & vt::A_BOLD != 0); }
                insts.push(Inst { pos: float2 { px, py }, size: float2 { w, cell_h }, rect: g.rect,
                                  uv: g.uv, fg: rgba(fg), bg: rgba(bg) });
            }
            if st.flags & vt::A_UL_MASK != 0 { solid(px, py + underline_y, w, line_w, fg); }
            if st.flags & vt::A_STRIKE != 0 { solid(px, py + floor(cell_h / 2.0), w, line_w, fg); }
            if on_cursor && !(focused && vt::cursor_shape <= 2) {
                let s = vt::cursor_shape;
                if !focused {
                    solid(px, py, w, line_w, CURSOR);
                    solid(px, py + cell_h - line_w, w, line_w, CURSOR);
                    solid(px, py, line_w, cell_h, CURSOR);
                    solid(px + w - line_w, py, line_w, cell_h, CURSOR);
                } else if s == 3 || s == 4 {
                    solid(px, py + cell_h - 2.0 * line_w, w, 2.0 * line_w, CURSOR);
                } else {
                    solid(px, py, 2.0 * line_w, cell_h, CURSOR);
                }
            }
        }
    }
}

// The selection's text, rows joined by newlines, trailing blanks dropped.
fn selection_text() -> u8[>..] {
    var out: u8[>..] = [];
    guard sel_on else { return out; }
    var ay = sel_y0;
    var ax = sel_x0;
    var by = sel_y1;
    var bx = sel_x1;
    if by < ay || (by == ay && bx < ax) { swap(ay, by); swap(ax, bx); }
    for y in ay..by + 1 {
        let r = view_row(y);
        let start = out.len;
        let x0 = if y == ay { ax } else { 0 };
        let x1 = if y == by { bx + 1 } else { vt::cols };
        for x in x0..min(x1, r.len) {
            let c = r[x];
            if c.cp & (vt::F_SPACER | vt::F_LEAD) != 0 { continue; }
            var cp = c.cp & vt::CP_MASK;
            if c.cp & vt::F_MARKS != 0 { cp = vt::marks[cp].base; }
            if cp == 0 { cp = ' '; }
            push_utf8(out, cp);
        }
        while out.len > start && out[out.len - 1] == ' ' { out.resize(out.len - 1); }
        if y != by { out.push('\n'); }
    }
    return out;
}

// --- input ---------------------------------------------------------------------------------

var outq: u8[>..] = [];

fn send(s: const u8[:]) { outq.append(s); }

fn send_esc(s: const u8[:]) {
    outq.push(0x1B);
    outq.append(s);
}

// A cursor or editing key: CSI <code> with the modifiers as xterm adds them.
fn send_key(final: u8, ss3: bool, m: i64) {
    if m > 1 {
        send_esc("[1;");
        format(outq, m);
        outq.push(final);
    } else if ss3 {
        send_esc("O");
        outq.push(final);
    } else {
        send_esc("[");
        outq.push(final);
    }
}

fn send_tilde(code: i64, m: i64) {
    send_esc("[");
    format(outq, code);
    if m > 1 { outq.push(';'); format(outq, m); }
    outq.push('~');
}

fn paste(text: const u8[:]) {
    if vt::bracketed_paste { send_esc("[200~"); }
    for b in text {
        // Newlines arrive as Enter, and nothing in the text ends the paste early.
        if b == '\n' { outq.push('\r'); } else if b != 0x1B { outq.push(b); }
    }
    if vt::bracketed_paste { send_esc("[201~"); }
}

fn scroll_view(n: i64) {
    guard !vt::alt();
    offset = max(min(offset + n, vt::hist_len), 0);
}

let F_CODES: i64[12] = [0, 0, 0, 0, 15, 17, 18, 19, 20, 21, 23, 24];

var font_px: f32 = 16.0;
var font_scale: f32 = 1.0;
var font_changed = false;

// A key going down: true when it was handled here, and the text it may also
// type should not be sent.
fn key(e: gfx::Event) -> bool {
    let shift = e.mods & gfx::MOD_SHIFT != 0;
    let ctrl = e.mods & gfx::MOD_CTRL != 0;
    let alt = e.mods & gfx::MOD_ALT != 0;
    let m = 1 + (if shift { 1 } else { 0 }) + (if alt { 2 } else { 0 }) + (if ctrl { 4 } else { 0 });
    let name = gfx::key_name(e.scancode);
    let k = e.keycode;

    if ctrl && shift && k == 'c' {
        let t = selection_text();
        if t.len > 0 { gfx::set_clipboard(t); }
        return true;
    }
    if (ctrl && shift && k == 'v') || (shift && name == "Insert") {
        paste(gfx::clipboard());
        return true;
    }
    if ctrl && (k == '=' || k == '+') { font_px += 1.0; font_changed = true; return true; }
    if ctrl && k == '-' { font_px = max(font_px - 1.0, 6.0); font_changed = true; return true; }
    if ctrl && k == '0' { font_px = 16.0; font_changed = true; return true; }
    if shift && !ctrl {
        if name == "PageUp" { scroll_view(vt::nrows - 1); return true; }
        if name == "PageDown" { scroll_view(-(vt::nrows - 1)); return true; }
        if name == "Home" && !vt::alt() { offset = vt::hist_len; return true; }
        if name == "End" && !vt::alt() { offset = 0; return true; }
    }

    var handled = true;
    if name == "Return" || name == "Keypad Enter" {
        if alt { send_esc("\r"); } else { send("\r"); }
    } else if name == "Backspace" {
        if ctrl { send("\x08"); } else if alt { send_esc("\x7f"); } else { send("\x7f"); }
    } else if name == "Tab" {
        if shift { send_esc("[Z"); } else { send("\t"); }
    } else if name == "Escape" {
        send("\x1b");
    } else if name == "Up" { send_key('A', vt::app_cursor, m); }
    else if name == "Down" { send_key('B', vt::app_cursor, m); }
    else if name == "Right" { send_key('C', vt::app_cursor, m); }
    else if name == "Left" { send_key('D', vt::app_cursor, m); }
    else if name == "Home" { send_key('H', vt::app_cursor, m); }
    else if name == "End" { send_key('F', vt::app_cursor, m); }
    else if name == "Insert" { send_tilde(2, m); }
    else if name == "Delete" { send_tilde(3, m); }
    else if name == "PageUp" { send_tilde(5, m); }
    else if name == "PageDown" { send_tilde(6, m); }
    else if name.len >= 2 && name.len <= 3 && name[0] == 'F' && name[1] >= '1' && name[1] <= '9' {
        var n = (name[1] - '0') as i64;
        if name.len == 3 { n = n * 10 + (name[2] - '0'); }
        if n >= 1 && n <= 4 {
            send_key('P' + (n - 1) as u8, true, m);
        } else if n <= 12 {
            send_tilde(F_CODES[n - 1], m);
        } else {
            handled = false;
        }
    } else if ctrl && !alt {
        // The control characters: Ctrl+A is 1, Ctrl+[ is ESC, Ctrl+Space is NUL.
        var c = -1;
        if k >= 'a' && k <= 'z' { c = k - 'a' + 1; }
        else if k == ' ' || k == '2' || k == '@' { c = 0; }
        else if k == '[' || k == '3' { c = 27; }
        else if k == '\\' || k == '4' { c = 28; }
        else if k == ']' || k == '5' { c = 29; }
        else if k == '6' || k == '^' { c = 30; }
        else if k == '/' || k == '7' || k == '_' { c = 31; }
        else if k == '8' { c = 127; }
        if c >= 0 { outq.push(c as u8); } else { handled = false; }
    } else {
        handled = false;
    }
    if handled { offset = 0; sel_on = false; }
    return handled;
}

// A mouse report, when the program asked for them: SGR (1006) or the old
// form; button 0-2, 3 for a release in the old form, 64 and 65 the wheel,
// 32 added for motion.
fn mouse_report(button: i64, x: i64, y: i64, down: bool, mods: i32) {
    var b = button;
    if mods & gfx::MOD_SHIFT != 0 { b += 4; }
    if mods & gfx::MOD_ALT != 0 { b += 8; }
    if mods & gfx::MOD_CTRL != 0 { b += 16; }
    if vt::sgr_mouse {
        send_esc("[<");
        format(outq, b, ";", x + 1, ";", y + 1);
        outq.push(if down { 'M' } else { 'm' });
    } else {
        if !down { b = (b & ~3) | 3; }
        guard x < 223 && y < 223;
        send_esc("[M");
        outq.push((32 + b) as u8);
        outq.push((33 + x) as u8);
        outq.push((33 + y) as u8);
    }
}

fn cell_at(p: float2) -> i64, i64 {
    let x = floor((p.x - margin) / cell_w) as! i64;
    let y = floor((p.y - margin) / cell_h) as! i64;
    return max(min(y, vt::nrows - 1), 0), max(min(x, vt::cols - 1), 0);
}

var buttons_down = 0;           // a bit per button, for motion reports

fn mouse(e: gfx::Event) {
    let shift = e.mods & gfx::MOD_SHIFT != 0;
    let reporting = vt::mouse_mode != 0 && !shift;
    if e.kind == gfx::EVENT_MOUSE_WHEEL {
        let n = if e.y > 0.0 { 3 } else if e.y < 0.0 { -3 } else { 0 };
        guard n != 0;
        let y, x = cell_at(gfx::mouse_pos());
        if reporting {
            for k in 3 { mouse_report(if n > 0 { 64 } else { 65 }, x, y, true, e.mods); }
        } else if vt::alt() {
            // Alternate scroll: the wheel as arrow keys where there is no scrollback.
            for k in 3 { send_key(if n > 0 { 'A' } else { 'B' }, vt::app_cursor, 1); }
        } else {
            scroll_view(n);
        }
        return;
    }
    let y, x = cell_at(float2 { e.x, e.y });
    if e.kind == gfx::EVENT_MOUSE_BUTTON {
        let b = if e.button == gfx::MOUSE_LEFT { 0 } else if e.button == gfx::MOUSE_MIDDLE { 1 }
                else if e.button == gfx::MOUSE_RIGHT { 2 } else { -1 };
        guard b >= 0;
        if e.down { buttons_down |= 1 << b; } else { buttons_down &= ~(1 << b); }
        if reporting {
            mouse_report(b, x, y, e.down, e.mods);
            return;
        }
        if b == 0 && e.down {
            sel_on = false;
            selecting = true;
            sel_y0 = y;
            sel_x0 = x;
            sel_y1 = y;
            sel_x1 = x;
        } else if b == 0 {
            selecting = false;
        } else if b == 1 && e.down {
            paste(gfx::clipboard());
        }
        return;
    }
    if e.kind == gfx::EVENT_MOUSE_MOTION {
        if reporting {
            if vt::mouse_mode == 1003 || (vt::mouse_mode == 1002 && buttons_down != 0) {
                var b = 3;
                for k in 3 { if buttons_down & (1 << k) != 0 { b = k; break; } }
                mouse_report(b + 32, x, y, true, e.mods);
            }
            return;
        }
        if selecting && (y != sel_y0 || x != sel_x0 || sel_on) {
            sel_on = true;
            sel_y1 = y;
            sel_x1 = x;
        }
    }
}

// Sends the core's replies and the keys typed, as much as the pty takes;
// false once it is gone.
fn send_pending(fd: i64) -> bool {
    if vt::replies.len > 0 {
        outq.append(vt::replies);
        vt::replies.clear();
    }
    guard outq.len > 0 else { return true; }
    let w = pty_write(fd, outq);
    if w < 0 { return false; }
    if w == outq.len { outq.clear(); return true; }
    if w > 0 {
        let rest = outq.len - w;
        for k in rest { outq[k] = outq[w + k]; }
        outq.resize(rest);
    }
    return true;
}

// --keys: each key with its modifiers held around it.
fn press_keys(list: const u8[:]) {
    var i = 0;
    while i < list.len {
        var j = i;
        while j < list.len && list[j] != ',' { j += 1; }
        var k = list[i..j];
        var mods = 0;
        loop {
            if starts_with(k, "Ctrl+") { mods |= 1; k = k[5..]; }
            else if starts_with(k, "Shift+") { mods |= 2; k = k[6..]; }
            else if starts_with(k, "Alt+") { mods |= 4; k = k[4..]; }
            else { break; }
        }
        if mods & 1 != 0 { gfx::inject_key("Left Ctrl", true); }
        if mods & 2 != 0 { gfx::inject_key("Left Shift", true); }
        if mods & 4 != 0 { gfx::inject_key("Left Alt", true); }
        if !gfx::inject_key(k, true) { abort(str("gterm: no key ", k)); }
        gfx::inject_key(k, false);
        if mods & 4 != 0 { gfx::inject_key("Left Alt", false); }
        if mods & 2 != 0 { gfx::inject_key("Left Shift", false); }
        if mods & 1 != 0 { gfx::inject_key("Left Ctrl", false); }
        i = j + 1;
    }
}

// --- main ----------------------------------------------------------------------------------

fn main() {
    var font_path: u8[>..] = [];
    var bold_path: u8[>..] = [];
    var shell: u8[>..] = [];
    var command: u8[>..] = [];
    var typed: u8[>..] = [];
    var keys: u8[>..] = [];
    var shot: u8[>..] = [];
    var seconds = -1;
    var cols = 100;
    var rows = 30;
    var history = 10000;
    let a = args();
    var i = 1;
    while i < a.len {
        let s = a[i];
        guard i + 1 < a.len else { abort(str("gterm: ", s, " needs a value")); }
        let v = a[i + 1];
        if s == "--font" { font_path.append(v); }
        else if s == "--bold" { bold_path.append(v); }
        else if s == "--shell" { shell.append(v); }
        else if s == "--exec" { command.append(v); }
        else if s == "--type" { typed.append(v); }
        else if s == "--keys" { keys.append(v); }
        else if s == "--shot" { shot.append(v); }
        else {
            let n, ok = parse_int(v);
            guard ok else { abort(str("gterm: not a number: ", v)); }
            if s == "--cols" { cols = n; }
            else if s == "--rows" { rows = n; }
            else if s == "--history" { history = n; }
            else if s == "--size" { font_px = n; }
            else if s == "--seconds" { seconds = n; }
            else { abort(str("gterm: unknown option ", s)); }
        }
        i += 2;
    }
    if font_path.len == 0 {
        var k = 0;
        while k < FONTS.len {
            if file_exists(FONTS[k]) {
                font_path.append(FONTS[k]);
                if bold_path.len == 0 { bold_path.append(FONTS[k + 1]); }
                break;
            }
            k += 2;
        }
    }
    guard font_path.len > 0 else { abort("gterm: no monospace font found; give one with --font"); }

    init_palette();
    // The font first, so the window opens at exactly cols x rows cells.
    guard load_font(font_path, bold_path, font_px) else {
        abort(str("gterm: cannot load ", font_path, ": ", ui::error()));
    }
    let win_w = (cols * cell_w + 2.0 * margin) as! i64;
    let win_h = (rows * cell_h + 2.0 * margin) as! i64;
    guard gfx::open("gterm", win_w, win_h, gfx::WINDOW_RESIZABLE | gfx::NO_VSYNC) else {
        abort(str("gterm: gfx: ", gfx::error()));
    }
    // On a high-density display the screen has more pixels than the window
    // has units: the font is baked again at that many pixels.
    font_scale = gfx::screen_size().x as f32 / win_w;
    if font_scale < 1.0 { font_scale = 1.0; }
    if font_scale > 1.0 {
        margin = round(4.0 * font_scale);
        guard load_font(font_path, bold_path, round(font_px * font_scale)) else {
            abort(str("gterm: cannot load ", font_path, ": ", ui::error()));
        }
    } else {
        upload_atlas();
    }

    let size0 = gfx::screen_size();
    cols = max(((size0.x - 2.0 * margin) / cell_w) as! i64, 2);
    rows = max(((size0.y - 2.0 * margin) / cell_h) as! i64, 1);
    vt::init(cols, rows, history);
    let fd = pty_spawn(shell, command, cols, rows);
    guard fd >= 0 else { abort("gterm: cannot start a shell on a pty"); }
    pty_resize(fd, cols, rows, size0.x, size0.y);
    gfx::text_input(true);

    let corners: Corner[4] = [Corner { float2 { 0.0, 0.0 } }, Corner { float2 { 1.0, 0.0 } },
                              Corner { float2 { 0.0, 1.0 } }, Corner { float2 { 1.0, 1.0 } }];
    let corner_buf = gfx::vertex_buffer(bytes_of(corners));
    var desc = gfx::PipelineDesc { primitive: gfx::TRIANGLE_STRIP, instance_location: 1 };
    desc.formats[5] = gfx::VERTEX_UBYTE4_NORM;
    desc.formats[6] = gfx::VERTEX_UBYTE4_NORM;
    let pipe = gfx::pipeline(VS, FS, desc);
    let smp = gfx::sampler(gfx::NEAREST, gfx::CLAMP);
    var inst_buf = gfx::Buffer { 0 };
    var inst_cap = 0;

    var buf: u8[>..] = [];
    buf.resize(65536, 0);
    var focused = true;
    var meta_key = -1;          // an Alt+key whose text, if it is the key's own, goes as ESC text
    var swallow_text = false;   // a key handled here: its text is not sent too
    var alive = true;
    var last_output = time();
    var dirty = true;               // something to draw again
    var shown_size = int2_0;
    var typed_at = -1.0;

    while alive && gfx::frame() {
        let now = time();
        // The test input goes in once the shell has been quiet for a while,
        // its prompt drawn.
        if typed.len > 0 && now - last_output > 0.5 {
            gfx::inject_text(typed);
            gfx::inject_key("Return", true);
            gfx::inject_key("Return", false);
            typed.clear();
            typed_at = now;
        } else if keys.len > 0 && typed.len == 0 && now - typed_at > 0.5 {
            press_keys(keys);
            keys.clear();
            typed_at = now;
        }
        if seconds >= 0 && typed.len == 0 && keys.len == 0 && now - typed_at > seconds { break; }
        let evs = gfx::events();
        if evs.len > 0 { dirty = true; }
        for e in evs {
            if e.kind == gfx::EVENT_KEY {
                if !e.down { continue; }
                swallow_text = key(e);
                meta_key = -1;
                if !swallow_text && e.mods & gfx::MOD_ALT != 0 && e.mods & gfx::MOD_CTRL == 0 {
                    meta_key = e.keycode;
                }
            } else if e.kind == gfx::EVENT_TEXT {
                if swallow_text { continue; }
                let c = e.codepoint;
                if meta_key >= 0 && (c == meta_key || c == meta_key - 32) { outq.push(0x1B); }
                push_utf8(outq, c);
                offset = 0;
                sel_on = false;
            } else if e.kind == gfx::EVENT_FOCUS_GAINED {
                focused = true;
                if vt::focus_events { send_esc("[I"); }
            } else if e.kind == gfx::EVENT_FOCUS_LOST {
                focused = false;
                if vt::focus_events { send_esc("[O"); }
            } else {
                mouse(e);
            }
        }

        if font_changed {
            font_changed = false;
            dirty = true;
            if !load_font(font_path, bold_path, round(font_px * font_scale)) {
                abort(str("gterm: cannot load ", font_path, ": ", ui::error()));
            }
        }

        // The window's size in cells.
        let size = gfx::screen_size();
        let c = max(((size.x - 2.0 * margin) / cell_w) as! i64, 2);
        let r = max(((size.y - 2.0 * margin) / cell_h) as! i64, 1);
        if size.x != shown_size.x || size.y != shown_size.y { dirty = true; shown_size = size; }
        if c != vt::cols || r != vt::nrows {
            vt::resize(c, r);
            pty_resize(fd, c, r, size.x, size.y);
            offset = min(offset, vt::hist_len);
            sel_on = false;
        }

        // What the shell writes, read as it comes until the next frame is
        // due: the frames are paced here, 60 a second, rather than by the
        // display's vsync, so a program writing fast is not held up while
        // a frame is drawn and waits to be shown.
        var got = 0;
        let due = now + 1.0 / 60.0;
        loop {
            if !send_pending(fd) { alive = false; break; }
            let n = pty_read(fd, buf);
            if n < 0 { alive = false; break; }
            if n > 0 { vt::feed(buf[..n]); got += n; continue; }
            let left = due - time();
            if left <= 0.0 { break; }
            pty_wait(fd, ceil(left * 1000.0) as! i64);
        }
        if got > 0 { sel_on = sel_on && offset > 0; last_output = now; dirty = true; }
        if offset > 0 && got > 0 { offset = min(offset, vt::hist_len); }
        if vt::title_changed {
            vt::title_changed = false;
            gfx::set_title(if vt::title.len > 0 { vt::title } else { "gterm" });
        }
        if alive && pty_alive() == 0 { alive = false; }

        // Nothing new: the window keeps showing the last frame drawn.
        if !dirty { continue; }
        dirty = false;
        build(focused);
        let bytes = bytes_of(insts);
        if bytes.len > inst_cap {
            if inst_buf.id != 0 { gfx::release(inst_buf); }
            inst_cap = bytes.len * 2;
            inst_buf = gfx::buffer(gfx::BUFFER_VERTEX, inst_cap, bytes);
        } else {
            gfx::update_buffer(inst_buf, bytes);
        }
        let bgc = rgba(DEFAULT_BG);
        gfx::begin_screen(float4 { bgc[0] / 255.0, bgc[1] / 255.0, bgc[2] / 255.0, 1.0 });
        gfx::bind(pipe);
        gfx::bind_vertex_buffer(corner_buf);
        gfx::bind_vertex_buffer(1, inst_buf, 0);
        gfx::uniforms(gfx::VERTEX, 0, View { screen: float4 { size.x, size.y, 0.0, 0.0 } });
        gfx::bind_texture(gfx::FRAGMENT, 0, atlas_tex, smp);
        gfx::draw_instanced(4, insts.len);
        gfx::end_pass();
    }
    if shot.len > 0 && !gfx::screenshot(shot) { write_stderr(str("gterm: ", gfx::error(), "\n")); }
    pty_close(fd);
    ui::destroy(atlas);
    gfx::close();
}
