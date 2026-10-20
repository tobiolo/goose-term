#!/usr/bin/env python3
"""Time every row on every input.

For each input the rows run in turn (a, b, c, a, b, c, ...): one warm-up run,
then RUNS timed runs, each pinned to one CPU. A run is timed whole, from fork
to exit (read the input, feed it, dump, tear down), with time.perf_counter;
its user and system time and peak resident memory come from wait4. Every run's
checksum lines are compared with the first row's: a row that differs is marked,
not dropped, so the table says which rows did the same work.

  bench.py --out results.json [--runs 5] [--cpu 2] ROW=PATH... -- INPUT...
"""
import argparse
import json
import os
import statistics
import sys
import time


def run_once(argv, cpu):
    r, w = os.pipe()
    t0 = time.perf_counter()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        os.dup2(w, 1)
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, 2)
        os.sched_setaffinity(0, {cpu})
        os.execv(argv[0], argv)
    os.close(w)
    out = b''
    while True:
        chunk = os.read(r, 1 << 16)
        if not chunk:
            break
        out += chunk
    _, status, ru = os.wait4(pid, 0)
    t1 = time.perf_counter()
    os.close(r)
    return {
        'wall': t1 - t0,
        'user': ru.ru_utime,
        'sys': ru.ru_stime,
        'maxrss_kb': ru.ru_maxrss,
        'status': status,
        'out': out.decode(errors='replace'),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    ap.add_argument('--runs', type=int, default=5)
    ap.add_argument('--cpu', type=int, default=2)
    ap.add_argument('--extra', default='', help='arguments for every row, e.g. "--cols 174 --rows 39"')
    ap.add_argument('rows', nargs='+', metavar='ROW=PATH')
    if '--' not in sys.argv:
        ap.error('missing "--" before the inputs')
    sep = sys.argv.index('--')
    a = ap.parse_args(sys.argv[1:sep])
    rows = [x.split('=', 1) for x in a.rows]
    inputs = sys.argv[sep + 1:]
    extra = a.extra.split()
    results = []
    for path in inputs:
        name = os.path.basename(path).rsplit('.', 1)[0]
        size = os.path.getsize(path)
        runs = {r: [] for r, _ in rows}
        for k in range(a.runs + 1):
            for r, exe in rows:
                res = run_once([exe, path] + extra, a.cpu)
                if k > 0:
                    runs[r].append(res)
        ref = runs[rows[0][0]][0]['out']
        entry = {'input': name, 'bytes': size, 'rows': {}}
        for r, _ in rows:
            rs = runs[r]
            walls = [x['wall'] for x in rs]
            ok = all(x['status'] == 0 for x in rs)
            entry['rows'][r] = {
                'median': statistics.median(walls),
                'min': min(walls),
                'max': max(walls),
                'user': statistics.median(x['user'] for x in rs),
                'sys': statistics.median(x['sys'] for x in rs),
                'maxrss_kb': max(x['maxrss_kb'] for x in rs),
                'ok': ok,
                'agrees': ok and all(x['out'] == ref for x in rs),
                'checksums': rs[0]['out'],
            }
        results.append(entry)
        line = '  '.join(f"{r} {entry['rows'][r]['median']:.3f}s {entry['rows'][r]['maxrss_kb'] / 1024:.1f}MB"
                         + ('' if entry['rows'][r]['agrees'] else ' (differs)') for r, _ in rows)
        print(f'{name:40s} {line}', flush=True)
    with open(a.out, 'w') as f:
        json.dump({'runs': a.runs, 'cpu': a.cpu, 'extra': a.extra, 'results': results}, f, indent=1)


main()
