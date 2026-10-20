#!/usr/bin/env python3
"""The GUI benchmarks: terminal emulators, windows and all, as
vizenc/terminal-benchmark measures them.

Every terminal opens a 174x39 window with DejaVu Sans Mono at 12 pt and no
configuration file of the user's. It runs a command of the harness's and
closes when that ends. Each test runs RUNS times per terminal, the
terminals taking turns:

- plaintext: `cat shakespeare.txt` inside the terminal, timed by the shell
  around it, in milliseconds. That is how fast the terminal takes the text
  in, not when it is all drawn.
- fps: the DOOM-fire port (examples/doomfire) for 10 seconds, its average
  frames per second.
- memory: the terminal's resident set (VmRSS) idle 5 seconds after start,
  and again after the same cat (10000 lines of scrollback). CPU time over
  3 idle seconds is also taken from /proc, as a percentage of one core.

Input latency is not measured: terminal-benchmark films the screen for it.

  gui_bench.py --out results/gui.json [--runs 5] [--only gterm,alacritty]
"""
import argparse
import json
import os
import shlex
import shutil
import statistics
import subprocess
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.environ.get('OUT', os.path.join(ROOT, '.out'))
INPUTS = os.environ.get('INPUTS', os.path.join(ROOT, '.inputs'))
FONT = '/usr/share/fonts/TTF/DejaVuSansMono.ttf'
FONT_BOLD = '/usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf'
COLS, ROWS = 174, 39
TICK = os.sysconf('SC_CLK_TCK')


def command(term, cmd):
    """The command line that opens `term` running `sh -c cmd`."""
    if term == 'gterm':
        return [os.path.join(OUT, 'bin', 'gterm'), '--cols', str(COLS), '--rows', str(ROWS),
                '--size', '16', '--font', FONT, '--bold', FONT_BOLD, '--exec', cmd]
    if term == 'alacritty':
        return ['alacritty', '--config-file', '/dev/null',
                '-o', f'window.dimensions.columns={COLS}', '-o', f'window.dimensions.lines={ROWS}',
                '-o', 'font.normal.family="DejaVu Sans Mono"', '-o', 'font.size=12',
                '-e', 'sh', '-c', cmd]
    if term == 'ghostty':
        return ['ghostty', '--config-default-files=false', '--gtk-single-instance=false',
                f'--window-width={COLS}', f'--window-height={ROWS}',
                '--font-family=DejaVu Sans Mono', '--font-size=12', '--confirm-close-surface=false',
                '--gtk-titlebar=false',  # GTK's header bar would take three of the 39 rows
                '-e', 'sh', '-c', cmd]
    if term == 'xfce4-terminal':
        return ['xfce4-terminal', '--disable-server', f'--geometry={COLS}x{ROWS}',
                '--font=DejaVu Sans Mono 12', '--hide-menubar', '--hide-toolbar', '--hide-scrollbar',
                '-x', 'sh', '-c', cmd]
    raise ValueError(term)


def version(term):
    exe = os.path.join(OUT, 'bin', 'gterm') if term == 'gterm' else term
    if term == 'gterm':
        return subprocess.run(['git', '-C', ROOT, 'rev-parse', '--short', 'HEAD'],
                              capture_output=True, text=True).stdout.strip() + ' (this repository)'
    p = subprocess.run([exe, '--version'], capture_output=True, text=True)
    return (p.stdout or p.stderr).strip().splitlines()[0]


