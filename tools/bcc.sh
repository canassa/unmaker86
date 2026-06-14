#!/usr/bin/env bash
# bcc.sh — compile a DOS .C source into a real-mode .EXE using Borland C++ 3.1
# (toolchain/bc31) running headless under dosbox-x. The .EXE lands next to the
# source. Output is a 16-bit real-mode DOS program that runs on the zdos core.
#
#   tools/bcc.sh <path/to/SOURCE.C>
#
# Headless flags (-silent -fastlaunch -nogui -exit) + the device-off -set list
# mirror the c-recon relink project's dosbox_run.sh — no display, no audio, runs
# the autoexec and exits. bc31 mounts as D:; INCLUDE/LIB env vars point BCC at
# the headers/libs so a bare `bcc SOURCE.C` compiles + links.
set -e

SRC_C="$1"
[ -f "$SRC_C" ] || { echo "usage: tools/bcc.sh <SOURCE.C>"; exit 1; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BC31="$REPO/toolchain/bc31"
WORK="$(cd "$(dirname "$SRC_C")" && pwd)"
NAME="$(basename "$SRC_C")"
LOG="$(mktemp)"

dosbox-x -silent -fastlaunch -nogui -exit \
    -set "core=dynamic_x86" \
    -set "cycles=max" \
    -set "cputype=pentium_mmx" \
    -set "pcspeaker=false" \
    -set "voodoo=false" \
    -set "scaler=none" \
    -set "aspect=false" \
    -set "vsyncmode=off" \
    -set "ipx=false" \
    -set "serial1=disabled" \
    -set "serial2=disabled" \
    -set "parallel1=disabled" \
    -c "mount c $WORK" \
    -c "mount d $BC31" \
    -c "path d:\\bin;%PATH%" \
    -c "c:" \
    -c "bcc -Id:\\include -Ld:\\lib $NAME > BUILD.LOG" \
    -c "exit" > "$LOG" 2>&1 || true

echo "--- bcc transcript (BUILD.LOG) ---"
tr -d '\r' < "$WORK/BUILD.LOG" 2>/dev/null || echo "(no BUILD.LOG)"
rm -f "$LOG"
