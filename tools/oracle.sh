#!/usr/bin/env bash
# oracle.sh — the EXTERNAL ORACLE. dosbox-x (a mature, correct DOS) is the truth.
#
# Runs a real-mode DOS program under dosbox-x HEADLESS, captures its console
# output + exit code (ERRORLEVEL), and writes a committed golden file
#     <program>.expected
# next to the EXE. zdos's `test-oracle` later asserts it reproduces this golden
# OFFLINE (the golden is vendored, mirroring the CPU's conformance vectors).
#
#   tools/oracle.sh <path/to/PROGRAM.EXE> [data-file ...]
#
# This is a MINT step: run ONCE when adding a corpus program, NOT at
# `zig build test` time (dosbox-x is the truth-source, not a test dependency).
#
# How it works (DOS console output does NOT reach host stdout under headless
# dosbox-x, so we redirect the DOS program's stdout to a file on the mounted
# drive and read it back, then capture ERRORLEVEL into a second file):
#   c:\PROG.EXE [args] > OUT.TXT          captures the program's CON output
#   if errorlevel N echo N > CODE.TXT     captures the DOS exit code
#
# (dosbox-x's internal shell does NOT expand %ERRORLEVEL% in `echo`, but it DOES
# implement `if errorlevel N` = "exit code >= N". We descend a fixed ladder of
# probe levels and record the first/highest that matches; corpus exit codes are
# small (0, 7, ...), so a short ladder suffices.)
#
# The headless flags (-silent -fastlaunch -nogui -exit) + the device-off -set
# list mirror tools/bcc.sh (the proven c-recon recipe): no display, no audio,
# runs the autoexec and exits. The program's directory mounts as C:.
#
# CANONICAL ORACLE SCOPE — xms / ems pinning (determinism vs zdos's scope):
#   xms=false  — PINNED. dosbox-x defaults xms=true (dosbox.cpp:4619), which
#     installs the XMS multiplex handler so INT 2Fh AX=4300 returns AL=0x80
#     ("XMS present"). zdos DEFERS XMS entirely (plans/dos-coverage-gaps.md §4:
#     our target class is plain real-mode + EMS, no XMS/DPMI/extender), so the
#     faithful answer is "not installed" (AL!=0x80). Pinning xms=false makes the
#     reference oracle match zdos's deferred-XMS scope: with it off, dosbox-x's
#     multiplex_xms is never registered (xms.cpp:771) and AX=4300/4310 fall
#     through INT2F_Handler untouched (AL=0x00) — exactly zdos's answer.
#   ems  — NOT pinned (left at dosbox-x's default "true", dosbox.cpp:4829). zdos
#     IMPLEMENTS EMS (INT 67h AH=40-48, ems.zig). NOTE: turning xms OFF has a
#     deliberate side effect on EMS — with xms=false and ems=true, dosbox-x
#     DOWNGRADES its EMS from "mixed" mode to BOARD mode (ems.cpp:1845: "EMS
#     changed to board mode ... because XMS is not enabled"). Board mode is a
#     pure hardware-EMS-board model with NO VCPI and NO OS system handle — which
#     is EXACTLY zdos's BaK-target scope ("EMS via a host INT 67h handler, no
#     EMM386/V86", CLAUDE.md). So board mode is the CORRECT canonical reference,
#     not a regression. Consequence on the re-minted goldens:
#       EMSINFO  free=total 03A4 -> 03BC  (+24 pages freed by dropping the
#                                          system handle)
#       EMSCOUNT base 0001->0000, sumpages 0020->0008 (no system handle counted)
#     EMSMAP/EMSSAVE/MEMALLOC/FARHEAP are UNCHANGED (they don't depend on the
#     system handle or the EMS total). zdos's ems.zig is matched to board mode
#     (REPORTED_PAGES=0x3BC, no system handle) so it reproduces these goldens.
#
# Disk-fill hazard: a runaway program could fill the host disk via the redirect.
# We bound it with `ulimit -f` (max file size, 512-byte blocks) and `timeout`.
set -e

PROG="$1"
[ -f "$PROG" ] || { echo "usage: tools/oracle.sh <PROGRAM.EXE> [data-file ...]"; exit 1; }
shift || true

WORK="$(cd "$(dirname "$PROG")" && pwd)"
NAME="$(basename "$PROG")"           # e.g. FILEIO.EXE
STEM="${NAME%.*}"                    # e.g. FILEIO
EXPECTED="$WORK/$STEM.expected"
OUT="$WORK/OUT.TXT"
CODE="$WORK/CODE.TXT"
LOG="$(mktemp)"

