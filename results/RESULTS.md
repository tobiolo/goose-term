5 timed runs after one warm-up, pinned to CPU 2; median wall time, whole process. † = checksums differ from alacritty's.

| input | MB | alacritty | libvterm | goose |
|---|---:|---:|---:|---:|
| doomfire | 29.6 | 137 ms | 193 ms | 139 ms |
| gitlog | 20.3 | 266 ms | 2520 ms | 108 ms |
| shakespeare | 11.2 | 195 ms | 2484 ms | 70 ms |
| vtebench_cursor_motion | 18.1 | 83 ms | 110 ms | 72 ms |
| vtebench_dense_cells | 19.1 | 86 ms | 101 ms † | 94 ms |
| vtebench_light_cells | 16.9 | 86 ms | 248 ms | 16 ms |
| vtebench_medium_cells | 16.8 | 106 ms | 270 ms | 66 ms |
| vtebench_scrolling | 16.8 | 170 ms | 31518 ms | 215 ms |
| vtebench_scrolling_bottom_region | 16.8 | 121 ms | 23166 ms | 149 ms |
| vtebench_scrolling_bottom_small_region | 16.8 | 299 ms | 12248 ms | 140 ms |
| vtebench_scrolling_fullscreen | 16.8 | 195 ms | 1462 ms | 67 ms |
| vtebench_scrolling_top_region | 16.8 | 460 ms | 22985 ms | 147 ms |
| vtebench_scrolling_top_small_region | 16.8 | 279 ms | 13383 ms | 138 ms |
| vtebench_sync_medium_cells | 16.9 | 113 ms | 267 ms | 67 ms |
| vtebench_unicode | 16.9 | 87 ms | 430 ms † | 93 ms |

Peak resident memory (MB; the input itself is read whole into memory by every row):

| input | alacritty | libvterm | goose |
|---|---:|---:|---:|
| doomfire | 31.1 | 30.7 | 32.7 |
| gitlog | 62.4 | 88.3 | 25.9 |
| shakespeare | 53.7 | 79.7 | 17.0 |
| vtebench_cursor_motion | 20.1 | 19.7 | 20.5 |
| vtebench_dense_cells | 21.0 | 20.6 | 22.7 |
| vtebench_light_cells | 19.0 | 18.6 | 20.5 |
| vtebench_medium_cells | 22.8 | 18.8 | 20.9 |
| vtebench_scrolling | 59.0 | 85.0 | 21.2 |
| vtebench_scrolling_bottom_region | 18.8 | 18.4 | 20.6 |
| vtebench_scrolling_bottom_small_region | 18.8 | 18.4 | 20.5 |
| vtebench_scrolling_fullscreen | 59.0 | 84.9 | 32.0 |
| vtebench_scrolling_top_region | 18.8 | 18.5 | 20.6 |
| vtebench_scrolling_top_small_region | 18.8 | 18.4 | 18.5 |
| vtebench_sync_medium_cells | 23.1 | 19.0 | 20.9 |
| vtebench_unicode | 18.9 | 18.6 | 20.7 |

Geometric means, goose against each row, over the inputs where both agree with alacritty:

| against | inputs | speed | peak memory |
|---|---:|---:|---:|
| alacritty | 15 | 1.69x faster | 1.25x less |
| libvterm | 13 | 22.13x faster | 1.40x less |
