/* The terminal under matrix.goose: its size, raw keyboard input, and the
   state put back on the way out, however the program ends. */
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

static struct termios saved;
static int raw_on;
static volatile sig_atomic_t quit_signal;

static void on_signal(int sig) { (void)sig; quit_signal = 1; }

/* The terminal's columns and rows; 0 if stdout is not one. */
int32_t mx_tty_size(int64_t *cols, int64_t *rows) {
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) != 0 || ws.ws_col == 0 || ws.ws_row == 0) return 0;
    *cols = ws.ws_col;
    *rows = ws.ws_row;
    return 1;
}

void mx_tty_restore(void) {
    if (!raw_on) return;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved);
    raw_on = 0;
}

/* Keys one at a time, unechoed; Ctrl+C arrives as a key (3). */
void mx_tty_raw(void) {
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);
    signal(SIGINT, on_signal);
    if (tcgetattr(STDIN_FILENO, &saved) != 0) return;
    struct termios t = saved;
    t.c_lflag &= ~(ICANON | ECHO | ISIG | IEXTEN);
    t.c_iflag &= ~(IXON | ICRNL);
    t.c_cc[VMIN] = 0;
    t.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &t) == 0) {
        raw_on = 1;
        atexit(mx_tty_restore);
    }
}

/* A key pressed since the last call, or -1. */
int32_t mx_tty_key(void) {
    struct pollfd p = { STDIN_FILENO, POLLIN, 0 };
    if (poll(&p, 1, 0) <= 0) return -1;
    unsigned char c;
    return read(STDIN_FILENO, &c, 1) == 1 ? c : -1;
}

int32_t mx_tty_quit_signal(void) { return quit_signal; }
