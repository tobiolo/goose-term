/* The libvterm row: feed a recorded byte stream to libvterm's screen layer,
   keep the scrollback the way Neovim's terminal does (a ring of malloc'ed
   lines of VTermScreenCell, an evicted line reused when it is as wide), then
   print the canonical dump that every row prints (tests/DUMP.md).

     libvterm_row <input> [--cols N] [--rows N] [--history N] [--chunk N] [--dump FILE] */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "vterm.h"

typedef struct {
    int cols;
    VTermScreenCell cells[];
} SbLine;

static SbLine **sb;
static int sb_cap, sb_head, sb_len;
static int altscreen;

static int on_pushline(int cols, const VTermScreenCell *cells, void *user) {
    (void)user;
    if (sb_cap == 0) return 1;
    SbLine *line = NULL;
    if (sb_len == sb_cap) {
        line = sb[sb_head];
        sb_head = (sb_head + 1) % sb_cap;
        sb_len--;
        if (line->cols != cols) { free(line); line = NULL; }
    }
    if (!line) {
        line = malloc(sizeof(SbLine) + (size_t)cols * sizeof(VTermScreenCell));
        line->cols = cols;
    }
    memcpy(line->cells, cells, (size_t)cols * sizeof(VTermScreenCell));
    sb[(sb_head + sb_len) % sb_cap] = line;
    sb_len++;
    return 1;
}

static int on_sb_clear(void *user) {
    (void)user;
    for (int i = 0; i < sb_len; i++) free(sb[(sb_head + i) % sb_cap]);
    sb_head = sb_len = 0;
    return 1;
}

static int on_termprop(VTermProp prop, VTermValue *val, void *user) {
    (void)user;
    if (prop == VTERM_PROP_ALTSCREEN) altscreen = val->boolean;
    return 1;
}

static const VTermScreenCallbacks callbacks = {
    .sb_pushline = on_pushline,
    .sb_clear = on_sb_clear,
    .settermprop = on_termprop,
};

/* A growable byte buffer for the dump's lines. */
typedef struct { char *p; size_t n, cap; } Buf;

static void put(Buf *b, const void *s, size_t n) {
    if (b->n + n > b->cap) {
        b->cap = (b->n + n) * 2 + 64;
        b->p = realloc(b->p, b->cap);
    }
    memcpy(b->p + b->n, s, n);
    b->n += n;
}

static void puts_(Buf *b, const char *s) { put(b, s, strlen(s)); }

static void put_utf8(Buf *b, uint32_t c) {
    char o[4];
    int n;
    if (c < 0x80) { o[0] = (char)c; n = 1; }
    else if (c < 0x800) { o[0] = (char)(0xC0 | c >> 6); o[1] = (char)(0x80 | (c & 63)); n = 2; }
    else if (c < 0x10000) { o[0] = (char)(0xE0 | c >> 12); o[1] = (char)(0x80 | (c >> 6 & 63)); o[2] = (char)(0x80 | (c & 63)); n = 3; }
    else { o[0] = (char)(0xF0 | c >> 18); o[1] = (char)(0x80 | (c >> 12 & 63)); o[2] = (char)(0x80 | (c >> 6 & 63)); o[3] = (char)(0x80 | (c & 63)); n = 4; }
    put(b, o, (size_t)n);
}

static uint64_t fnv(uint64_t h, const char *p, size_t n) {
    for (size_t i = 0; i < n; i++) h = (h ^ (unsigned char)p[i]) * 1099511628211ull;
    return h;
}

static void color(char *o, const VTermColor *c, int is_fg) {
    if (is_fg ? VTERM_COLOR_IS_DEFAULT_FG(c) : VTERM_COLOR_IS_DEFAULT_BG(c)) strcpy(o, "d");
    else if (VTERM_COLOR_IS_INDEXED(c)) sprintf(o, "i%d", c->indexed.idx);
    else sprintf(o, "#%02x%02x%02x", c->rgb.red, c->rgb.green, c->rgb.blue);
}

static int is_spacer(const VTermScreenCell *c) { return c->chars[0] == (uint32_t)-1; }

static void attr(char *o, const VTermScreenCell *c) {
    char fg[16], bg[16];
    int blank = c->chars[0] == 0 || c->chars[0] == ' ' || is_spacer(c);
    if (blank) strcpy(fg, "d"); else color(fg, &c->fg, 1);
    color(bg, &c->bg, 0);
    int bits = 0;
    if (c->attrs.bold) bits |= 1;
    if (c->attrs.italic) bits |= 4;
    if (c->attrs.underline) bits |= 8;
    if (c->attrs.reverse) bits |= 16;
    if (c->attrs.conceal) bits |= 32;
    if (c->attrs.strike) bits |= 64;
    sprintf(o, "%s/%s/%d", fg, bg, bits);
}

