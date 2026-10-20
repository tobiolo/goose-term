# The machine the committed results come from

| | |
|---|---|
| CPU | 13th Gen Intel Core i7-1355U: 2 P-cores (CPUs 0-3, up to 5.0 GHz) and 8 E-cores (CPUs 4-11) |
| Pinning | every run on CPU 2, a P-core (`bench.py --cpu 2`, through `sched_setaffinity`) |
| Power | on AC; `powersave` governor with `balance_performance` (intel_pstate defaults), turbo on |
| Memory | 30 GiB |
| OS | Arch Linux, kernel 7.2.11-arch1-1 |
| C | gcc 16.2.1 20260810; libvterm and its row at `-O2 -DNDEBUG` |
| Rust | rustc 1.99.1 (Arch Linux); alacritty's release profile: opt-level 3, thin LTO |
| Goose | commit `1e31b6d` of github.com/aardappel/goose, Release build; the row built with `goose build -O2 --cc gcc` |
| Python | 3.14.8, for the runner and the input generators |

## How a run is timed

`scripts/bench.py` forks, pins the child to one CPU, execs the row on one
input, and waits for it with `wait4`:

- wall time: `time.perf_counter` from fork to the end of the wait, so it
  includes reading the input, the dump and teardown;
- user and system time, and peak resident set size: the child's `rusage`.

The rows take turns on each input (alacritty, libvterm, goose, alacritty, ...),
one warm-up round and then five timed rounds. The table reports medians.