# A corpus program may take fixed command-line arguments. Programs whose golden
# depends on argv encode them in a sidecar "<STEM>.args" file next to the EXE so
# the oracle and the zdos harness pass the IDENTICAL command tail. (HELLO etc.
# have no args -> empty tail.)
ARGS=""
[ -f "$WORK/$STEM.args" ] && ARGS="$(tr -d '\r\n' < "$WORK/$STEM.args")"

# A console-INPUT corpus program reads from stdin (DOS handle 0). Its golden
# depends on EXACTLY which bytes the keyboard/stdin produces, so those bytes are
# committed in a sidecar "<STEM>.in" next to the EXE. When present, the oracle
# runs the program under dosbox-x with stdin REDIRECTED from that file
# (`PROG.EXE < IN.TXT > OUT.TXT`): DOS handle 0 then reads the file's bytes
# verbatim (a redirected localFile, GetInformation()==0 => never reports
# not-ready/EOF via bit 6 — see drive_local.cpp LocalFile::GetInformation). The
# zdos harness preloads the IDENTICAL bytes as the machine's scripted stdin, so
# the run is apples-to-apples. We copy the sidecar to IN.TXT on the mounted C:
# (8.3 name) so the dosbox-x shell can open it for redirection.
REDIR_IN=""
IN_TXT="$WORK/IN.TXT"
rm -f "$IN_TXT"
if [ -f "$WORK/$STEM.in" ]; then
    cp "$WORK/$STEM.in" "$IN_TXT"
    REDIR_IN="< IN.TXT"
fi

rm -f "$OUT" "$CODE"

# Build the ERRORLEVEL probe ladder. `if errorlevel N` is true iff code >= N.
# Probe ASCENDING 1..255 and APPEND each matching N to CODE.TXT; the HIGHEST
# number that appears is exactly the exit code (the host takes the max below).
# If the program exits 0 nothing matches and CODE.TXT is never created -> 0.
# (dosbox-x's shell does not support nested `if`; `if errorlevel 0` is
# always-false in its shell; and repeated OVERWRITE of one file across commands
# truncates unreliably -- so APPEND + host-side max over 1..255 with a
# "missing file => 0" default is the portable way to read the code back.)
PROBE_CMDS=()
for n in $(seq 1 255); do
    PROBE_CMDS+=( -c "if errorlevel $n echo $n >> CODE.TXT" )
done

# Disk-fill guard: cap any file this shell (incl. the redirect) writes to ~16 MB
# (32768 * 512-byte blocks). Subshell so the limit does not leak to the caller.
(
  ulimit -f 32768
  timeout 120 dosbox-x -silent -fastlaunch -nogui -exit \
      -set "core=dynamic_x86" \
      -set "cycles=max" \
      -set "cputype=pentium_mmx" \
      -set "xms=false" \
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
      -c "c:" \
      -c "$NAME $ARGS $REDIR_IN > OUT.TXT" \
      "${PROBE_CMDS[@]}" \
      -c "exit" > "$LOG" 2>&1 || true
)

rm -f "$LOG"

if [ ! -f "$OUT" ]; then
    echo "oracle: program produced no OUT.TXT (did it run? did dosbox-x mount?)" >&2
    exit 1
fi

# DOS writes CRLF + an EOF (0x1A) on some redirects; keep CRLF (zdos's CON
# emits CRLF too — see borland_test.zig EXPECTED) but strip a trailing ^Z.
RET="0"
if [ -f "$CODE" ]; then
    # CODE.TXT holds every matching `if errorlevel N` -> the exit code is the max.
    RET="$(tr -d '\r' < "$CODE" | sort -n | tail -1)"
    [ -n "$RET" ] || RET="0"
fi

# The golden is a self-describing record: a header line with the exit code,
# then a marker, then the verbatim console bytes. The zdos harness parses the
# same format. Keeping the raw bytes (incl. CRLF) makes it a faithful oracle.
{
    printf 'exit_code: %s\r\n' "$RET"
    printf -- '--- output ---\r\n'
    # strip a single trailing DOS EOF (0x1A) if present
    sed 's/\x1a$//' "$OUT"
} > "$EXPECTED"

rm -f "$OUT" "$CODE" "$IN_TXT"

echo "minted golden: $EXPECTED  (exit_code=$RET, $(wc -c < "$EXPECTED") bytes)"
