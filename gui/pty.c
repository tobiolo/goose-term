/* The pseudo-terminal under the GUI: a shell started on a new pty, and
   non-blocking reads and writes of its master side. The functions are what
   gui/gterm.goose declares as extern fn; a Goose slice arrives as
   { data, len }. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

typedef struct { uint8_t *data; int64_t len; } gt_bytes;

static pid_t child = -1;

/* Starts `shell` (a NUL-free path; $SHELL or /bin/sh when empty) on a new
   pty of cols x rows, or `/bin/sh -c command` when a command is given, and
   returns the master's descriptor, or -1. */
int64_t gt_pty_spawn(gt_bytes shell, gt_bytes command, int64_t cols, int64_t rows) {
    char path[4096];
    if (shell.len > 0 && shell.len < (int64_t)sizeof path) {
        memcpy(path, shell.data, (size_t)shell.len);
        path[shell.len] = 0;
    } else {
        const char *s = getenv("SHELL");
        strncpy(path, s && *s ? s : "/bin/sh", sizeof path - 1);
        path[sizeof path - 1] = 0;
    }
    struct winsize ws = { (unsigned short)rows, (unsigned short)cols, 0, 0 };
    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) return -1;
    if (pid == 0) {
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        unsetenv("COLUMNS");
        unsetenv("LINES");
        signal(SIGINT, SIG_DFL);
        signal(SIGQUIT, SIG_DFL);
        signal(SIGCHLD, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);
        if (command.len > 0) {
            char *cmd = malloc((size_t)command.len + 1);
            memcpy(cmd, command.data, (size_t)command.len);
            cmd[command.len] = 0;
            execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
            _exit(127);
        }
        const char *name = strrchr(path, '/');
        execlp(path, name ? name + 1 : path, (char *)NULL);
        _exit(127);
    }
    child = pid;
    fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK);
    fcntl(master, F_SETFD, FD_CLOEXEC);
    return master;
}

/* Reads what is there into buf: the byte count, 0 for nothing yet, -1 once
   the other side is gone. */
int64_t gt_pty_read(int64_t fd, gt_bytes buf) {
    for (;;) {
        ssize_t n = read((int)fd, buf.data, (size_t)buf.len);
        if (n > 0) return n;
        if (n == 0) return -1;
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        return -1;   /* EIO: the shell and everything on the pty exited */
    }
}

/* Writes as much of buf as the pty takes now: the byte count, -1 on error. */
int64_t gt_pty_write(int64_t fd, gt_bytes buf) {
    int64_t done = 0;
    while (done < buf.len) {
        ssize_t n = write((int)fd, buf.data + done, (size_t)(buf.len - done));
        if (n > 0) { done += n; continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        return -1;
    }
    return done;
}

void gt_pty_resize(int64_t fd, int64_t cols, int64_t rows, int64_t px_w, int64_t px_h) {
    struct winsize ws = { (unsigned short)rows, (unsigned short)cols,
                          (unsigned short)px_w, (unsigned short)px_h };
    ioctl((int)fd, TIOCSWINSZ, &ws);
}

/* Whether the shell is still running; reaps it once it is not. */
int32_t gt_pty_alive(void) {
    if (child <= 0) return 0;
    int status;
    pid_t r = waitpid(child, &status, WNOHANG);
    if (r == 0) return 1;
    child = -1;
    return 0;
}

void gt_pty_close(int64_t fd) {
    if (child > 0) kill(child, SIGHUP);
    close((int)fd);
}

/* Waits up to ms milliseconds for the pty to have something to read: 1 if
   it has, 0 if the time ran out. */
int32_t gt_pty_wait(int64_t fd, int64_t ms) {
    struct pollfd p = { (int)fd, POLLIN, 0 };
    int r = poll(&p, 1, ms < 0 ? 0 : (int)ms);
    return r > 0;
}
