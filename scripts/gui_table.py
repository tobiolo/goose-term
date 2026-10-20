#!/usr/bin/env python3
"""Turn gui_bench.py's JSON into results/GUI.md: one table per test, a row
per run and the median, as vizenc/terminal-benchmark lays them out.

  gui_table.py results/gui.json > results/GUI.md
"""
import json
import sys


def table(title, note, terms, values, fmt, best):
    print(f'### {title}\n\n{note}\n')
    print('| run | ' + ' | '.join(terms) + ' |')
    print('|---:|' + '---:|' * len(terms))
    n = len(values[terms[0]])
    for k in range(n):
        print(f'| {k + 1} | ' + ' | '.join(fmt(values[t][k]) for t in terms) + ' |')
    meds = {t: sorted(values[t])[n // 2] for t in terms}
    top = best(meds.values())
    print('| median | ' + ' | '.join(f'**{fmt(meds[t])}**' if meds[t] == top else fmt(meds[t])
                                     for t in terms) + ' |')
    print()


def main():
    d = json.load(open(sys.argv[1]))
    res = d['terminals']
    terms = list(res)
    print(f"{d['runs']} runs per terminal, taking turns; each a {d['cols']}x{d['rows']} window, "
          "DejaVu Sans Mono 12 pt, no user configuration.\n")
    print('| terminal | version | opened at |')
    print('|---|---|---|')
    for t in terms:
        print(f"| {t} | {res[t]['version']} | {res[t]['size'][0]}x{res[t]['size'][1]} |")
    print()
    table('Plaintext IO', '`cat` of the 11 MB shakespeare.txt inside the terminal, ms. Lower is better.',
          terms, {t: res[t]['plaintext_ms'] for t in terms}, lambda v: f'{v:.0f}', min)
    table('Frame rate', f"DOOM-fire (examples/doomfire, DOOM-fire-zig's output) for {d['fps_seconds']} s, "
          'frames per second. Higher is better.',
          terms, {t: res[t]['fps'] for t in terms}, lambda v: f'{v:.0f}', max)
    table('Memory, idle', "The terminal process's resident set 5 s after start, MB. Lower is better.",
          terms, {t: [m['idle_rss_mb'] for m in res[t]['memory']] for t in terms},
          lambda v: f'{v:.1f}', min)
    table('Memory, after cat', 'The same, after the cat filled the scrollback, MB. Lower is better.',
          terms, {t: [m['after_cat_rss_mb'] for m in res[t]['memory']] for t in terms},
          lambda v: f'{v:.1f}', min)
    table('CPU, idle', 'CPU time over 3 idle seconds, % of one core. Lower is better.',
          terms, {t: [m['idle_cpu_pct'] for m in res[t]['memory']] for t in terms},
          lambda v: f'{v:.1f}', min)


main()
