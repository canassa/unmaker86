# zdos bus / memory module — implementation plan (`src/bus/`)

This is the literal, ordered build plan for `src/bus/`: the **single memory choke point** for the
emulator — guest RAM plus physical-address region dispatch plus port I/O dispatch — in **Zig 0.16**.
The bus is the **bottom of the module graph alongside the CPU**: it imports nothing outside `std`,
and a concrete `Bus` struct is instantiated into `Cpu(comptime Bus)` so the per-instruction memory
path inlines to zero cost (no runtime vtable).

**Scope is real-mode physical memory + ports.** Protected-mode paging / TLB / page-fault handling is
the CPU's concern and is **deferred** (CPU plan D5). The bus deals only in **physical addresses**
(the CPU already did logical→linear→physical and decomposed wide accesses on its linear side) plus a
**16-bit I/O port space**. It is part of the reproducibility surface: it must be a **pure function of
(bus state, address, value)** with no host state, no host time, and a deterministic fill for
unmapped reads.

**Why this scope:** the bus is the path to the **Betrayal at Krondor (1993)** v1 target (`CLAUDE.md`
§"First target"). BaK is a real-mode 386 game (1 MiB RAM + ~1 MiB EMS, DOS 5.0, VGA, mouse) with no
DOS extender, no protected mode, no paging. The bus's job is the conventional/UMA/ROM memory map,
the A20 gate, the VGA framebuffer MMIO window (device impl out of scope — only the registration
seam), the I/O port dispatch every device hangs off, and the generic MMIO seam EMS registers through
(EMS is an ordinary MMIO device, B8 — no EMS-specific bus surface). **Devices
(PIT/PIC/VGA/SB), DOS, BIOS, EMS service logic are *other modules*** wired in by `src/machine/`; the
bus imports none of them.

**Read before starting (source of truth — do not work from memory):**
- `CLAUDE.md` — prime directive (determinism: byte-identical state at cycle N), ground rule (no
  mocks/stubs/fakes; flag structural problems, never bypass), module graph (bus is bottom, imports
  nothing), **allocation strategy** (guest RAM = one fixed up-front block, indexed directly, never
  per-op), the **First target: Betrayal at Krondor** section.
- **`src/cpu/bus.zig` — the comptime contract the bus MUST satisfy verbatim**, plus the `TestBus`
  reference implementation in that same file (the real bus must be drop-in compatible with the shape
  `TestBus` already proves against the CPU).
- `plans/cpu.md` — Phase 0 (the fixed Bus contract + the DECIDED Bus error model), and the boundary
  items: A20 ownership is the bus's (CPU passes the full **unmasked** `(sel<<4)+offset`),
  wide-access decomposition happens on the **CPU's linear side** (the bus wide accessors may assume
  single-region), the deterministic unmapped fill, the **0xFF floating-bus** port-read convention,
  and the **fixed ascending sub-access order**. (See cpu.md Phase 0 "Wide-access decomposition",
  "DECIDED (Bus error model)", and Phase 8 "A20 / 1 MiB-wrap test" + "port-input convention (0xFF
  floating bus)".)
- `.claude/skills/zig-developer/SKILL.md` + `memory-and-performance.md` — data-layout/allocation
  doctrine (no per-op alloc, allocate up front, prefer dense-int-keyed tables/indexes over pointers,
  comptime size locks); `references/zig/lib/std/` is the gold standard for exact 0.16 signatures —
  grep it, don't write Zig from memory.
- Reference memory models (algorithmic detail, two designs to weigh):
  `references/dosbox-staging/src/hardware/memory.cpp` + `src/cpu/paging.h` — the **PageHandler
  hierarchy + software TLB of host pointers** (`PageHandler` virtuals `readb/writeb`, `GetHostReadPt`
  fast path; `IllegalPageHandler` returns `0xff`; `ROMPageHandler` logs+ignores writes;
  `MEM_SetPageHandler(page,count,handler)` registration). `references/dosbox-x/src/hardware/memory.cpp`
  (same lineage). `references/spice86/.../Memory/Memory.cs` + `Memory/Ram.cs` + `Memory/A20Gate.cs`
  — the **per-region `IMemoryDevice[]` dispatch** model (A20 `TransformAddress` applied up-front,
  `RegisterMapping(start,size,device)` seam, A20 masks `0xFFFFF`/`0x1FFFFF`, HMA end `0x10FFEF`).

**Notation:** every actionable step is a `[ ]` checkbox. The **DECISIONS** block records the design
choices (B1–B12) with a recommendation + rationale per the ground rule (flag, don't silently decide).
Items marked **(determinism-critical)** are part of the reproducibility surface and must be exact.

> **Proportionality note.** The bus is *much* simpler than the CPU: no instruction set, no flags, no
> fault unwind. This plan is deliberately compact — 4 phases + a milestone section. Do not pad it.

---

## DECISIONS (all accepted — recommendations adopted)

- [x] **B1 — Region dispatch model: a hybrid "host-pointer fast path + per-region handler" routed by
      a flat per-page table. RECOMMENDED.** Weighing the two references:
  - DOSBox: `PageHandler*` array indexed by 4 KiB page, each handler is a vtable
    (`readb/writeb/...` + `GetHostReadPt`); RAM/ROM/MMIO/unmapped are distinct handler subclasses; a
    software TLB caches host pointers for the RAM fast path. Maximum flexibility, but the per-access
    vtable virtual call is exactly the runtime indirection zdos's `comptime Bus` design exists to
    avoid, and the full 1M-entry TLB is heavy.
  - spice86: a per-**byte** `IMemoryDevice[]` indexed by address, with `Read(addr)/Write(addr,v)`
    per device. Simple and faithful, but a per-byte array over 1 MiB+ and a virtual call on *every*
    byte access is both memory-heavy and slow — and per-byte granularity is finer than any real
    decode needs.
  - **zdos recommendation:** a **flat page table over the ≤ ~1.1 MiB real-mode physical space**
    (`page_kind: [N_PAGES]PageKind` where `PageKind = enum { ram, rom, mmio, unmapped }`, 4 KiB
    pages, ~272 entries for 1 MiB + HMA — trivially small, one cache-friendly array). The hot path:
    A20-mask → page index → if `.ram` (the overwhelming common case incl. all instruction fetch and
    stack) index the one fixed RAM block **directly** (no call, no pointer chase); `.rom` reads hit
    RAM directly too (ROM is backed by the same block, see B4); only `.mmio`/`.unmapped` dispatch to
    a handler. This keeps the determinism-friendly, branch-predictable hot path the CPU's
    comptime-Bus design wants (memory-and-performance.md §5d dense-int-keyed table), takes DOSBox's
    *idea* (per-page kind + host-pointer fast path) without its per-access vtable, and takes
    spice86's *registration model* without its per-byte array. **Rationale:** perf doctrine (no
    per-op indirection on the RAM fast path), determinism (a plain array lookup is a pure function),
    and the comptime-Bus style (handler dispatch is the rare path, not the hot path).
