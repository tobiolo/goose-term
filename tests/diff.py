#!/usr/bin/env python3
"""Run two or more rows over every input and compare their checksum lines.
Where they differ, write both full dumps and show the first differing lines.

  tests/diff.py [--chunk N] [--cols N] [--rows N] ROW1 ROW2 [ROW...] -- INPUT...
"""
import difflib
import os
import subprocess
import sys
import tempfile


def run(row, path, extra, dump=None):
    cmd = [row, path] + extra + (['--dump', dump] if dump else [])
    p = subprocess.run(cmd, capture_output=True)
    if p.returncode != 0:
        return None, p.stderr.decode(errors='replace')[-500:]
    return p.stdout.decode(), None


def main():
    args = sys.argv[1:]
    extra = []
    while args and args[0].startswith('--') and args[0] != '--':
        extra += args[:2]
        args = args[2:]
    sep = args.index('--')
    rows, inputs = args[:sep], args[sep + 1:]
    tmp = tempfile.mkdtemp(prefix='vtdiff-')
    bad = 0
    for path in inputs:
        outs = [run(r, path, extra) for r in rows]
        name = os.path.basename(path)
        failed = [(r, e) for r, (o, e) in zip(rows, outs) if o is None]
        if failed:
            bad += 1
            for r, e in failed:
                print(f'FAIL {name}: {os.path.basename(r)} crashed: {e.strip()}')
            continue
        first = outs[0][0]
        if all(o == first for o, _ in outs):
            print(f'ok   {name}')
            continue
        bad += 1
        print(f'DIFF {name}')
        dumps = []
        for i, r in enumerate(rows):
            d = os.path.join(tmp, f'{name}.{i}.dump')
            run(r, path, extra, d)
            dumps.append(open(d, encoding='utf-8', errors='replace').read().splitlines())
        for i in range(1, len(rows)):
            sums = list(difflib.unified_diff(outs[0][0].splitlines(), outs[i][0].splitlines(), lineterm='', n=0))
            print('  ' + '\n  '.join(sums[2:]))
            diff = list(difflib.unified_diff(dumps[0], dumps[i], os.path.basename(rows[0]),
                                             os.path.basename(rows[i]), lineterm='', n=1))
            for line in diff[:24]:
                print('    ' + line[:200])
    print(f'{len(inputs) - bad}/{len(inputs)} agree')
    sys.exit(1 if bad else 0)


main()
