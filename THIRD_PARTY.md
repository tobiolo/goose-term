# Third-party code and data

Nothing below is vendored. `bin/fetch-inputs` and `bin/build-all` fetch it
into `.deps/` at the commits in `bin/env.sh`, and the inputs go into
`.inputs/`. None of it is committed except where noted.

| what | where from | license | used for |
|---|---|---|---|
| Goose | github.com/aardappel/goose @ `1e31b6d` | Apache-2.0 | the compiler and standard library of the Goose row |
| libvterm | github.com/neovim/libvterm @ `9d6d211` (v0.3.3) | MIT | the libvterm row |
| alacritty_terminal 0.26.0, vte 0.15.0 | crates.io | Apache-2.0; vte Apache-2.0 OR MIT | the alacritty row, and the behavior the Goose core reproduces |
| unicode-width 0.2.2 | crates.io | MIT OR Apache-2.0 | character widths. `core/width.bin` (committed) is generated from it by `core/gen_width.py` |
| vtebench | github.com/alacritty/vtebench @ `ead8003` | Apache-2.0 OR MIT | its benchmark scripts are run to record the `vtebench_*` inputs |
| terminal-benchmark | github.com/vizenc/terminal-benchmark @ `f71121d` | no license file | only its `test/shakespeare.txt` (Shakespeare's works, public domain) is copied, as an input |
| DOOM-fire-zig | github.com/const-void/DOOM-fire-zig @ `eb0631b` | GPL-3.0 | `inputs/doomfire.py` (committed) re-implements its output loop to write the `doomfire` input, so treat that one script as GPL-3.0 |