/* One row of `cols` cells (`have` of them given, the rest default blanks). */
static void row_lines(const VTermScreenCell *cells, int have, int cols, Buf *text, Buf *attrs) {
    static VTermScreenCell blankcell;
    static int init;
    if (!init) {
        memset(&blankcell, 0, sizeof blankcell);
        blankcell.fg.type = VTERM_COLOR_DEFAULT_FG | VTERM_COLOR_INDEXED;
        blankcell.bg.type = VTERM_COLOR_DEFAULT_BG | VTERM_COLOR_INDEXED;
        init = 1;
    }
    text->n = attrs->n = 0;
    for (int x = 0; x < cols; x++) {
        const VTermScreenCell *c = x < have ? &cells[x] : &blankcell;
        if (is_spacer(c)) continue;
        put_utf8(text, c->chars[0] ? c->chars[0] : ' ');
        for (int k = 1; k < VTERM_MAX_CHARS_PER_CELL && c->chars[0] && c->chars[k]; k++) put_utf8(text, c->chars[k]);
    }
    while (text->n > 0 && text->p[text->n - 1] == ' ') text->n--;
    char prev[64] = "", one[64], num[24];
    int run = 0;
    for (int x = 0; x < cols; x++) {
        attr(one, x < have ? &cells[x] : &blankcell);
        if (run > 0 && strcmp(one, prev) != 0) {
            sprintf(num, "%d*", run);
            puts_(attrs, num); puts_(attrs, prev); puts_(attrs, ",");
            run = 0;
        }
        if (run == 0) strcpy(prev, one);
        run++;
    }
    sprintf(num, "%d*", run);
    puts_(attrs, num); puts_(attrs, prev); puts_(attrs, ",");
}

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

int main(int argc, char **argv) {
    int cols = 174, rows = 39, history = 10000;
    long chunk = 65536;
    const char *input = NULL, *dump = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--cols")) cols = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--rows")) rows = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--history")) history = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--chunk")) chunk = atol(argv[++i]);
        else if (!strcmp(argv[i], "--dump")) dump = argv[++i];
        else input = argv[i];
    }
    if (!input) { fprintf(stderr, "usage: libvterm_row <input> [--cols N] [--rows N] [--history N] [--chunk N] [--dump FILE]\n"); return 2; }

    double t0 = now_ms();
    FILE *f = fopen(input, "rb");
    if (!f) { perror(input); return 2; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *data = malloc((size_t)size + 1);
    if (fread(data, 1, (size_t)size, f) != (size_t)size) { perror("read"); return 2; }
    fclose(f);
    double t1 = now_ms();

    sb_cap = history;
    sb = calloc((size_t)(history > 0 ? history : 1), sizeof *sb);
    VTerm *vt = vterm_new(rows, cols);
    vterm_set_utf8(vt, 1);
    VTermScreen *screen = vterm_obtain_screen(vt);
    vterm_screen_set_callbacks(screen, &callbacks, NULL);
    vterm_screen_enable_altscreen(screen, 1);
    vterm_screen_reset(screen, 1);
    for (long off = 0; off < size; off += chunk) {
        long n = size - off < chunk ? size - off : chunk;
        vterm_input_write(vt, data + off, (size_t)n);
    }
    vterm_screen_flush_damage(screen);
    double t2 = now_ms();

    Buf text = {0}, attrs = {0}, full = {0};
    uint64_t ht = 14695981039346656037ull, ha = ht, st = ht, sa = ht;
    int shown = altscreen ? 0 : sb_len;
    for (int k = 0; k < shown; k++) {
        SbLine *l = sb[(sb_head + k) % sb_cap];
        row_lines(l->cells, l->cols, cols, &text, &attrs);
        ht = fnv(fnv(ht, text.p, text.n), "\n", 1);
        ha = fnv(fnv(ha, attrs.p, attrs.n), "\n", 1);
        if (dump) { puts_(&full, "H "); put(&full, text.p, text.n); puts_(&full, "\n  "); put(&full, attrs.p, attrs.n); puts_(&full, "\n"); }
    }
    VTermScreenCell *row = malloc((size_t)cols * sizeof *row);
    for (int y = 0; y < rows; y++) {
        for (int x = 0; x < cols; x++) vterm_screen_get_cell(screen, (VTermPos){.row = y, .col = x}, &row[x]);
        row_lines(row, cols, cols, &text, &attrs);
        st = fnv(fnv(st, text.p, text.n), "\n", 1);
        sa = fnv(fnv(sa, attrs.p, attrs.n), "\n", 1);
        if (dump) { puts_(&full, "S "); put(&full, text.p, text.n); puts_(&full, "\n  "); put(&full, attrs.p, attrs.n); puts_(&full, "\n"); }
    }
    if (dump) {
        FILE *o = fopen(dump, "wb");
        fwrite(full.p, 1, full.n, o);
        fclose(o);
    }
    VTermPos cur;
    vterm_state_get_cursorpos(vterm_obtain_state(vt), &cur);
    double t3 = now_ms();
    vterm_free(vt);
    on_sb_clear(NULL);
    free(sb);
    free(data);
    double t4 = now_ms();

    fprintf(stderr, "phases_ms read %.1f feed %.1f dump %.1f teardown %.1f\n", t1 - t0, t2 - t1, t3 - t2, t4 - t3);
    printf("bytes %ld\nsize %d %d\ncursor %d %d\nhistory %d\n", size, rows, cols, cur.row, cur.col, shown);
    printf("history_text %llu\nhistory_attr %llu\nscreen_text %llu\nscreen_attr %llu\n",
           (unsigned long long)ht, (unsigned long long)ha, (unsigned long long)st, (unsigned long long)sa);
    return 0;
}
