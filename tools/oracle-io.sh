#!/usr/bin/env bash
# oracle-io.sh — the BINARY device-blob ORACLE for the I/O phase (VGA et al.).
#
# Sibling of tools/oracle.sh. Where oracle.sh captures a program's TEXT console
# output + exit code (the DOS-layer goldens), this captures a program that reads
# back guest-observable DEVICE STATE (mode-13h VRAM bytes, the 6-bit DAC palette
# via ports, BDA video fields) and writes that RAW BINARY BLOB to a file on the
# mounted C: drive. dosbox-x is the TRUTH; the captured blob is the committed
# golden <PROGRAM>.expected, which zdos must reproduce byte-identically OFFLINE
# (plans/io-oracle.md §0/§1.2 — capture device state, never rendered pixels).
#
#   tools/oracle-io.sh <path/to/PROGRAM.EXE> [data-file ...]
#
# WHY A SEPARATE SCRIPT (io-oracle.md §1.2): the text path in oracle.sh re-emits
# CRLF and strips a trailing ^Z (correct for CON text, WRONG for a binary blob
# that may contain 0x0D/0x0A/0x1A as real palette/VRAM bytes). This script copies
# the program's output file VERBATIM — binary-safe, no newline/EOF mangling.
#
# How it works (the program writes its own file; no stdout redirect needed):
#   c:\PROG.EXE                          the program fopen(...,"wb")s VGAOUT.BIN
#   copy VGAOUT.BIN -> <STEM>.expected   captured verbatim as the golden
#   if errorlevel N echo N >> CODE.TXT   captures the DOS exit code (ladder)
# The program self-checks and exits non-zero on failure so a broken mint is
# caught; the exit code is recorded in a sidecar <STEM>.exitcode (binary goldens
# can't carry an "exit_code:" header line without corrupting the blob).
#
# PINNED -set flags (determinism, mirroring oracle.sh + USER DECISIONS D1/D2):
#   machine=vgaonly  — D1: plain IBM VGA, no S3 extensions (BaK is plain VGA; this
#                      shrinks the register surface and fixes DAC/CRTC read-backs).
#   xms=false        — same as oracle.sh (zdos defers XMS; keeps EMS in board mode).
#   pcspeaker=false / voodoo=false / scaler=none / aspect=false / vsyncmode=off /
#   ipx + serial + parallel disabled — the proven headless device-off set.
# (D2: sound is register-trace only for v1 — no synthesis is built or pinned here.)
set -e

PROG="$1"
[ -f "$PROG" ] || { echo "usage: tools/oracle-io.sh <PROGRAM.EXE> [data-file ...]"; exit 1; }
shift || true

WORK="$(cd "$(dirname "$PROG")" && pwd)"
NAME="$(basename "$PROG")"           # e.g. VGAINIT.EXE
STEM="${NAME%.*}"                    # e.g. VGAINIT
EXPECTED="$WORK/$STEM.expected"
EXITCODE="$WORK/$STEM.exitcode"
OUT="$WORK/VGAOUT.BIN"               # the fixed blob filename every I/O program uses
CODE="$WORK/CODE.TXT"
LOG="$(mktemp)"

rm -f "$OUT" "$CODE"

# ERRORLEVEL probe ladder (same technique as oracle.sh): `if errorlevel N` is true
# iff code >= N; append each matching N, the host takes the max. I/O programs use
# small codes (0 ok, 1..N self-check failures).
PROBE_CMDS=()
for n in $(seq 1 32); do
    PROBE_CMDS+=( -c "if errorlevel $n echo $n >> CODE.TXT" )
done

# Disk-fill guard: cap any file this shell writes to ~16 MB. A mode-13h blob is
# ~64 KB, so this is generous. Subshell so the limit does not leak to the caller.
(
  ulimit -f 32768
  timeout 120 dosbox-x -silent -fastlaunch -nogui -exit \
      -set "machine=vgaonly" \
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
      -c "$NAME" \
      "${PROBE_CMDS[@]}" \
      -c "exit" > "$LOG" 2>&1 || true
)

rm -f "$LOG"

if [ ! -f "$OUT" ]; then
    echo "oracle-io: program produced no VGAOUT.BIN (did it run? did dosbox-x mount?)" >&2
    exit 1
fi

RET="0"
if [ -f "$CODE" ]; then
    RET="$(tr -d '\r' < "$CODE" | sort -n | tail -1)"
    [ -n "$RET" ] || RET="0"
fi

# The golden is the RAW blob, copied verbatim (binary-safe). The exit code is a
# separate sidecar so the blob stays pure bytes.
cp "$OUT" "$EXPECTED"
printf '%s\n' "$RET" > "$EXITCODE"

rm -f "$OUT" "$CODE"

echo "minted binary golden: $EXPECTED  (exit_code=$RET, $(wc -c < "$EXPECTED") bytes)"