def run(term, cmd, timeout=60, watch=None):
    """Runs the terminal until it closes; watch(proc) is called while it runs."""
    p = subprocess.Popen(command(term, cmd), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    result = None
    try:
        if watch:
            result = watch(p)
        p.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
        raise RuntimeError(f'{term}: did not close within {timeout} s')
    return result


def wait_for(path, p, timeout=30):
    t0 = time.time()
    while not os.path.exists(path):
        if p.poll() is not None or time.time() - t0 > timeout:
            raise RuntimeError(f'no {path}')
        time.sleep(0.005)


def rss_kb(pid):
    with open(f'/proc/{pid}/status') as f:
        for line in f:
            if line.startswith('VmRSS:'):
                return int(line.split()[1])
    return 0


def cpu_s(pid):
    with open(f'/proc/{pid}/stat') as f:
        fields = f.read().rsplit(')', 1)[1].split()
    return (int(fields[11]) + int(fields[12])) / TICK


def read_number(path):
    with open(path) as f:
        return float(f.read().strip())


def size_probe(term, tmp):
    out = os.path.join(tmp, 'size')
    run(term, f'sleep 1.5; stty size > {shlex.quote(out)}')
    rows, cols = open(out).read().split()
    return int(cols), int(rows)


def plaintext(term, tmp, text):
    out = os.path.join(tmp, 'ms')
    q = shlex.quote
    run(term, f'sleep 1; s=$(date +%s%N); cat {q(text)}; e=$(date +%s%N); '
              f'echo $(( (e - s) / 1000000 )) > {q(out)}')
    return read_number(out)


def fps(term, tmp, seconds):
    out = os.path.join(tmp, 'fps')
    doomfire = os.path.join(OUT, 'bin', 'doomfire')
    run(term, f'sleep 1; {shlex.quote(doomfire)} --seconds {seconds} --out {shlex.quote(out)}',
        timeout=seconds + 60)
    return read_number(out)


def memory(term, tmp, text):
    m = [os.path.join(tmp, f'm{k}') for k in range(4)]
    q = shlex.quote
    cmd = (f'sleep 2; touch {q(m[0])}; sleep 3; touch {q(m[1])}; cat {q(text)}; '
           f'touch {q(m[2])}; sleep 2; touch {q(m[3])}; sleep 1')

    def watch(p):
        wait_for(m[0], p)
        c0, t0 = cpu_s(p.pid), time.time()
        wait_for(m[1], p)
        c1, t1 = cpu_s(p.pid), time.time()
        idle = rss_kb(p.pid)
        wait_for(m[3], p)
        return {'idle_rss_mb': idle / 1024, 'after_cat_rss_mb': rss_kb(p.pid) / 1024,
                'idle_cpu_pct': 100 * (c1 - c0) / (t1 - t0)}

    return run(term, cmd, watch=watch)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    ap.add_argument('--runs', type=int, default=5)
    ap.add_argument('--seconds', type=int, default=10, help='how long each fps run lasts')
    ap.add_argument('--only', default='gterm,alacritty,ghostty,xfce4-terminal')
    a = ap.parse_args()
    terms = [t for t in a.only.split(',') if t == 'gterm' or shutil.which(t)]
    text = os.path.join(INPUTS, 'shakespeare.txt')
    res = {t: {'version': version(t), 'plaintext_ms': [], 'fps': [], 'memory': []} for t in terms}
    with tempfile.TemporaryDirectory(prefix='gui-bench-') as tmp:
        for t in terms:
            res[t]['size'] = size_probe(t, tmp)
            print(f'{t:16s} {res[t]["version"]}; opened at {res[t]["size"][0]}x{res[t]["size"][1]}',
                  flush=True)
        for k in range(a.runs):
            for t in terms:
                for f in os.listdir(tmp):
                    os.remove(os.path.join(tmp, f))
                ms = plaintext(t, tmp, text)
                fr = fps(t, tmp, a.seconds)
                mem = memory(t, tmp, text)
                res[t]['plaintext_ms'].append(ms)
                res[t]['fps'].append(fr)
                res[t]['memory'].append(mem)
                print(f'run {k + 1} {t:16s} cat {ms:6.0f} ms   fire {fr:7.1f} fps   '
                      f'idle {mem["idle_rss_mb"]:6.1f} MB, {mem["idle_cpu_pct"]:5.1f}% cpu   '
                      f'after cat {mem["after_cat_rss_mb"]:6.1f} MB', flush=True)
    for t in terms:
        r = res[t]
        r['median'] = {
            'plaintext_ms': statistics.median(r['plaintext_ms']),
            'fps': statistics.median(r['fps']),
            'idle_rss_mb': statistics.median(m['idle_rss_mb'] for m in r['memory']),
            'after_cat_rss_mb': statistics.median(m['after_cat_rss_mb'] for m in r['memory']),
            'idle_cpu_pct': statistics.median(m['idle_cpu_pct'] for m in r['memory']),
        }
    with open(a.out, 'w') as f:
        json.dump({'runs': a.runs, 'fps_seconds': a.seconds, 'cols': COLS, 'rows': ROWS,
                   'terminals': res}, f, indent=1)


main()
