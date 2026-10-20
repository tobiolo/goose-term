# Shared settings for the scripts in bin/, inputs/ and scripts/.
# Source it; do not run it. Every path can be set from outside.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export ROOT
export DEPS=${DEPS:-$ROOT/.deps}        # goose and the baselines
export INPUTS=${INPUTS:-$ROOT/.inputs}  # downloaded and generated inputs
export OUT=${OUT:-$ROOT/.out}           # binaries and the results of new runs
export GOOSE=${GOOSE:-$DEPS/goose/build/goose}
export PATH=$HOME/.cargo/bin:$PATH

# The terminal every row emulates, and its scrollback.
export COLS=${COLS:-174}                # vizenc/terminal-benchmark's size
export ROWS=${ROWS:-39}
export HISTORY=${HISTORY:-10000}        # alacritty's default scrollback

# The pinned commits. These are the versions every committed result was measured at.
GOOSE_COMMIT=1e31b6df900d383f1f6af42b7a4bf78a831dc18c
LIBVTERM_COMMIT=9d6d2112335080312ef8c36667fa717ded4f7daf    # neovim/libvterm, tag v0.3.3
ALACRITTY_TERMINAL_VERSION=0.26.0                            # crates.io, with vte 0.15.0
VTEBENCH_COMMIT=ead80032e57dee2e75f0b51f2ea67528647d9944
TERMBENCH_COMMIT=f71121da68fc061dc141dd25ae9b3e14637d2819     # vizenc/terminal-benchmark
DOOMFIRE_COMMIT=eb0631b141b5778eefc6f5767bb45f8974c1be71      # const-void/DOOM-fire-zig

# fetch_repo <dir> <github owner/name> <commit>: a shallow checkout of one commit.
fetch_repo() {
  local dir=$DEPS/$1
  if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD)" = "$3" ]; then return; fi
  rm -rf "$dir"; mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "https://github.com/$2"
  git -C "$dir" fetch -q --depth 1 origin "$3"
  git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
}

log() { echo "[$(date +%H:%M:%S)] $*"; }