- [x] **B2 — Guest RAM = ONE fixed, page-aligned, up-front allocation indexed directly.** Per
      CLAUDE allocation strategy + memory-and-performance.md. A single `ram: []align(page) u8` of a
      fixed real-mode size, allocated once at `Bus.init`, freed at `deinit`, zero-filled
      deterministically. The RAM/ROM fast paths index it directly; **no per-op alloc/free ever**.
      **(determinism-critical: deterministic zero init, CLAUDE constraint #5.)**
- [x] **B3 — RAM block size/layout for the real-mode map.** The classic 1 MiB physical map is:
      conventional `0x00000–0x9FFFF` (640 KiB RAM), the UMA `0xA0000–0xBFFFF` (VGA framebuffer / MMIO
      window), `0xC0000–0xFFFFF` (option ROM / BIOS), and the **HMA wrap region** above 1 MiB up to
      `0x10FFEF` reachable from real mode with A20 enabled (`FFFF:FFFF` = `0x10FFEF`). **RECOMMENDED:
      allocate a single contiguous `0x110000`-byte block (1 MiB + 64 KiB)** — identical to
      `TestBus.flat_size` (`0x110000`) so the real bus matches the contract surface the CPU already
      validates against. The HMA (`0x100000–0x10FFEF`) is backed by the same block so A20-enabled
      real-mode wrap accesses land in real storage. BaK's ~1 MiB conventional + EMS-via-page-frame
      fits; **EMS backing store is owned by the EMS device module, not this block (B8).**
      **DECIDED:** size the RAM slab to `0x110000` (1 MiB + HMA); XMS/extended RAM is deferred (BaK
      uses EMS, not XMS) — a later growth of this block. **CRITICAL OOB FIX — slab size ≠ page-kind
      table size.** The page-kind table must cover the **FULL A20-mask ceiling**
      (`0x200000 >> 12 = 0x200` = **512 pages**), not the slab. Pages `[0x110000, 0x1FFFFF]` default
      to `.unmapped` (return the `0x00` fill — like DOSBox's illegal-page handler — and **never an OOB
      index**). The RAM/ROM fast path therefore **bounds-checks the index against the slab
      (`< 0x110000`), NOT against the mask**: the CPU's unreal-mode 32-bit offsets can A20-mask to
      addresses inside the mask ceiling yet beyond the slab, which would index out of bounds if the
      check used the mask. Mismatched addresses resolve via the page-kind table to `.unmapped`.
- [x] **B4 — ROM write behavior: writes are silently ignored (no fault), reads hit backing RAM.**
      Both references agree: DOSBox `ROMPageHandler` logs the write and discards it; spice86 backs ROM
      with RAM that simply isn't written by the guest. **RECOMMENDED: ROM regions are pages marked
      `.rom` in the page table; reads index the backing RAM block directly (same fast path as RAM);
      writes are dropped (optionally counted in a debug build for the API server, never faulted).**
      Rationale: real hardware does not fault on a write to ROM in real mode, and the bus contract
      (`writePhys*` returns `void`, cpu.md "DECIDED Bus error model") has no way to signal a fault —
      faults are the CPU's segmentation concern, not the bus's. **DECIDED:** drop-and-count behind a
      comptime debug flag so the MCP server can surface accidental ROM writes; the count must NOT
      affect emulated state (determinism).
- [x] **B5 — A20 representation: a single `u32` address mask, ANDed into every incoming physical
      address; DISABLED at power-on. DECIDED (reversed).** A20 is **off at power-on** (`a20_mask =
      0x0F_FFFF`); the BIOS/machine enables it via `setA20(true)` during POST. Rationale: real
      hardware powers on with A20 off; both references model this — DOSBox `InitA20` forces it
      disabled, and spice86 field-inits its `A20Gate` disabled. **Masking semantics:** A20-off forces
      **only bit 20** to zero — `addr & ~@as(u32, 0x100000)` (i.e. mask `0x0F_FFFF` over the low
      21-bit range, but it does **NOT clamp bits 21+**). Addresses above the addressable range are
      handled by the **page-kind table** (→ `.unmapped` / fill, B3), never by mask-clamping. So
      `mask = enabled ? 0x1F_FFFF : 0x0F_FFFF` is the *low-21-bit* form; the wide-access slow path
      must **re-apply A20 masking per byte** so a word straddling the 1 MiB seam wraps correctly
      (spice86 re-masks per byte). One branch-free `phys & a20_mask` at the top of every byte access.
      The CPU passes the **full unmasked** `(sel<<4)+offset` so the bus is the sole owner of A20
      (cpu.md Phase 8 A20 test). **(determinism-critical.)**
- [x] **B6 — Port dispatch: a dense `[65536]u8` per-port handler-index table + a small handler array.
      DECIDED.** The I/O space is 16-bit (64 K ports). A dense **`u8`** index table over 64 K entries
      (`[65536]u8`, **64 KiB**, defaulting to the "unmapped" handler index `0`) is ample for any real
      device count — small, O(1) dispatch, no hashing, deterministic iteration-order-free. Devices
      register a contiguous or sparse set of ports → fill the index table with their handler slot.
      **The port table is a separate allocation / lives at the COLD TAIL of the `Bus` struct, NOT
      inline among the hot fields** (it is never touched by the RAM fast path). Weighed against a
      hashmap (spice86-style map): a map adds hashing cost on the hot OUT/IN path and its iteration
      order is a determinism footgun (CLAUDE constraint #5). **Rationale:** memory-and-performance.md
      §5d (dense-int-keyed table over a map), determinism (no unordered container on a state path),
      O(1).
- [x] **B7 — Unmapped defaults are deterministic constants. RECOMMENDED.** Unmapped **memory read**
      returns a fixed fill byte; unmapped **port read** returns `0xFF` (the floating-bus convention
      DOSBox `IllegalPageHandler` and the CPU's ProcessorTests port convention both use — cpu.md M3
      "port-input convention (0xFF floating bus)"). Unmapped **writes** (memory or port) are dropped.
      **DECIDED fill values:** memory fill = **`0x00`** (matches `TestBus.fill = 0` so the real bus
      and the contract surface agree, and matches the deterministic zero RAM init); port read =
      **`0xFF`**. **(determinism-critical: CLAUDE constraint #5 — never return garbage.)**
- [x] **B8 — EMS is an ordinary MMIO device, NOT a bespoke bus API. DECIDED (reworked).** BaK needs
      EMS, but the bus needs **ZERO EMS-specific surface**. **DELETE** any `mapEmsPage` entry point and
      any bus-owned EMS backing block. The standard LIM EMS page frame is a 64 KiB window in the UMA
      (typically `0xE0000`, 4 × 16 KiB pages); it is registered through the **generic MMIO seam**: the
      machine calls `mapMmio(frame_phys, 0x10000, ems_handler)` exactly once. The `MemHandler` context
      is the **EMS manager** (in `src/dos`/`src/bios`), which **owns the EMS backing store** and
      performs page remaps *internally* by swapping which slice its handler points at (and, for the
      host-pointer fast path, which host pointer `getHostPtr` returns — B11). spice86 does exactly
      this: `EmmRegister : IMemoryDevice`, and a remap is an internal pointer swap. The EMS backing
      block's deterministic zero-init **is** determinism-critical, but it lives in the EMS module, not
      the bus. INT 67h service logic also lives in `src/dos`/`src/bios`. **Flag clearly: nothing
      EMS-specific is in this module.**
- [x] **B9 — Bus does NOT charge cycles. DECIDED (re-stated, from cpu.md).** The CPU owns the cycle
      ledger; the bus is timing-neutral. The bus must, however, never introduce nondeterminism (no
      host time, no RNG, no thread/env reads, no uninitialized reads). Asserted in Phase 4.
- [x] **B10 — Contract single source of truth: shared leaf module, no hand-copied mirror. DECIDED.**
      Hoist `assertBusContract` (currently in `src/cpu/bus.zig`, lines 16–29) into a **shared leaf
      module both `cpu` and `bus` import** — e.g. `src/abi/bus_contract.zig` (pick a name) — keeping
      the module graph **acyclic** (neither `cpu` nor `bus` imports the other; both import the leaf).
      Put `comptime { contract.assertBusContract(Bus); }` in `src/bus/bus.zig` itself so
      `zig build test-bus` catches contract drift at the bus's own layer. **DROP** the plan's earlier
      "hand-copied byte-for-byte mirror" fallback — a duplicated signature check is a drift vector, the
      exact thing this avoids. **Rationale:** one canonical contract, verified identically on both
      sides, no duplication. Note this entails **relocating `assertBusContract`** during
      implementation (a small `src/cpu/bus.zig` edit + the new leaf module).
- [x] **B11 — MMIO `MemHandler` is width-aware + host-pointer-capable. DECIDED.** Replace the
      byte-only handler with explicit per-width read/write methods: `read8/read16/read32` and
      `write8/write16/write32` (with a **documented byte-decompose fallback** when a handler only
      implements the byte methods — matching the port side, B11/Phase 4, and DOSBox `PageHandler`'s
      `readb/readw/readd`). Real VGA register writes are width-sensitive, so width methods are required
      for faithfulness. **ALSO add an optional host-pointer escape:** `getHostPtr(ctx, page) ?[*]u8`
      (like DOSBox `GetHostReadPt`) so RAM-like MMIO stays on the **direct-index fast path** instead of
      a per-access vtable call — specifically the **VGA framebuffer at `0xA0000`** (the hottest MMIO in
      a VGA game) and the **EMS frame** (B8). When `getHostPtr` returns non-null for a page, the bus
      indexes that pointer directly; when null, it falls to the per-width vtable methods. **Rationale:**
      faithful width-sensitive MMIO + keeps the two RAM-like MMIO hot spots off the vtable.
- [x] **B12 — Serializable bus state / handlers-by-ID. DECIDED (determinism, CLAUDE #6).** The bus
      must support **snapshot → restore → byte-identical**. Handlers are referenced by **stable integer
      IDs assigned in a fixed registration order**, NEVER by host pointer (pointers are ASLR-varying /
      unsnapshotable — CLAUDE #5). The page-kind and port index tables store **integer handler IDs**;
      the machine **re-binds IDs → handlers on restore**. Split state into:
  - **(a) config the machine replays on restore** (not in the snapshot): handler registrations
    (ID assignment order), ROM images, the MMIO/port mappings the machine installs at init.
  - **(b) emulation state captured IN the snapshot** (enumerated): the **RAM slab bytes**, the
    **A20 mask**, the **mutated page-kind table** (runtime-mutated by `mapMmio`/`unmapRegion`/EMS
    remaps), the **handler-ID index tables** (page + port), and **any device-side state** (e.g. the
    EMS manager's backing store + which slice each frame points at — owned by the device module, not
    the bus).
  **Rationale:** reproducibility regression test (CLAUDE #6) requires a populated bus to round-trip
  byte-identical with handlers re-bound by ID, never by pointer.

> **Boundary reconciliation (with the CPU's existing contract — no drift):**
> - **A20:** the CPU passes the **full unmasked** `(sel<<4)+offset`; the bus applies `phys &
>   a20_mask` (B5) **per byte**, masking only bit 20 when A20 is off (no clamp of bits 21+).
>   **A20 is OFF at power-on; the BIOS enables it during POST.** `FFFF:FFFF → 0x10FFEF` with A20 on;
>   with A20 off the same access wraps to `0x000FEF`. The bus is the **sole** A20 owner — cpu.md's A20
>   test asserts the CPU sends unmasked addresses, this plan implements the masking.
> - **Wide accesses:** the CPU decomposes 16/32-bit accesses on its **linear** side into the fixed
>   **ascending** sub-byte order BEFORE calling the bus (cpu.md Phase 0 "Wide-access decomposition").
>   Therefore the bus's `readPhys16/32` / `writePhys16/32` may **assume a single region** and are
>   free to take the fast path when the (already-A20-masked) address lands wholly in RAM. **This plan
>   defines what the bus guarantees for a wide access that nonetheless straddles a region boundary**
>   (e.g. last RAM byte at `0x9FFFF` + first MMIO byte at `0xA0000`): the bus's wide accessor falls
>   back to **per-byte dispatch in the same fixed ascending order** so each byte routes to its own
>   region — never reading past a region with a stale base pointer. This keeps the contract honest
>   (no silent cross-region corruption) while keeping the common single-region case branch-light.
>   (See Phase 2 for the exact split predicate.)
> - **Unmapped fill / port default:** B7 — `0x00` memory fill (matches `TestBus.fill`), `0xFF` port
>   read (matches the CPU's ProcessorTests port convention). Ownership is the **bus's** for both.
> - **Error model:** `readPhys*`/`writePhys*` never fail (cpu.md "DECIDED Bus error model"); the bus
>   returns the deterministic fill / drops the write rather than signalling. Faults are CPU-side
>   segmentation only.

---

## Phase 0: Module skeleton, contract conformance, build wiring

Goal: a compiling `src/bus/` Zig module exposing a concrete `Bus` struct that satisfies the CPU's
`assertBusContract` verbatim, with its own test step. **Done when** `zig build` and `zig build
test-bus` pass, the module imports nothing outside `std`, and `Cpu(Bus)` compiles (the comptime
contract is satisfied).

- [x] Create the file split under `src/bus/` (one responsibility per file):
  - [x] `bus.zig` — the `pub const Bus = struct { ... }` concrete type: owns guest RAM, the page-kind
        table (B1), the A20 mask (B5), the port dispatch table (B6), and the handler registries.
        Exposes the **12 contract methods** (`readPhys8/16/32`, `writePhys8/16/32`, `portIn8/16/32`,
        `portOut8/16/32`) plus the machine-facing registration API (Phase 3). Module root.
  - [x] `memmap.zig` — the real-mode physical memory map constants (B3): conventional / UMA / ROM /
        HMA boundaries, page size, page count, the `PageKind` enum, and the default page-kind layout.
  - [x] `regions.zig` — region/page dispatch: page-index helpers, the width-aware + host-pointer
        `MemHandler` interface for MMIO (the registration seam, B11; EMS is just an MMIO device, B8),
        the unmapped/ROM/MMIO routing (B1, B4, B7), handler-ID tables (B12).
  - [x] `ports.zig` — the port dispatch table + `PortHandler` interface + register/dispatch + the
        unmapped `0xFF` default + the 16/32-bit single-handler width dispatch (B6, B7; Phase 4).
  - [x] `a20.zig` — the A20 mask representation + `setA20(enabled)` + `mask(phys)` (B5). (Tiny; keep
        separate so the masking is the single documented owner.)
  - [x] `bus_test.zig` — test root that `@import`s all `_test` files.
  - [x] `ram_test.zig`, `regions_test.zig`, `a20_test.zig`, `ports_test.zig`, `determinism_test.zig`
        — per-area tests (Phase 4). (Plus `integration_test.zig`, built as a separate artifact.)
- [x] **Build wiring** (mirror the CPU's wiring in `build.zig`, verified APIs `b.addModule`,
      `b.createModule`, `b.addTest`, `b.addRunArtifact`, `b.step`):
  - [x] `const bus_mod = b.addModule("bus", .{ .root_source_file = b.path("src/bus/bus.zig"),
        .target = target, .optimize = optimize });` — exposes the bus as an importable module (the
        machine will `addImport("bus", bus_mod)` and instantiate `Cpu(Bus)`).
  - [x] A dedicated test step `b.step("test-bus", "Run bus unit tests")` over a `b.addTest` rooted at
        `src/bus/bus_test.zig`; wire it into the top-level `test` step
        (`test_step.dependOn(&run_bus_tests.step)`), alongside the existing `test-cpu`. (The M0
        integration test is a SEPARATE artifact because it imports the `cpu`+`bus` modules whose roots
        can't also live in the unit-test root module; both are wired into `test-bus` and `test`.)
- [x] **Contract conformance via a shared leaf module (B10 — no drift, no mirror; the load-bearing
      gate):**
  - [x] **Hoist `assertBusContract` into a shared leaf module** both `cpu` and `bus` import — e.g.
        `src/abi/bus_contract.zig` (pick a name). Relocate it out of `src/cpu/bus.zig` (lines 16–29)
        and have `src/cpu/bus.zig` import + re-export it (small edit). The module graph stays
        **acyclic**: `cpu` and `bus` each import the leaf; neither imports the other.
  - [x] In `src/bus/bus.zig`, `const contract = @import("bus_contract");` (the leaf) and add
        `comptime { contract.assertBusContract(Bus); }` so **`zig build test-bus`** verifies the real
        bus against the **exact same** `assertBusContract` the CPU compiles against — contract drift is
        caught at the bus's own layer, not deferred to a machine test. **DO NOT** hand-copy a
        byte-for-byte signature mirror (the dropped fallback) — duplication is itself a drift vector.
        A machine-level `Cpu(Bus)` instantiation smoke test may *additionally* exist, but the leaf
        comptime assertion is the authoritative gate.
  - [x] Confirm every method signature matches the contract EXACTLY: `fn (*Bus, u32) u8/u16/u32`
        for reads, `fn (*Bus, u32, vT) void` for writes, `fn (*Bus, u16) u8/u16/u32` for `portIn*`,
        `fn (*Bus, u16, vT) void` for `portOut*`. No drift in argument widths or order.
- [x] **`MemHandler` interface shape (B11) — define here, route in Phases 2–3:** a fat-pointer struct
      = opaque context pointer + function pointers for **per-width** access (`read8/read16/read32`,
      `write8/write16/write32`) plus an **optional host-pointer escape** `getHostPtr(ctx, page)
      ?[*]u8` (DOSBox `GetHostReadPt` analog). Document the **byte-decompose fallback** (a handler that
      only implements the byte methods gets 16/32-bit access synthesized by the bus in fixed ascending
      order). Width methods are required for faithful width-sensitive MMIO (real VGA register writes);
      `getHostPtr` keeps RAM-like MMIO (VGA framebuffer `0xA0000`, EMS frame) on the direct-index fast
      path. Grep `references/zig/lib/std/` for the idiomatic "context ptr + fn ptrs" interface pattern
      (`std.mem.Allocator`, `std.Random`) and match it.
- [x] **`Bus.init(allocator) !Bus` / `Bus.deinit()`** allocating the one fixed RAM block (B2) and the
      port table; deterministic zero init. A smoke test: `Bus.init` succeeds, round-trips a byte,
      `deinit` frees with no leak (`std.testing.allocator`). **Run `zig build test-bus`.**
- [x] **Machine integration contract** (document in `bus.zig` header):
  - [x] The **machine OWNS the `Bus` value** and passes `*Bus` into `Cpu(Bus)`'s step path; the bus
        is the bottom of the graph (imports nothing outside `std` + the contract leaf, B10).
  - [x] **Fixed init order:** `Bus.init` → `loadRom` (incl. the BIOS image) → device MMIO/port
        registration → `Cpu(Bus)` construction → reset. (This order assigns handler IDs
        deterministically, B12.)
  - [x] **Push-registration model:** devices **expose** `MemHandler` / `PortHandler` structs; the
        **machine** performs the `mapMmio` / `registerPort` calls (the bus never reaches into a
        device). This reconciles CLAUDE's "self-registering devices" wording: the *device exposes the
        handler*, the *machine wires it* — the bus stays device-agnostic.

---

## Phase 1: Guest RAM + the flat fast path

Goal: the one fixed RAM block and the direct-index read/write 8/16/32 fast path satisfying the
contract. **Done when** RAM r/w 8/16/32 round-trip and `Cpu(Bus)` runs a tiny program against it.

- [x] **Allocate guest RAM once (B2):** `ram: []u8` of `memmap.ram_total_size` (`0x110000`, B3),
      page-aligned (`alignedAlloc` — grep `references/zig/lib/std/mem.zig` /
      `std.heap`/`Allocator.alignedAlloc` for the exact 0.16 signature), zero-filled
      (`@memset(ram, 0)`). Allocated in `Bus.init`, freed in `Bus.deinit`. **(determinism-critical:
      deterministic zero init.)**
- [x] **`comptime` size lock** on `ram_total_size` (slab = `0x110000`) AND the **page-kind table size
      = the A20-mask ceiling `0x200000 >> 12 = 0x200` (512 pages)**, NOT the slab size (B3,
      memory-and-performance.md §5c — lock the layout so a refactor can't silently change the map or
      reintroduce the OOB gap). Assert at comptime that `slab_size < page_table_pages << 12`.
- [x] **Hot/cold field ordering of the `Bus` struct (memory-and-performance.md, B6).** Lay out HOT
      fields first — the `ram` slice, `a20_mask`, the small `page_kind` array (or pointer) — and COLD
      fields last — the port index table, the handler registries, debug/drop counters. The RAM fast
      path must touch only the hot prefix. Add an `@offsetOf` / ordering note (and a comptime check
      that the hot fields precede the cold ones) so a future field add can't push the port table into
      the hot cache line. (NB: Zig's default `auto` struct layout reorders fields by alignment, so a
      raw `@offsetOf` ordering assertion would NOT reflect declaration order; rather than assert a
      layout the compiler doesn't promise — ground rule, no false guarantees — the fields are declared
      hot-first and a comptime SIZE LOCK + dense-int-keyed-table type check pins the layout, with the
      reasoning documented in `bus.zig`.)
- [x] **Little-endian 8/16/32 RAM accessors** matching the contract's byte order. The CPU already
      guarantees ascending sub-bytes (cpu.md Phase 0); implement reads/writes as little-endian over
      the RAM block. **Prefer `std.mem.readInt(uN, ram[i..][0..k], .little)` /
      `std.mem.writeInt`** for the aligned-in-RAM fast path (verify the exact 0.16 signature in
      `references/zig/lib/std/mem.zig` — do not write byte-shuffling from memory). This is the single
      hot path; it must be a tight, inlinable function.
- [x] **Pin the wide RAM fast path to exactly: one page-kind lookup + one in-page test
      (`(masked & 0xfff) <= 0x1000 - size`) + a single `std.mem.readInt`.** Drop to the per-byte loop
      **only** on a page/region straddle (or a non-RAM/ROM page). Copy the shape of DOSBox
      `mem_readw_inline` / `mem_readd_inline` (`references/dosbox-staging/src/cpu/paging.h:307-322`).
      **Explicitly do NOT mirror `TestBus`'s N-byte loop as the production path** — `TestBus`
      (`src/cpu/bus.zig` lines 151–180) decomposes every wide access into bytes for simplicity; the
      real bus's single-region case must be one `readInt`/`writeInt`. (`fastRamSpan` is exactly this.)
- [x] **The fast-path read flow** (the structural core, B1): `phys → a20.mask(phys) → page index →
      page_kind[idx]`:
  - [x] `.ram` (and `.rom` for reads, B4): **bounds-check the index against the slab
        (`< 0x110000`), NOT against the mask (B3)** — then index `ram` directly and return the
        little-endian value. No call, no pointer chase. This is the branch the CPU takes for
        fetch/stack/data. (An in-mask-but-beyond-slab address resolves via the page-kind table to
        `.unmapped`, never an OOB index.)
  - [x] `.mmio` / `.unmapped`: defer to Phase 2 region dispatch.
- [x] **The fast-path write flow:** `.ram` → write `ram` directly; `.rom` → drop (B4); `.mmio` /
      `.unmapped` → Phase 2.
- [x] Unit tests (`ram_test.zig`): write then read at 8/16/32 across page boundaries within RAM;
      assert little-endian byte ordering matches `TestBus` (read back individual bytes after a 32-bit
      write, mirroring the `TestBus` round-trip test in `src/cpu/bus.zig`).
- [x] **Integration check:** instantiate `Cpu(Bus)` (machine-level test or a bus-test that imports
      cpu only in the test) and run a tiny hand-assembled real-mode program (e.g. a few MOV/ADD into
      RAM, a HLT) — assert final RAM/regs. This proves M0 (the bus satisfies the CPU contract end to
      end). Reuse the CPU's existing tiny-program harness shape. (`integration_test.zig`: a MOV/ADD/
      store/HLT program AND a PUSH/POP-through-RAM program both run on the real `Cpu(Bus)`.)

---

## Phase 2: Region/page dispatch + A20 gate + wide-access region-crossing

Goal: full region routing (RAM / ROM / MMIO / unmapped), the A20 gate, and the defined behavior for
a wide access that crosses a region boundary. **Done when** dispatch tests pass for every region kind,
A20 masking + 1 MiB wrap hold, and a region-crossing wide access routes per-byte in ascending order.

- [x] **Page-kind table (B1, B3):** `page_kind: [memmap.page_count]PageKind` where `PageKind =
      enum(u8) { ram, rom, mmio, unmapped }`, sized to the **A20-mask ceiling (512 pages, B3)** — not
      the slab. Initialized in `Bus.init` from the default real-mode layout (`memmap.zig`):
      conventional → `.ram`, UMA → `.unmapped` (until a device claims it), ROM window →
      `.ram`-backed-but-marked-`.rom` after ROM load (Phase 3, but the standard ROM regions are
      installed `.rom` at `init`, Phase 3), HMA → `.ram`, and **pages `[0x110000, 0x1FFFFF]` →
      `.unmapped`** (beyond the slab — `0x00` fill, never OOB). **This table is mutable runtime
      snapshot state (B12):** `mapMmio` / `unmapRegion` / EMS remaps mutate it, so it is captured in
      the snapshot, not replayed as config.
  - [x] **Default-layout function (used by `unmapRegion`, Phase 3):** factor the init mapping into a
        single documented `defaultPageKind(page) PageKind` so "reset to what" is a **deterministic
        function of address**, not an ad-hoc RAM/unmapped choice.
- [x] **Page-index helper:** `page_index(phys) = phys >> page_shift` (4 KiB pages, `page_shift = 12`).
      A20 masking happens **before** indexing.
- [x] **A20 gate (B5, `a20.zig`):**
  - [x] `a20_mask: u32` field on `Bus`, **default `0x0F_FFFF` — A20 DISABLED at power-on (B5)**; the
        BIOS/machine calls `setA20(true)` during POST. A20-off forces **only bit 20** to zero and does
        **NOT** clamp bits 21+ — addresses above the addressable range resolve through the page-kind
        table to `.unmapped`/fill (B3), not by mask-clamping.
  - [x] `setA20(enabled: bool)` → `a20_mask = if (enabled) 0x1F_FFFF else 0x0F_FFFF`.
  - [x] `mask(phys) = phys & a20_mask` applied at the top of **every byte access**. The wide-access
        slow path **re-applies the mask per byte** (B5, spice86-style) so a word straddling the 1 MiB
        seam wraps each byte independently.
  - [x] **(determinism-critical) 1 MiB wrap test:** `FFFF:FFFF` → CPU sends `0x10FFEF` unmasked → with
        A20 on, `0x10FFEF & 0x1FFFFF = 0x10FFEF` (HMA, real storage); with A20 off,
        `0x10FFEF & 0x0FFFFF = 0x00FFEF` (wraps into conventional — **bit-20-only**; the plan's earlier
        `0x000FEF` was an arithmetic slip, corrected here and asserted in `a20_test.zig`). Assert both,
        and assert **default-off** (a fresh bus wraps until `setA20(true)`). This is the bus side of
        cpu.md Phase 8's A20 test (which asserts the CPU sends the unmasked address).
- [x] **Region handler routing (`regions.zig`) — the MMIO seam (interface shape defined in Phase 0,
      B11):** the fat-pointer `MemHandler` (context ptr + per-width `read8/16/32`, `write8/16/32` +
      optional `getHostPtr`) is the *rare* path; a runtime vtable here is fine — the comptime-zero-cost
      requirement applies to the RAM path, which never touches this. (EMS is just an MMIO device, B8 —
      no special kind.)
  - [x] An array of registered handlers + a per-page **handler-ID table `handler_id: [page_count]u8`**
        storing **stable integer IDs (B12)**, not pointers (only consulted when `page_kind` is
        `.mmio`). `.unmapped` and `.rom` need no handler (constant behavior).
  - [x] **Routing:** `.mmio` read → if `getHostPtr(page)` is non-null index it directly (RAM-like fast
        path, B11), else call the per-width `read*`; `.mmio` write → host-ptr fast path or per-width
        `write*`; `.unmapped` read → `memmap.unmapped_fill` (`0x00`, B7); `.unmapped` write → drop;
        `.rom` read → RAM; `.rom` write → drop (B4).
- [x] **Wide-access region-crossing (the boundary the CPU plan delegates here, B-reconciliation):**
  - [x] **Fast single-region path:** if the (masked) start address and `start + size - 1` fall in the
        **same page** AND that page is `.ram`/`.rom`-read, use the direct little-endian RAM accessor.
        (Common case: all aligned and most unaligned accesses.) A single-page MMIO/unmapped access uses
        the handler's NATIVE width method (`readWideOnePage`), so width-sensitive VGA stays faithful.
  - [x] **Slow per-byte path:** otherwise (crosses a page boundary into a different-kind page, or any
        byte lands in `.mmio`/`.unmapped`), decompose into bytes and route **each byte independently**
        through the 8-bit path, in the **fixed ascending address order** (`phys`, `phys+1`, …) — the
        same order the contract guarantees (cpu.md Phase 0). Assemble/disassemble little-endian. This
        is the documented guarantee for a wide access that straddles a region boundary: **no
        cross-region read uses a stale region base; every byte is dispatched to its own region.**
  - [x] Note: because the CPU already split on the *linear* side, a true cross-region wide call should
        be rare in practice — but the bus handles it correctly rather than assuming it never happens
        (ground rule: don't bypass, handle faithfully).
- [x] Unit tests (`regions_test.zig`, `a20_test.zig`):
  - [x] Each `PageKind` routes correctly: RAM r/w, ROM read-hits-RAM + write-dropped, MMIO r/w hits a
        test handler, unmapped read = `0x00` + write dropped.
  - [x] A20 mask on/off, the 1 MiB wrap both ways (above).
  - [x] A 16-bit and a 32-bit access straddling `0x9FFFF/0xA0000` (RAM→UMA) routes per-byte ascending
        — verify with a recording test handler that the bytes arrive in ascending order.

---

## Phase 3: Registration seams (devices, ROM) — the machine wiring contract

Goal: the API by which `src/machine/` wires devices' memory regions, ROM images, and port handlers
into the bus. **Done when** registration tests show a registered MMIO region / port handler / ROM
image takes effect, overlap is rejected, and EMS-via-MMIO (a registered handler that internally
remaps) relocates a UMA window.

- [x] **Install standard ROM regions at `init` (DOSBox installs these at construction):** mark
      `0xF0000–0xFFFFF` (and optionally `0xC0000–0xC8000`) as `.rom` — **write-dropped, reads from
      backing RAM** — **independent of `loadRom`**. `loadRom` then only fills bytes into already-`.rom`
      pages. This means the ROM window behaves correctly (writes dropped) even before/without an image.
- [x] **Memory-region registration** (`regions.zig` / `bus.zig`): `mapMmio(phys_start, len, handler:
      MemHandler) void` — marks the covered pages `.mmio` and points their `handler_id` at the
      registered handler's **stable integer ID (B12)**. (Modeled on DOSBox
      `MEM_SetPageHandler(page,count,handler)` and spice86 `RegisterMapping(start,size,device)`.)
      (Returns the `u8` ID for the machine's snapshot replay.)
  - [x] **Page-granular MMIO rule:** assert `phys_start`/`len` are **page-aligned** (the VGA
        framebuffer `0xA0000` and the EMS frame are page-aligned). A handler that backs a page **owns
        intra-page decode**; **two devices may NOT share a page** — keep the page-alignment assert and
        flag if a sub-page MMIO device ever appears.
  - [x] `loadRom(phys_start, bytes) void` — copies a ROM image into the backing RAM block at
        `phys_start` (the covered pages are already `.rom` from init; reads hit RAM, writes drop — B4).
        Used by the machine for the BIOS image / option ROMs.
  - [x] `unmapRegion(phys_start, len) void` — resets pages to **`defaultPageKind(page)`** (the single
        documented default-layout lookup, Phase 2 — a deterministic function of address, not an ad-hoc
        RAM/unmapped choice) — the DOSBox `MEM_ResetPageHandler` analog; needed for device teardown.
  - [x] **Memory-region overlap policy:** `mapMmio` / `loadRom` over already-claimed (`.mmio`, or a
        different `.rom` owner) pages → **assert/flag** (mirror the port double-registration rule);
        **never silently overwrite** (ground rule).
- [x] **MMIO `MemHandler` is width-aware + host-pointer-capable (B11):** the registered handler exposes
      `read8/16/32`, `write8/16/32` (byte-decompose fallback documented) and the optional
      `getHostPtr(ctx, page) ?[*]u8` direct-index escape (VGA framebuffer `0xA0000`, EMS frame). Real
      VGA register writes are width-sensitive — width methods are required for faithfulness.
- [x] **EMS = an ordinary MMIO device (B8 — NO bespoke bus API):** there is **no `mapEmsPage` and no
      bus-owned EMS backing block.** The machine registers EMS once via `mapMmio(frame_phys, 0x10000,
      ems_handler)`; the `MemHandler` context is the **EMS manager** (`src/dos`/`src/bios`), which owns
      the EMS backing store and **remaps internally by swapping which slice / host pointer it points
      at** (spice86 `EmmRegister : IMemoryDevice`, remap = internal pointer swap). The bus needs zero
      EMS surface. The EMS backing block's deterministic zero-init is determinism-critical but lives in
      the EMS module (B12 device-side state), **not the bus**. INT 67h service logic also lives in
      `src/dos`/`src/bios`. (Verified by the `regions_test` "EMS-style internal remap" test — zero EMS
      surface on the bus.)
- [x] **Port-handler registration** (`ports.zig`): `registerPort(port: u16, handler: PortHandler)
      void` and a range form `registerPortRange(first, count, handler)`. `PortHandler` is a fat-pointer
      interface with explicit per-width methods (`in8/in16/in32` + `out8/out16/out32`, mirroring the
      bus contract) — referenced by **stable integer ID (B12)**, never by pointer; the dense `u8` index
      table stores the ID (B6). **Document:** double-registration of a port is a programming error —
      assert/flag, don't silently overwrite (ground rule).
- [x] **Handler purity contract (B9, determinism):** any registered `MemHandler` / `PortHandler` MUST
      be a **pure function of (device state, address/port, value)** — no host time / RNG / thread /
      env reads, deterministic on reset, snapshot-serializable. The bus cannot check this at comptime,
      but it is **part of the contract** and is enforced by the device modules' own determinism audits.
      State it here so device authors honor it. (Documented in the `bus.zig` header.)
- [x] **Integration-contract documentation** (in `bus.zig` header): the bus connects to the CPU via
      `Cpu(Bus)` instantiation (Phase 0); the **machine** is the only caller of `mapMmio` / `loadRom` /
      `registerPort` / `setA20` / `unmapRegion`. **The InterruptController / Scheduler / FaultSink
      hooks are CPU-machine concerns and are NOT on the bus** (cpu.md Phase 0 split) — note the
      boundary so no one folds IRQ/scheduler state into the bus.
- [x] Unit tests (`regions_test.zig`, `ports_test.zig`): register a test MMIO handler → reads/writes
      route to it (per-width + `getHostPtr` fast path); `loadRom` then read-back + write-dropped;
      standard ROM region write-dropped even with no image loaded; `mapMmio` over a claimed page
      asserts; `registerPort` → IN/OUT route to the test handler; `unmapRegion` reverts to
      `defaultPageKind`; an EMS-style handler that swaps its backing slice relocates a window
      (reading the frame returns the new bytes after the internal remap).

---

## Phase 4: Port I/O dispatch + determinism audit

Goal: complete port dispatch with the deterministic unmapped default and single-handler 16/32-bit
width dispatch, then a determinism + snapshot audit gating the module. **Done when** port tests pass
and the determinism tests (same ops twice → byte-identical; fresh bus byte-identical; populated bus
snapshot→restore→byte-identical) are green.

- [x] **Port dispatch (B6, `ports.zig`):** the dense **`port_handler_id: [65536]u8`** table (64 KiB,
      **separate allocation / cold tail of `Bus`, NOT inline among hot fields**) + a handler array,
      handlers referenced by **stable integer ID (B12)**. `portIn8(port)` → look up ID → handler `in8`
      (or the unmapped default `0`); `portOut8` → handler `out8` (or drop). **(determinism-critical:
      dense table, no unordered container.)**
  - [x] **Unmapped port default (B7):** `portIn8` on an unregistered port returns **`0xFF`** (floating
        bus — matches DOSBox + the CPU's ProcessorTests port convention, cpu.md M3); `portIn16` →
        `0xFFFF`; `portIn32` → `0xFFFF_FFFF`; unmapped `portOut*` → drop.
  - [x] **16/32-bit port access — single-handler dispatch (NOT spill-to-`port+1`):** a 16/32-bit access
        dispatches to the **single handler registered at the base port**. If that handler registered
        the native width (per a fixed **width-capability descriptor stored with the handler ID**), call
        its native-width method (`in16/in32` / `out16/out32`). Otherwise the bus **synthesizes** the
        wide value by calling **that same handler's byte methods** in fixed ascending order — **never
        the handler at `port+1`.** Port aliasing/mirroring is the **device's** responsibility (a device
        that answers a mirrored port range registers all mirror slots). **Rationale:** the old
        "decompose into ascending accesses to consecutive ports (port, port+1, …)" model mis-routes a
        wide access across two different devices; the single-handler model matches spice86/DOSBox.
        (The `WidthCaps` descriptor lives in the `PortHandler.VTable`; the bus checks it before
        choosing native-width vs byte-synthesis from the SAME handler.)
  - [x] **Port handler purity contract (B9):** as in Phase 3 — a `PortHandler` MUST be a pure function
        of (device state, port, value); no host time/RNG/thread/env; deterministic on reset;
        snapshot-serializable. Enforced by device-module audits.
- [x] Unit tests (`ports_test.zig`): register an 8-bit-only handler, do a 16-bit IN → assert it
      synthesized from **two byte INs to the SAME handler/base port** (recording handler), NOT a call
      to `port+1`'s handler; a native-16-bit handler gets a single `in16`; unmapped IN8/16/32 returns
      `0xFF`/`0xFFFF`/`0xFFFFFFFF`; unmapped OUT dropped.
- [x] **Determinism audit (B9 — the module gate, `determinism_test.zig`):**
  - [x] **Grep-enforced no-host-state test** (mirror cpu.md Phase 9): `@embedFile` every `src/bus/`
        source and reject `std.time`, `std.Random`, `std.Thread`, `getenv`, `process.getEnv`.
  - [x] **Same-ops-twice → byte-identical:** run a fixed scripted sequence of reads/writes (across
        RAM/ROM/MMIO/unmapped) + port IN/OUT + an A20 toggle on two fresh buses; assert byte-identical
        RAM, byte-identical port-handler observations, byte-identical returned values.
  - [x] **Fresh-bus byte-identical:** two `Bus.init` calls produce byte-identical RAM (zero) and
        byte-identical page-kind/port tables — no uninitialized state (CLAUDE constraint #5).
  - [x] **Zero allocation on the access path:** a counting-allocator guard (memory-and-performance.md
        §7) asserts no alloc/free during any `readPhys*`/`writePhys*`/`portIn*`/`portOut*` call.
  - [x] **Serializable state & snapshot test (B12 — determinism, CLAUDE #6):** enumerate the
        **snapshot set** — RAM slab bytes, A20 mask, the mutated page-kind table, the handler-ID index
        tables (page + port), and device-side state (owned by device modules, e.g. the EMS backing
        store). Handler *registrations*, ROM images, and the init mappings are **config replayed by the
        machine on restore**, NOT in the snapshot. Add a test that a **populated** bus round-trips
        **snapshot → restore → byte-identical**, with handlers **re-bound by stable ID** (never by host
        pointer — ASLR-varying, CLAUDE #5).
  - [x] **Conformance-angle note (write it down):** the CPU's `TestBus` already validates the contract
        *shape* (the 12 methods, little-endian round-trip, sparse fill). The **real bus adds what
        `TestBus` does not**: region dispatch (RAM/ROM/MMIO/unmapped), the A20 gate + 1 MiB wrap,
        registered port dispatch + the `0xFF` default, the width-aware + host-ptr MMIO seam, the
        standard ROM regions, the region-crossing wide-access path, and the snapshot round-trip. These
        bus-specific behaviors are tested here, not by ProcessorTests. **Also note:** the real bus's
        single-region wide path is one `readInt`/`writeInt`, NOT `TestBus`'s per-byte loop (Phase 1).

---

## Milestone ordering & "done when" criteria

- [x] **M0 — Flat-RAM bus satisfying the CPU contract.** `zig build` + `zig build test-bus` green;
      `Bus` is comptime-verified against `assertBusContract` **via the shared leaf module (B10)**, the
      assertion living in `src/bus/bus.zig`; one fixed RAM block allocated up front (fast path
      bounds-checked against the slab, B3); RAM r/w 8/16/32 round-trip little-endian (single-region
      path = one `readInt`/`writeInt`); a tiny hand-assembled real-mode program **runs on `Cpu(Bus)`**
      and lands the expected RAM/regs. The bus imports nothing outside `std` + the contract leaf.
      (Phases 0–1)
- [x] **M1 — Region dispatch + A20.** Page-kind table (sized to the 512-page mask ceiling, B3) routes
      RAM / ROM (read-hits-RAM, write-dropped) / MMIO (test handler) / unmapped (`0x00` read, write
      dropped); the A20 gate masks every byte (**default OFF at power-on**, bit-20-only, per-byte
      re-mask on the wide path) and the 1 MiB wrap holds both ways (`FFFF:FFFF` → `0x10FFEF` on, →
      `0x00FFEF` off — bit-20-only; the plan's earlier `0x000FEF` was an arithmetic slip); a wide access
      straddling a region boundary routes per-byte in ascending order. (Phase 2)
- [x] **M2 — Registration seams.** Standard ROM regions installed `.rom` at `init`; `mapMmio` /
      `loadRom` / `unmapRegion` (resets to `defaultPageKind`) / `registerPort`(`Range`) take effect in
      tests; overlap is rejected; the integration-contract boundary (machine wires devices via push
      registration; IRQ/scheduler hooks are NOT on the bus) is documented; **EMS is an ordinary MMIO
      device (B8)** — an internal-remap handler relocates a UMA window with zero bus EMS surface.
      (Phase 3)
- [x] **M3 — Port dispatch + width-aware MMIO seam + determinism/snapshot audit.** Port IN/OUT 8/16/32
      dispatch with the `0xFF` floating-bus default and **single-handler width dispatch** (native-width
      method or byte-synthesis from the SAME handler — never `port+1`); the determinism tests pass
      (grep-enforced no-host-state, same-ops-twice byte-identical, fresh-bus byte-identical, zero-alloc
      access path, **populated-bus snapshot→restore→byte-identical with handlers re-bound by ID, B12**).
      The conformance-angle gap (what the real bus tests beyond `TestBus`) is written down. Bus is
      ready for `src/machine/` and `src/devices/` to wire against. (Phase 4)

---

## Out of scope (kept as seams, not built here)

- **EMS (INT 67h service + page-frame backing store + remaps):** entirely a DOS/BIOS concern (B8).
  EMS is registered as an **ordinary MMIO device** through the generic `mapMmio` seam; the EMS manager
  owns its backing store and remaps internally. The bus has **zero EMS-specific surface** — no
  `mapEmsPage`, no bus-owned EMS block. The manager lives in `src/dos`/`src/bios`.
- **Device implementations (PIT/PIC/VGA/SB):** `src/devices/`; the bus exposes only the MMIO + port
  registration seams. The VGA framebuffer at `0xA0000` is a registered MMIO region, not bus code.
- **Protected-mode paging / TLB / #PF / page-boundary linear split:** CPU concern, deferred (cpu.md
  D5). The bus deals only in physical addresses; the CPU's `linearToPhys` choke point is where a
  future paging unit inserts, not the bus.
- **XMS / extended memory > 1 MiB:** deferred; B3 sizes for 1 MiB + HMA. Growing the RAM block + a
  page-kind extension is the future change (BaK uses EMS, not XMS).
- **Cycle accounting:** the bus charges no cycles (B9); the CPU owns the ledger.
