5 runs per terminal, taking turns; each a 174x39 window, DejaVu Sans Mono 12 pt, no user configuration.

| terminal | version | opened at |
|---|---|---|
| gterm | 27f3326 (this repository) | 174x39 |
| alacritty | alacritty 0.17.0 (94e7c887) | 174x39 |
| ghostty | Ghostty 1.3.1-arch2 | 174x39 |
| xfce4-terminal | xfce4-terminal 1.2.0 (Xfce 4.21) | 174x39 |

### Plaintext IO

`cat` of the 11 MB shakespeare.txt inside the terminal, ms. Lower is better.

| run | gterm | alacritty | ghostty | xfce4-terminal |
|---:|---:|---:|---:|---:|
| 1 | 124 | 187 | 257 | 289 |
| 2 | 115 | 196 | 281 | 297 |
| 3 | 131 | 202 | 272 | 297 |
| 4 | 119 | 183 | 245 | 306 |
| 5 | 122 | 214 | 252 | 316 |
| median | **122** | 196 | 257 | 297 |

### Frame rate

DOOM-fire (examples/doomfire, DOOM-fire-zig's output) for 10 s, frames per second. Higher is better.

| run | gterm | alacritty | ghostty | xfce4-terminal |
|---:|---:|---:|---:|---:|
| 1 | 1156 | 1185 | 582 | 672 |
| 2 | 1148 | 1185 | 609 | 677 |
| 3 | 1171 | 1174 | 594 | 672 |
| 4 | 1167 | 1185 | 590 | 679 |
| 5 | 1174 | 1199 | 609 | 659 |
| median | 1167 | **1185** | 594 | 672 |

### Memory, idle

The terminal process's resident set 5 s after start, MB. Lower is better.

| run | gterm | alacritty | ghostty | xfce4-terminal |
|---:|---:|---:|---:|---:|
| 1 | 42.4 | 73.1 | 148.9 | 60.0 |
| 2 | 42.5 | 74.1 | 149.5 | 60.1 |
| 3 | 42.9 | 72.9 | 148.7 | 60.5 |
| 4 | 42.5 | 74.9 | 149.3 | 60.2 |
| 5 | 43.1 | 73.1 | 149.8 | 60.0 |
| median | **42.5** | 73.1 | 149.3 | 60.1 |

### Memory, after cat

The same, after the cat filled the scrollback, MB. Lower is better.

| run | gterm | alacritty | ghostty | xfce4-terminal |
|---:|---:|---:|---:|---:|
| 1 | 46.9 | 113.7 | 160.7 | 62.3 |
| 2 | 47.0 | 113.6 | 160.9 | 64.3 |
| 3 | 47.0 | 113.5 | 160.5 | 62.7 |
| 4 | 47.0 | 113.8 | 159.5 | 61.3 |
| 5 | 47.3 | 114.0 | 161.4 | 62.2 |
| median | **47.0** | 113.7 | 160.7 | 62.3 |

### CPU, idle

CPU time over 3 idle seconds, % of one core. Lower is better.

| run | gterm | alacritty | ghostty | xfce4-terminal |
|---:|---:|---:|---:|---:|
| 1 | 4.0 | 0.0 | 0.3 | 0.0 |
| 2 | 4.0 | 0.0 | 0.3 | 0.0 |
| 3 | 4.0 | 0.0 | 0.3 | 0.0 |
| 4 | 4.3 | 0.0 | 0.7 | 0.0 |
| 5 | 4.0 | 0.0 | 0.7 | 0.0 |
| median | 4.0 | **0.0** | 0.3 | **0.0** |

