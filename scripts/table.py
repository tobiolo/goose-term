#!/usr/bin/env python3
"""Turn bench.py's JSON into the Markdown tables of results/RESULTS.md.

  table.py results/bench.json [--vs goose]

One table of wall time (median of the runs, min-max under it as a spread)
and one of peak resident memory. A row whose checksums differ from the first
row's is marked †. The geometric means compare --vs with each other row
over the inputs where both agree with the reference.
"""
import json
import math
import sys


def main():
    path = sys.argv[1]
    vs = sys.argv[sys.argv.index('--vs') + 1] if '--vs' in sys.argv else 'goose'
    d = json.load(open(path))
    res = d['results']
    rows = list(res[0]['rows'])
    print(f"{d['runs']} timed runs after one warm-up, pinned to CPU {d['cpu']}; median wall time, "
          f"whole process. † = checksums differ from {rows[0]}'s.\n")
    print('| input | MB | ' + ' | '.join(rows) + ' |')
    print('|---|---:|' + '---:|' * len(rows))
    for e in res:
        cells = []
        for r in rows:
            x = e['rows'][r]
            mark = '' if x['agrees'] else ' †'
            if not x['ok']:
                cells.append('crash')
                continue
            cells.append(f"{x['median'] * 1000:.0f} ms{mark}")
        print(f"| {e['input']} | {e['bytes'] / 1e6:.1f} | " + ' | '.join(cells) + ' |')
    print('\nPeak resident memory (MB; the input itself is read whole into memory by every row):\n')
    print('| input | ' + ' | '.join(rows) + ' |')
    print('|---|' + '---:|' * len(rows))
    for e in res:
        print(f"| {e['input']} | " + ' | '.join(f"{e['rows'][r]['maxrss_kb'] / 1024:.1f}" for r in rows) + ' |')
    print(f'\nGeometric means, {vs} against each row, over the inputs where both agree with {rows[0]}:\n')
    print('| against | inputs | speed | peak memory |')
    print('|---|---:|---:|---:|')
    for r in rows:
        if r == vs:
            continue
        both = [e for e in res if e['rows'][r]['agrees'] and e['rows'][vs]['agrees']]
        if not both:
            continue
        sp = math.exp(sum(math.log(e['rows'][r]['median'] / e['rows'][vs]['median']) for e in both) / len(both))
        mem = math.exp(sum(math.log(e['rows'][r]['maxrss_kb'] / e['rows'][vs]['maxrss_kb']) for e in both) / len(both))
        print(f'| {r} | {len(both)} | {sp:.2f}x {"faster" if sp >= 1 else "slower"} | '
              f'{mem if mem >= 1 else 1 / mem:.2f}x {"less" if mem >= 1 else "more"} |')


main()
