# Vendored SingleStepTests / 80386 conformance vectors

These are the public 80386 single-step conformance vectors used to validate the
zdos CPU core (`src/cpu/`) against real-hardware-derived per-instruction state.

## Source

- Upstream: <https://github.com/SingleStepTests/80386>

## What is vendored here

- `v1_ex_real_mode/<op>.MOO.gz` — 941 real-mode opcode vector files, binary
  **MOO v1.1** format (spec: <https://github.com/dbalsom/moo>), kept gzipped and
  decompressed in-harness with `std.compress.flate` (offline / reproducible — the
  tests NEVER fetch at runtime, per the determinism rule in `CLAUDE.md`).
- `80386.csv` — per-opcode metadata. The harness uses the `f_umask` column (the
  per-opcode EFLAGS *compare* mask: a 1 bit means "compare this flag", a 0 bit
  means "this flag is architecturally undefined for this opcode — ignore it").
  This implements the D9 undefined-flag policy (spice86 harness design: a
  per-opcode undefined-EFLAGS mask).
- `revocation_list.txt` — hashes of known-bad / unverifiable vectors to skip
  (currently empty upstream apart from the header comment).

## Subsetting (why this is ~19 MB, not ~580 MB)

The raw upstream corpus is ~579 MB: each opcode file contains ~10,000 vectors,
and the bulk of each vector is a per-test `CYCL` bus-cycle trace. zdos
**deliberately does not assert bus-cycle counts** against vectors (`plans/cpu.md`
decision **D8**: assert final register/flag/memory STATE, not the vectors' bus
timing — zdos has its own synthetic cycle ledger). So the vendored files are
processed by `strip_cycl.zig`:

1. The `CYCL` chunk is dropped (every asserted field — registers, flags, memory,
   name, bytes, hash — is preserved byte-for-byte; nothing asserted is lost).
2. Each opcode file is capped at **100 vectors** (covering ALL 941 opcodes).

100 vectors/opcode × 941 opcodes = ~94,000 conformance vectors — ample coverage
of every real-mode opcode, while keeping the repo a sane size. This is a
documented faithful subset, **not** a way to hide failures: the harness runs
every vendored vector and reports every failure.

To reproduce exactly (or to vendor the FULL corpus), run `./fetch.sh`
(`CAP=0 ./fetch.sh` keeps all ~10,000 vectors/opcode — ~318 MB stripped).

## Reproduce

```sh
cd src/cpu/testdata/80386
./fetch.sh            # default: CYCL-stripped, 100 vectors/opcode (~19 MB)
CAP=0 ./fetch.sh      # full corpus, CYCL-stripped (~318 MB)
```
