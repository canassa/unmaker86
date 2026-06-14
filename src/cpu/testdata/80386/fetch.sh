#!/usr/bin/env bash
# Reproducible, offline-after-fetch vendoring of the SingleStepTests/80386
# real-mode conformance vectors + support files.
#
# Source: https://github.com/SingleStepTests/80386
# LICENSE: software is MIT; the DATA FILES (the *.MOO.gz vectors, 80386.csv,
#          revocation_list.txt) are PUBLIC DOMAIN. Vendoring them into zdos is
#          license-safe (no GPL concern). See README.md in this directory.
#
# Run from this directory:  ./fetch.sh
# It downloads:
#   - 941 v1_ex_real_mode/*.MOO.gz  (kept gzipped; decompressed in-harness)
#   - 80386.csv            (per-opcode metadata incl. undefined-flag columns)
#   - revocation_list.txt  (known-bad vector hashes to skip)
#
# The files are committed to the repo so tests NEVER fetch at runtime
# (determinism / offline rule). This script only needs re-running to refresh.

set -euo pipefail
cd "$(dirname "$0")"

BASE="https://raw.githubusercontent.com/SingleStepTests/80386/main"
API="https://api.github.com/repos/SingleStepTests/80386/git/trees/main?recursive=1"

mkdir -p v1_ex_real_mode

echo "Fetching support files..."
curl -fsSL --max-time 60 -o 80386.csv "$BASE/80386.csv"
curl -fsSL --max-time 60 -o revocation_list.txt "$BASE/revocation_list.txt"

echo "Resolving the v1_ex_real_mode file list from the GitHub tree API..."
curl -fsSL --max-time 120 "$API" \
  | grep -o '"path": *"v1_ex_real_mode/[^"]*"' \
  | sed 's/.*v1_ex_real_mode\///;s/"//' > /tmp/zdos_realmode_files.txt
count=$(wc -l < /tmp/zdos_realmode_files.txt)
echo "Found $count vector files."

echo "Downloading vectors to a temp dir (parallel)..."
RAW=$(mktemp -d)
xargs -P 16 -I {} curl -fsSL --max-time 60 -o "$RAW/{}" \
  "$BASE/v1_ex_real_mode/{}" < /tmp/zdos_realmode_files.txt

# The raw corpus is ~579 MB: each opcode file holds ~10,000 vectors, and most of
# every test is a CYCL bus-cycle trace that zdos does NOT assert (plans/cpu.md
# D8: assert state, not bus-cycles). We vendor a repo-friendly subset:
#   - strip the CYCL chunk (state preserved byte-for-byte)
#   - cap each opcode file at CAP vectors (covers ALL 941 opcodes)
# This yields ~19 MB while keeping every opcode and every asserted field.
# To vendor the FULL corpus instead, set CAP=0 (warning: ~318 MB stripped).
CAP="${CAP:-100}"

echo "Building the strip tool..."
zig build-exe strip_cycl.zig -O ReleaseFast

echo "Stripping CYCL + capping at $CAP vectors/opcode..."
for f in "$RAW"/*.MOO.gz; do
  ./strip_cycl "$f" "v1_ex_real_mode/$(basename "$f")" "$CAP"
done
rm -rf "$RAW" strip_cycl

echo "Done. $(ls v1_ex_real_mode | wc -l) files in v1_ex_real_mode/ ($(du -sh v1_ex_real_mode | cut -f1))."
