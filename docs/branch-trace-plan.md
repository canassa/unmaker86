# Control-flow branch trace + trap — design plan

A per-machine ring buffer that records **computed-target control transfers** as they
execute, so an operator can find *where* guest control derailed (bad `ret`/indirect
`jmp` into a data table, trashed stack, spin in low memory) — plus a **stop-on-matching-
transfer trap** that *halts the run AT the derail* the instant a recorded transfer
matches a predicate. It is a **pure host-side observer**: integer POD only, zero effect
on executed cycles or guest state, and a function of execution alone
(`trace = f(execution)`), so two identical runs produce byte-identical traces. The trap
is *reporting-only*: it changes WHERE a run pauses, never which cycles run.

This plan is design-only. It cites the actual code it builds on. No source is modified.

---

## Revised per adversarial review (changelog)

This revision folds in adversarial-review findings and adds the **trap** as the keystone.
Changes from the prior draft:

1. **NEW: the branch-trace TRAP (§4).** The trace as previously designed was a *passive*
   log: nothing stopped the run at a derail. The existing no-progress watchdog
   (`controller.zig:464`) only catches a **frozen ledger**, but a real derail (a bad
   `ret`/indirect `jmp` into a data table) keeps executing garbage that *charges cycles*,
   so the watchdog never trips. §4 adds a stop-on-matching-transfer trap (target-range /
   SP-range / kind-mask predicates) checked inside `recordBranch`, surfacing a new
   `StopReason.branch_trap` so `Controller.runUntilEvent` (`controller.zig:444`) pauses
   AT the transfer. This would have auto-caught the motivating crash the instant a `ret`
   jumped into the `0x532B` data table.
2. **Reversed: record near-direct `call E8` BY DEFAULT (§1a, §2).** The prior draft
   excluded `call_near_direct`. It is now a first-class kind, **default-ON** in
   `kind_mask`, recorded at the tail of `callRelv` (`exec_ctrl.zig:74`). Tradeoff owned
   below: direct calls are the most frequent recorded kind, but with the trap you halt AT
   the derail, so recent call-chain context outweighs deep history; the ring stays
   generous (≥4096) and callers can mask it off for max depth.
3. **NEW §1d: host-orchestrated CS:IP pokes enumerated as correctly-excluded
   discontinuities.** The "two hooks cover everything" claim hid real CS:IP mutations
   outside both hooks (the EXEC/INT-23h trampoline, program-entry/far-return loads). They
   are host repositioning, not guest branches — correctly NOT recorded — but they leave
   harmless trace seams, now documented. (Good news the reviewer confirmed: the INT 74h
   mouse user-callback enters via a real `RETF`, so it IS captured as `ret_far`.)
4. **Fixed §3 restore wording.** `Machine.restore` (`machine.zig:930-931`) writes only
   `self.cpu.st = snap.cpu_state` and does **not** call `wire`; the `branch_trace`
   back-pointer lives on the `CpuWith` wrapper (not in `State`), so it **survives restore
   untouched** — it is not "re-bound."
5. **Fixed §7 reveal wording.** `run_to_cycle(at_cycle)` lands **at the transfer target**
   (CS:IP already = `to`, post-transfer); inspect the trashed stack/registers *there*
   (`at_cycle - k` was hand-wavy). With the trap the primary path is "halt AT the derail."
6. **NEW: restore auto-clears the trace, and the input-free-window precondition (§7).**
7. **NEW: reset semantics (§3) made explicit** — reset clears the ring *contents* but
   preserves the *config* (armed/mask/predicate), mirroring how breakpoints survive reset.
8. **Watchdog promoted to a real `StopReason.no_progress` (§4.4)**, not a debug-print.
9. **NITs:** a full 4096-entry ring pages in **4** requests (`MAX_TRACE_DUMP=1024`), not
   2; the interrupt-arm `from` is the **return address pushed** (`interrupts.zig:213-215`),
   not the `INT`/faulting instruction.
10. **Kept** the verified-sound items: `at_cycle` as the stable-coordinate keystone, the
    two-hook completeness argument, classification-is-free, observer purity, the `cb`-seam
    mirror, and the §8 linear-0 honest non-repro.

---

## 0. Ground-rule posture (CLAUDE.md)

* **Determinism (prime directive).** The trace records *after* a transfer's target is
  already resolved and committed to `cpu.st`. It reads only integers already in
  `State` (`selector[CS]`, `eip`, `SP`, `cycles`) plus the per-instruction
  `instr_start_*` scratch. It charges **no cycles**, takes **no branch on guest
  state**, performs **no allocation**, and reads **no host clock/RNG**. It cannot
  change which instruction runs next. The recording is gated by an `armed` bool that
  itself never charges a cycle. The **trap** (§4) is equally pure: its predicate is an
  integer test on observer state, and a match changes only *which `StopReason` is
  surfaced and at which boundary the controller stops* — never a cycle, never a guest
  byte. It is the exact analog of the existing `target_reached` reason
  (`controller.zig:99`), which is also "reporting-only — it changes which REASON is
  surfaced, never which cycles ran or any guest state."
* **No fakes.** This is a real observer wired into the real resolution sites — not a
  reconstructed/heuristic trace. The interrupt-delivery arm reuses the *exact* funnel
  that the shipped interrupt-vector breakpoint already trusts
  (`interrupts.deliverViaIvt`, the `last_delivered` breadcrumb).
* **Raise structural issues.** Surfaced below and requiring a user decision: (a)
  whether each entry carries `at_cycle` (§2, recommended — the locate→reveal and the
  trap-reveal both want it); (b) the linear-0 breakpoint claim could **not** be
  reproduced in the matcher (§8) — reported honestly rather than papered over; (c) the
  SP-range trap predicate is offset-only in real mode (§4.1) — a documented limitation,
  not a silent degrade.

---

## 1. Hook point(s) + classification

There is no single architectural funnel for *all* computed transfers, but there are
**two** clean ones, and together they cover the whole set with the fewest edits.

### 1a. The control-flow arm — `src/cpu/exec_ctrl.zig`

Every computed/far transfer is already its own function in `exec_ctrl.zig`, and each
one *already knows its kind* at the point CS:IP is committed. We record one line at the
tail of each, **after** the target is resolved. The set (with the kind tag to assign):

| Function (file:line) | Opcode(s) | Kind | Why recorded |
|---|---|---|---|
| `callRelv` (exec_ctrl.zig:74) | `E8` | `call_near_direct` | **default-ON** call-chain context (static target; see note) |
| `retNear` (exec_ctrl.zig:113) | `C3`/`C2` | `ret_near` | target popped from stack |
| `retFar` (exec_ctrl.zig:264) | `CB`/`CA` | `ret_far` | CS:IP popped from stack |
| `iret` (exec_ctrl.zig:287) | `CF` | `iret` | CS:IP:FLAGS popped from stack |
| `grp5` reg=2 (exec_ctrl.zig:167) | `FF /2` | `call_near_ind` | `call [mem]`/`call reg` |
| `grp5` reg=4 (exec_ctrl.zig:173) | `FF /4` | `jmp_near_ind` | `jmp [mem]`/`jmp reg` |
| `farCallIndirect` (exec_ctrl.zig:252) | `FF /3` | `call_far_ind` | far `call [mem]` |
| `farJmpIndirect` (exec_ctrl.zig:242) | `FF /5` | `jmp_far_ind` | far `jmp [mem]` |
| `farCallDirect` (exec_ctrl.zig:234) | `9A` | `call_far` | far call (reloads CS) |
| `farJmpDirect` (exec_ctrl.zig:227) | `EA` | `jmp_far` | far jmp (reloads CS) |

The `callRelv` record line goes at the tail, **after** `cpu.st.eip = (cpu.st.eip +% rel)
& ipMask(cpu);` (exec_ctrl.zig:78):

```zig
// at the tail of callRelv, after the eip update at exec_ctrl.zig:78
cpu.recordBranch(.call_near_direct);
```

**Owning the `call_near_direct` tradeoff (locked-in: ON by default).** A near-direct
`E8` has a *static* target baked into the instruction, so the call itself cannot
derail — a bad `ret` that pops a garbage return is caught by the `ret_near` arm. So for
pure *derail localization* the direct call is redundant. **But** with the trap (§4) the
run halts AT the derail, so what the operator needs at that moment is the **recent
call-chain context** ("how did we get into this function?"), and the direct calls are
exactly that context. Deep history matters less once you stop at the bug. Cost: direct
calls are the single most frequent recorded kind, so they consume ring depth fastest.
Mitigations: (i) the ring stays generous (`TRACE_CAPACITY ≥ 4096`); (ii) a caller who
wants maximum *derail-only* depth masks `call_near_direct` off via `kind_mask` (§4.3 /
§6), trading call-chain context for a deeper window of indirect/return transfers.

**Excluded by design** (static target baked into the instruction, *and* they are the
loop back-edges that would flood the ring — and unlike `E8` they push no call-chain
context worth keeping): `jccRel8`/`jccRelv` (exec_ctrl.zig:43/50),
`jmpRel8`/`jmpRelv` (exec_ctrl.zig:65/69), and `loop`/`jcxz` (exec_ctrl.zig:129). These
are conditional/unconditional *intra-function* edges; excluding them is what keeps the
ring full of *meaningful* transfers.

**What each record line captures.** `from` is the instruction's own CS:IP; `to` is the
freshly committed CS:IP; `sp` is the post-transfer `SP`. For near transfers
`from_cs == to_cs`; for far transfers CS changes mid-function, so `from_cs` must be the
value *entering* the instruction. We obtain it without per-site bookkeeping by reading a
new per-instruction scratch field `cpu.instr_start_cs` (mirrors the existing
`cpu.instr_start_eip`, cpu.zig:99), set once in `interrupts.step` next to
`cpu.instr_start_eip = cpu.st.eip` (interrupts.zig:65). So every site becomes a single
call:

```zig
// at the tail of e.g. retNear, after `cpu.st.eip = ip;`
cpu.recordBranch(.ret_near);   // reads instr_start_cs/eip + current CS:IP + SP + cycles
```

`recordBranch(kind)` (defined on the CPU, §3) reads `from = instr_start_cs:instr_start_eip`,
`to = selector[CS]:(eip & 0xFFFF)`, `sp = getReg16(ESP)`, `at_cycle = st.cycles`. No
arguments beyond the kind — the rest is already in `cpu.st`.

### 1b. The interrupt-delivery arm — `src/cpu/interrupts.zig`

`deliverViaIvt` (interrupts.zig:200) is **the single faithful chokepoint** for *all*
IVT vectoring: software `INT n`/`INT3`/`INTO`/`ICEBP` (via `exec_ctrl.intN` etc.,
exec_ctrl.zig:273–286), hardware IRQ and NMI (via `serviceInterrupts`), and CPU
exceptions (via `deliverException`). The shipped interrupt-vector breakpoint already
relies on this exact property — the `last_delivered` breadcrumb is set here
(interrupts.zig:231). We add the trace record at the same spot, **after** the successful
far load (interrupts.zig:222–223), so a limit-exceeded delivery that returned early
(interrupts.zig:206) is correctly *not* recorded:

```zig
// interrupts.zig, immediately after cpu.st.eip = new_ip; (and beside the last_delivered set)
cpu.recordBranchEx(.interrupt,
    from_cs, from_ip,                 // captured at top of deliverViaIvt (= the PUSHED return CS:IP)
    new_cs, new_ip,                   // the handler entry
    cpu.st.getReg16(ESP));            // SP after the 3 pushes
```

`from_cs`/`from_ip` are snapshotted into locals from `cpu.st.selector[CS]` / `cpu.st.eip`
at the **top** of `deliverViaIvt`, i.e. the exact values the delivery sequence pushes as
the return frame at interrupts.zig:213–215 (`pushWord(flags)`, `pushWord(CS)`,
`pushWord(IP)`). **Nit fixed:** the interrupt-arm `from` is therefore the *return address
pushed* — the boundary CS:IP the handler will `IRET` back to — **not** the `INT`/faulting
instruction's own address (for a software `INT n` they coincide only because the trap is
taken at the byte after the opcode; for a hardware IRQ the `from` is the instruction that
*would* run next, which is precisely the pushed return address). This arm uses the
explicit-operand form `recordBranchEx` (it cannot use the `instr_start_*` shortcut: a
hardware IRQ is delivered at a boundary, not from the just-retired instruction's start).

This is **why two hooks, not one**: a post-`executeOne` central hook in
`dispatch.executeOne` would catch the exec_ctrl transfers but **miss** hardware IRQ/NMI
deliveries, which fire later in `serviceInterrupts` *after* `executeOne` returns.
Recording directly in `deliverViaIvt` is the only faithful capture for those.

### 1c. Do the functions already know the kind?

Yes. Each `exec_ctrl` function *is* a single opcode/sub-opcode, and `grp5`'s arms
(exec_ctrl.zig:154) are an explicit `switch (cpu.dec.reg)` over CALL/JMP near/far — the
classification is free, no re-decode. `deliverViaIvt` is unconditionally "an interrupt
delivery". No instruction-stream re-inspection is needed anywhere.

### 1d. Host-orchestrated CS:IP pokes — correctly EXCLUDED discontinuities

The "two hooks cover everything" claim is true *for guest branches*, but it must not be
read as "no other code ever writes CS:IP." Several **host** paths reposition CS:IP
directly (not via a guest control-transfer opcode and not via `deliverViaIvt`). These are
**correctly NOT recorded** — they are the emulator repositioning the guest, not the guest
branching — but they create **harmless trace discontinuities** an operator should expect:

* **The `runGuestInt` trampoline (EXEC / INT 23h re-entry).** `bridge.zig:701-702` pokes
  `cpu.loadSegment(.cs, self.tramp_seg); cpu.st.eip = self.tramp_off;` to enter a host-
  built trampoline, drives a nested step loop, then *restores* CS:IP/SP at
  `bridge.zig:720-722`. Used by INT 23h's `breakTest` (`int21.zig:359`, `br.runGuestInt(0x23)`)
  and the EXEC path. Effect on the trace: the trampoline's own `INT n` *is* recorded by
  the §1b arm, but its `from` is the trampoline address the guest never "reached" by a
  normal branch — and when the host restores CS:IP at `:720-722` there is a **silent
  seam** (the outer code resumes with no recorded transfer back). This is faithful: the
  guest never executed a branch there; the host moved it.
* **Program-entry and far-return loads in the loader.** `loader.zig:316-317` (`setupRun`:
  `cpu.loadSegment(.cs, res.cs); cpu.st.eip = res.ip;`) sets the initial CS:IP of a freshly
  loaded program, and `loader.zig:657-658` loads CS:IP to an `execRetfSegOff` landing pad
  for a child-program far return. Neither is a guest branch; both are correctly unrecorded.
  The first transfer the operator sees is the program's *own* first computed transfer.

**Good news the reviewer confirmed — this is NOT a gap:** the INT 74h mouse user-callback
is entered by a **real `RETF`**, not a host poke. `int33.zig:816-821` pushes the far
frames (`pushFar(cpu, eoi…); pushFar(cpu, handler_seg, handler_off);`) and lets the
trampoline's `RETF` pop them, routing through `exec_ctrl.retFar` — so the callback entry
**is** captured as a `ret_far` entry. The deferred-IRQ12 mouse callback therefore appears
in the trace like any other transfer.

---

## 2. Entry layout + ring sizing

```zig
// src/cpu/branch_trace.zig  (NEW — pure integer POD, no imports beyond std)
pub const BranchKind = enum(u8) {
    call_near_direct,                 // E8 — default-ON (see §1a tradeoff)
    ret_near, ret_far, iret,
    call_near_ind, jmp_near_ind,
    call_far, call_far_ind, jmp_far, jmp_far_ind,
    interrupt,
};

pub const BranchEntry = struct {
    kind: u8 = 0,          // BranchKind
    from_cs: u16 = 0,
    from_ip: u16 = 0,
    to_cs: u16 = 0,
    to_ip: u16 = 0,
    sp: u16 = 0,
    at_cycle: u64 = 0,     // RECOMMENDED — see decision note below
};
```

* **Lean by intent.** No register/stack dumps. In a deterministic emulator you *locate*
  with the lean trace, then `snapshot`+replay+`step` to *reveal* the exact registers and
  memory (§7) — or, with the trap, you are already halted there. `sp` is included
  deliberately: stack-pointer corruption is the leading crash hypothesis, a column of
  `sp` down the dump shows exactly the transfer where SP went bad, **and** it is the
  field the SP-range trap predicate (§4.1b) tests.
* **Ring sizing.** `pub const TRACE_CAPACITY = 4096;` entries. At the 20-byte layout
  (with `at_cycle`, padded to 24) that is ~96 KiB; at the 12-byte layout (without
  `at_cycle`, padded) ~48 KiB. Both are a fixed, per-machine slab — no allocation. 4096
  is generous depth even with `call_near_direct` ON: a contained `call`/`ret` recursion
  is bounded by the ring (oldest evicted), the flooding statics (`jcc`/near-`jmp`) are
  excluded entirely (§1a), and the trap halts AT the derail so a deep pre-derail window
  is not the priority. Callers who want a deeper indirect/return-only window mask
  `call_near_direct` off (§4.3).

```zig
pub const BranchTrace = struct {
    entries: [TRACE_CAPACITY]BranchEntry = @splat(.{}),
    head: u32 = 0,        // next write slot
    len: u32 = 0,         // valid entries, saturates at TRACE_CAPACITY
    total: u64 = 0,       // monotonic count of all transfers ever recorded
    armed: bool = false,  // record gate; default OFF (zero overhead until armed)
    kind_mask: u16 = 0xFFFF, // §4.3 kind filter; default = all kinds (incl. call_near_direct)

    trap: TrapPredicate = .{},   // §4.1 — independent of `armed`
    trap_hit: ?BranchEntry = null, // §4.2 — latched on first match; consumed by the controller

    pub fn push(self: *BranchTrace, e: BranchEntry) void {
        // (1) TRAP first — evaluated on EVERY transfer, independent of the record gate
        //     so a caller can trap on kinds it does not record. Pure integer test.
        if (self.trap.armed and self.trap_hit == null and self.trap.matches(e)) {
            self.trap_hit = e;                         // latch the FIRST matching transfer
        }
        // (2) RECORD — gated by armed + kind_mask
        if (!self.armed) return;                       // cheap gate, no cycle charge
        if ((self.kind_mask >> @intCast(e.kind)) & 1 == 0) return;
        self.entries[self.head] = e;
        self.head = (self.head + 1) % TRACE_CAPACITY;
        if (self.len < TRACE_CAPACITY) self.len += 1;
        self.total += 1;
    }
    pub fn clear(self: *BranchTrace) void { self.head = 0; self.len = 0; self.total = 0; self.trap_hit = null; }
    // chronological copy-out helper for the dump command (§6) lives here.
};
```

`total` (a single counter on the ring, **not** a per-entry `seq`) lets a dump report
absolute indices and lets a reader tell whether the ring wrapped, without bloating each
entry.

> **DECISION FOR THE USER — `at_cycle` (8 bytes).** The settled lean layout
> `{kind,from_cs,from_ip,to_cs,to_ip,sp}` omits cycle. I recommend **adding `at_cycle`**
> anyway: the reveal step is `run_to_cycle(at_cycle)` then `step`/inspect (§7), and the
> trap stop also reports the cycle for free. Without it, you can only re-arm an
> `execution_address` breakpoint on the derail target — ambiguous if that linear is hit
> many times (exactly the low-memory-spin case). `at_cycle` is a pure integer from the
> ledger (`cpu.st.cycles`), so it costs determinism nothing. The design works either way;
> if declined, drop the field and the workflow falls back to address-based re-arming.

---

## 3. Where the ring lives + ownership

**The `BranchTrace` slab is owned by the `Machine` (a plain field, deliberately *not* in
`Machine.Snapshot`); the CPU reaches it through an optional back-pointer wired at boot,
exactly mirroring the existing callback-sink seam.**

### Why this placement

* **The hook must run *inside* the step, at the transfer site** — only the CPU sees the
  resolved target. Contrast with breakpoints, which the Controller checks *between*
  steps (`scanBreakpoints`, controller.zig:523, called from `runUntilEvent`,
  controller.zig:484). A branch record cannot be a between-steps Controller check: by
  the next boundary the transfer is over and `from`/`sp` may be gone. So storage must be
  reachable by the CPU synchronously. (The **trap match** is computed here too, in
  `push`; only the *stop* is taken between steps by the controller — §4.2.)
* **The CPU must not import the debugger** (module graph). The `BranchTrace` *type* lives
  in `src/cpu/branch_trace.zig`, so the CPU owns its own observer type — no upward
  import. This mirrors how `State.last_delivered` (interrupts.zig:231, read by
  breakpoints.zig:160,204) is a CPU-owned breadcrumb that the debugger *reads*, never a
  debugger type the CPU imports.
* **Reach it cheaply via the proven `cb` seam.** The CPU already carries an optional
  sink pointer wired by the machine: `cb: ?*opts.CallbackSink` (cpu.zig:92–94), set in
  `Services.wire` via `cpu.cb = self` (machine.zig:89). We add the same shape:

  ```zig
  // cpu.zig, in the CpuWith(...) struct, beside `cb`:
  branch_trace: ?*branch_trace.BranchTrace = null,   // null in bare-CPU tests; wired by Machine

  // recordBranch / recordBranchEx are tiny inline methods:
  pub inline fn recordBranch(self: *Self, kind: branch_trace.BranchKind) void {
      const t = self.branch_trace orelse return;      // single optional-deref, no work if unwired
      t.push(.{ .kind = @intFromEnum(kind),
                .from_cs = self.instr_start_cs, .from_ip = @truncate(self.instr_start_eip),
                .to_cs = self.st.selector[@intFromEnum(Seg.cs)], .to_ip = @truncate(self.st.eip),
                .sp = self.st.getReg16(@intFromEnum(Reg32.esp)), .at_cycle = self.st.cycles });
  }
  pub inline fn recordBranchEx(self: *Self, kind: branch_trace.BranchKind,
                               from_cs: u16, from_ip: u16, to_cs: u16, to_ip: u16, sp: u16) void {
      const t = self.branch_trace orelse return;
      t.push(.{ .kind = @intFromEnum(kind), .from_cs = from_cs, .from_ip = from_ip,
                .to_cs = to_cs, .to_ip = to_ip, .sp = sp, .at_cycle = self.st.cycles });
  }
  ```

  `instr_start_cs: u16 = 0` is added beside `instr_start_eip` (cpu.zig:99) and set in
  `interrupts.step` (interrupts.zig:65). Both are per-step scratch, **not** in `State`.

* **The Machine owns the slab**, beside `cpu` (machine.zig:217), and binds the pointer
  **once** in `Machine.wire` (machine.zig:310), right after `self.cpu = Cpu.init(...)`
  places the CPU at its final, pinned address (machine.zig:312):

  ```zig
  // machine.zig, Machine struct:
  branch_trace: branch_trace.BranchTrace = .{},
  // in Machine.wire(), after self.cpu = Cpu.init(...) (machine.zig:312):
  self.cpu.branch_trace = &self.branch_trace;   // bound ONCE; never serialized
  ```

  The Controller reads it via `self.m.branch_trace` — the same idiom by which
  breakpoints read `m.cpu.st.last_delivered` (breakpoints.zig:160, 204).

### Survives restore + reset (NOT re-bound) — corrected

* **Restore.** `Machine.restore` (machine.zig:930-931) copies **only**
  `self.cpu.st = snap.cpu_state` (and the device snapshots); it does **not** call `wire`.
  The `branch_trace` back-pointer lives on the `CpuWith` *wrapper*, **not** in
  `cpu.st`/`State`, so a restore leaves it **untouched — it survives, it is not
  re-bound.** (`cpu.reset()` likewise only does `self.st.reset()`, cpu.zig:107-109, so
  the pointer survives reset too.) Because the `Machine` and its embedded `cpu` are
  pinned, the once-bound pointer can never dangle.
* **Restore auto-clears the trace (decision — §7).** Although `restore` does not *touch*
  the back-pointer, the restore *workflow* must call `branch_trace.clear()`: a restore
  starts a new timeline, so prior `at_cycle` coordinates are invalid and a subsequent
  dump would interleave two timelines with overlapping `at_cycle`. The clear also drops a
  stale `trap_hit`. (This is a controller-level action on restore, not a change to
  `Machine.restore` itself.)

### Is it snapshotted? **No — and that is deliberate, document it.**

`Machine.Snapshot` captures `cpu_state: cpu_mod.State` (machine.zig:812) — i.e. only the
CPU's `State`, **not** the `CpuWith` wrapper's scratch (`dec`, `instr_start_eip`, `cb`,
the new `branch_trace` pointer). The slab is a `Machine` field that is **omitted from
`Machine.Snapshot` on purpose**. Therefore `snapshot`/`restore` neither captures nor
clobbers the trace:

* The trace is **debugger/observer state, like the Controller's `BreakpointSet`**
  (controller.zig:410), which is likewise *not* in any Snapshot — confirmed: the
  Controller has no snapshot method, and `Snapshot` has no breakpoint/observer fields.
* Restoring an earlier machine state **must not** rewrite the operator's accumulated
  branch history — the history is *about* the run, not part of the determinism-critical
  machine state.

### Reset semantics (explicit)

`Machine.reset` (machine.zig:678) re-zeros RAM for reproducibility (machine.zig:681) and
clears the per-run breadcrumbs (`cpu.reset()`→`st.reset()` drops `last_delivered`;
`bus.resetWatchHit()` at :682), but it **persists** the armed watch table, the `.watched`
page markers, and the controller's breakpoint set (the doc-comment at machine.zig:684-685:
"a debug session's breakpoints outlive a machine reset"). The branch trace follows the
**same split**:

* **Config persists** across reset — `armed`, `kind_mask`, and the `trap` predicate are
  observer configuration, exactly like breakpoints, and survive a reset untouched.
* **Contents clear** across reset — `head`/`len`/`total`/`trap_hit` are *timeline* data,
  exactly like RAM and `last_delivered`, and a power-on is a new timeline. Add a
  `self.branch_trace.resetTimeline()` call in `Machine.reset` (a new method that zeros
  the contents but leaves `armed`/`kind_mask`/`trap`), placed beside the existing
  breadcrumb resets. This is stated explicitly so the two features (snapshot/restore vs.
  reset) have one coherent stance: **restore preserves contents** (a restore is a return
  *to a point on the same operator-visible timeline*, and the controller clears
  explicitly only when starting a NEW timeline), while **reset clears contents** (a
  power-on is unambiguously a new timeline).

*Alternative considered & rejected:* a comptime `TraceSink` hook type with the ring on the
Controller. More machinery for no determinism benefit; the optional-POD-pointer seam above
is the minimal faithful version and matches `cb` one-for-one. Noted as the fallback if the
user prefers the ring physically on the Controller.

---

## 4. The branch-trace TRAP (stop-on-matching-transfer) — keystone

A passive log tells you *where* a derail went **after** you already noticed something
broke. The problem: a real derail (a bad `ret`/indirect `jmp` into a data table) keeps
**executing garbage that charges cycles**, so the no-progress watchdog (which only fires
on a *frozen* ledger) never trips, and the run sails past the bug. The trap closes that
gap: it **halts the run the instant a recorded transfer matches a predicate**, leaving the
machine paused **AT** the transfer (CS:IP already = the target), with the matching trace
entry surfaced. It is the precise, opt-in complement to the watchdog backstop (§4.4).

This would have **auto-caught the motivating crash**: arm the trap with "target outside
the program's code segments," and the moment a `ret` popped a trashed return and jumped
into the `0x532B` data table, the run stops at the table address with the culprit
`ret_near` entry in hand — no manual stepping, no re-running.

### 4.1 Predicates (composable; OR semantics)

The predicate lives on the ring as pure POD and is evaluated in `push` (§2) after the
entry `e` is built. At least these three clauses, each independently enable-able; the trap
fires if **any enabled clause** matches the entry (OR — stop at the first sign of
trouble; a caller arms only the clauses it wants):

```zig
// src/cpu/branch_trace.zig
pub const TrapPredicate = struct {
    armed: bool = false,             // master gate (independent of the record `armed`)

    // (a) target OUTSIDE a linear code range — catches a transfer into data/garbage.
    to_range: bool = false,
    to_lo: u32 = 0,
    to_hi: u32 = 0xFFFFF,            // trap if to_lin < to_lo OR to_lin > to_hi

    // (b) SP OUTSIDE a stack-bounds range — catches SP corruption (leading hypothesis).
    sp_range: bool = false,
    sp_lo: u16 = 0,
    sp_hi: u16 = 0xFFFF,             // trap if e.sp < sp_lo OR e.sp > sp_hi

    // (c) KIND mask — stop on any iret / any indirect jmp / etc.
    kind_match: bool = false,
    kind_trap_mask: u16 = 0,         // trap if (1 << e.kind) & kind_trap_mask != 0

    pub fn matches(self: *const TrapPredicate, e: BranchEntry) bool {
        if (self.to_range) {
            const to_lin = (@as(u32, e.to_cs) << 4) +% e.to_ip;   // same formula as exec-bp currentLinear
            if (to_lin < self.to_lo or to_lin > self.to_hi) return true;
        }
        if (self.sp_range) {
            if (e.sp < self.sp_lo or e.sp > self.sp_hi) return true;
        }
        if (self.kind_match) {
            if ((self.kind_trap_mask >> @intCast(e.kind)) & 1 == 1) return true;
        }
        return false;
    }
};
```

* **(a) `to_range`** is the derail catcher: set `[to_lo,to_hi]` to the program's loaded
  code extent (e.g. the linear span of its code segments) and any transfer that lands
  *outside* it — into a data table, the PSP, low memory, or freed memory — trips. `to_lin`
  uses the **same** `(cs<<4)+ip` formula as the execution-breakpoint matcher
  (`breakpoints.zig:212 currentLinear`), so the bound the operator reasons about is the
  same linear space they already use for breakpoints/`disassemble`.
* **(b) `sp_range`** is the SP-corruption catcher: set `[sp_lo,sp_hi]` to the program's
  stack-segment bounds; a `ret`/`call` that leaves SP outside the window (a runaway pop,
  an unbalanced stack, an underflow wrap) trips. **Documented limitation (ground rule 3):**
  `e.sp` is the 16-bit SP *offset* within the current SS; in real mode with a single stack
  segment this is exact, but it does **not** account for an SS reload (a far stack switch).
  If the program switches stacks, the bound is approximate (offset-only). This is surfaced,
  not silently degraded; a future widening could compare `(ss<<4)+sp` linear if SS is added
  to the entry.
* **(c) `kind_match`** stops on a transfer *class*: e.g. `kind_trap_mask` with only the
  `iret` bit set stops on the next `iret` (handler-exit forensics); only the indirect-jmp
  bits set stops on any `jmp [mem]`/`jmp reg` (vtable/jump-table dispatch). The mask is
  the same `1 << @intFromEnum(kind)` encoding as the record `kind_mask`.

All three are **integer-only, side-effect-free** tests on the entry that was just built
from committed `State` — no host clock, no allocation, no guest mutation.

### 4.2 Mechanism — match in `push`, stop in `runUntilEvent`

* **Match (in the CPU, on the hot path).** `push` (§2) evaluates `trap.matches(e)`
  *after* the entry is built and **latches** the first match into `trap_hit`
  (`?BranchEntry`). Latching the first only (`trap_hit == null` guard) means a flurry of
  post-derail garbage transfers cannot overwrite the *original* culprit before the
  controller reads it. The match is computed at the transfer site because that is the only
  place the resolved target/SP exist — but it takes **no stop action itself** (the CPU
  cannot, and must not, unwind the controller's run loop).
* **Stop (in the controller, between steps).** `runUntilEvent` (controller.zig:444) checks
  `self.m.branch_trace.trap_hit` **each step**, right alongside `scanBreakpoints` — the
  same "check observer state at the boundary" pattern. Because `push` runs *during* the
  step that executes the transfer and the transfer is the last thing that instruction
  does, when `m.step()` returns CS:IP already equals the transfer's `to`. So returning
  here leaves the machine paused **AT the target, post-transfer** — exactly where the
  operator wants to inspect the trashed stack/registers. On consuming the hit the
  controller **clears** `trap_hit` (so a subsequent `run` does not immediately re-fire on
  the stale latch) and surfaces the new reason:

  ```zig
  // controller.zig runUntilEvent loop, after the post-step terminal + scanBreakpoints checks:
  if (self.m.branch_trace.trap_hit) |e| {
      self.m.branch_trace.trap_hit = null;                 // consume the latch
      return self.record(.{ .branch_trap = .{ .entry = e, .at_cycle = self.m.cpu.st.cycles } });
  }
  ```

* **Precedence.** Checked **after** `terminalReason` and `scanBreakpoints`, so a terminal
  always wins and an explicit USER breakpoint at the same boundary wins the tie (the user
  asked for that stop by name; the trap is the automatic backstop). Document this ordering;
  ties are rare. `stepInstruction`/`stepN`/`stepOver` should perform the same post-step
  `trap_hit` check so a single step across a matching transfer also stops on it (the
  universal debugger convention, mirroring how those paths already call `scanBreakpoints`).

### 4.3 StopReason variant + threading

Add a variant to the debug-layer `StopReason` union (controller.zig:81), beside the
existing `target_reached`/`dwell_complete` reporting-only reasons:

```zig
// controller.zig StopReason union — a NEW reporting-only, non-terminal reason.
/// A branch-trace TRAP fired: a recorded transfer matched the armed predicate (§4.1).
/// The machine is paused AT the transfer (CS:IP = the target). `entry` is the matching
/// transfer (the culprit). Reporting-only — it changes WHERE the run pauses, never which
/// cycles ran or any guest state, exactly like `target_reached`.
branch_trap: struct { entry: branch_trace.BranchEntry, at_cycle: u64 },
```

Thread it the same way the other reasons are threaded — all three touch points are
mechanical:

1. **Serializer (`server.zig`).** The `.stop => |s| try self.writeValue(w, .{ .stop = s })`
   arm (server.zig:2454) serializes the whole `StopReason` union via the generic
   `writeValue` (server.zig:2545) reflection, so the new variant serializes **for free**
   (no new serializer arm). It emits `{"branch_trap":{"entry":{…},"at_cycle":N}}`. The
   entry's `kind` is a `u8`; for readability the controller can surface the trap via the
   §6 `WireBranchEntry` mapping (kind name + `from_lin`/`to_lin`) instead of the raw POD —
   recommended, so the stop body matches a dump row.
2. **Compact `StopTag` (`run_control.zig:36`).** Add a `branch_trap` tag to the `enum(u8)`
   so `/api/run/status` can report it.
3. **Pacer classifier (`run_pacer.zig:206`).** Add the switch arm
   `.branch_trap => |t| .{ .branch_trap, t.at_cycle, true }` — **terminal = true** in the
   pacer's sense (it disarms the paced run so it does not immediately re-run past the
   trap, exactly like `.breakpoint`), but **program_end = false** (it is not a guest exit;
   the `program_end` switch at run_pacer.zig:222 leaves it in the `else` arm). This keeps
   that `switch (reason)` total (the compiler enforces it).

### 4.4 Reconciliation with the no-progress watchdog

The uncommitted watchdog in `runUntilEvent` (controller.zig:464-481) is a **temporary
`std.debug.print`** that detects a *frozen ledger* (the cycle counter not advancing for
1,000,000 consecutive steps — a host emulation path spinning with no guest progress) and
returns `cycle_budget_exhausted`. It and the trap are **complementary, not redundant**:

| | catches | how |
|---|---|---|
| **no-progress watchdog** | a **frozen ledger** — host path spins, **no** cycles charged | counts consecutive zero-cycle steps |
| **branch-trap (§4)** | a **live derail** — guest executes garbage that **does** charge cycles | matches a recorded transfer against a predicate |

A real `ret`-into-data derail charges cycles every garbage instruction, so the watchdog
**cannot** see it — that is precisely the gap the trap fills. Conversely a host-side spin
charges no cycles, so the trap never records a transfer and cannot see it. **Keep both.**

Recommendation: **promote the watchdog from a debug-print to a proper `StopReason`** rather
than deleting it (a worker must never spin forever — the watchdog is the unconditional
backstop). Add `no_progress: struct { at_cycle: u64, stuck_steps: u64 }` to `StopReason`
(+ a `no_progress` `StopTag`, + a `run_pacer.zig` arm mapped terminal=true / program_end=
false), drop the `std.debug.print`, replace the `1_000_000` literal with a named
`NO_PROGRESS_LIMIT` const, and return `.{ .no_progress = … }` instead of
`cycle_budget_exhausted`. Coexistence in `runUntilEvent`: the per-step order becomes
(1) pre-step terminal, (2) `step`, (3) no-progress watchdog (frozen-ledger backstop),
(4) post-step terminal, (5) `scanBreakpoints`, (6) `trap_hit` check, (7) deadline. The
watchdog is the always-on safety net; the trap is the precise opt-in stop.

---

## 5. (reserved)

*(Section intentionally folded into §4 — the trap and its watchdog reconciliation are one
topic. Numbering kept stable for the control-surface and composition sections below.)*

---

## 6. Control surface (MCP + HTTP)

Mirrors the `list_breakpoints` (read-only, fixed-array payload) and `clear_breakpoints`
(mutate-then-ack) idioms end-to-end, extended with the trap arm/clear.

### `src/api/queue.zig`

```zig
// Commands (add to the Command union, queue.zig:62):
branch_trace_arm: struct { on: bool, kind_mask: u16 = 0xFFFF },   // arm/disarm record + filter
branch_trace_clear: void,
branch_trace_dump: struct { limit: u32, offset: u32 = 0, newest_first: bool = true },
// TRAP arm/clear (§4):
branch_trap_arm: TrapArgs,                                        // sets the predicate + armed
branch_trap_clear: void,

// Wire entry + caps (beside MAX_STACK_WORDS, queue.zig:46 / StackResult, queue.zig:259):
pub const MAX_TRACE_DUMP = 1024;          // per-response array cap (page the ring if larger)
pub const WireBranchEntry = struct {       // integer-only; serde via std.json.Stringify
    kind: []const u8,                      // kind name (e.g. "ret_near") for readability
    from_cs: u16, from_ip: u16, to_cs: u16, to_ip: u16,
    from_lin: u32, to_lin: u32,            // convenience: seg<<4 + ip (matches exec-bp linear)
    sp: u16, at_cycle: u64, index: u64,    // index = absolute position (total-based)
};
pub const TraceDumpResult = struct { count: u16 = 0, capacity: u32 = 0, total: u64 = 0,
                                     items: [MAX_TRACE_DUMP]WireBranchEntry = undefined };
pub const TraceStatus = struct { armed: bool, len: u32, capacity: u32, total: u64, kind_mask: u16,
                                 trap_armed: bool };  // surface trap arm state in status
pub const TrapArgs = struct {              // pointer-free POD mirroring TrapPredicate
    to_range: bool = false, to_lo: u32 = 0, to_hi: u32 = 0xFFFFF,
    sp_range: bool = false, sp_lo: u16 = 0, sp_hi: u16 = 0xFFFF,
    kind_match: bool = false, kind_trap_mask: u16 = 0,
};

// Responses (add to the Response union, queue.zig:340):
trace_status: TraceStatus,        // arm/disarm/clear/trap-arm ack
trace_dump: TraceDumpResult,
```

`MAX_TRACE_DUMP` bounds the per-response array exactly like `MAX_STACK_WORDS`
(queue.zig:46) bounds `StackResult` and `MAX_BREAKPOINTS` bounds `BpListResult`. **Nit
fixed:** a full 4096-entry ring therefore pages in **4** requests (`4096 / 1024`), not 2,
via `offset`/`limit`. No heap in the hot path: the worker fills `items[0..count]` from the
ring.

### `src/api/worker.zig` (dispatch in `drainOne`, worker.zig:95)

```zig
.branch_trace_arm   => .{ .trace_status = ctrl.armBranchTrace(c.on, c.kind_mask) },
.branch_trace_clear => .{ .trace_status = ctrl.clearBranchTrace() },
.branch_trace_dump  => branchTraceDump(ctrl, c),   // local helper, fills TraceDumpResult, no alloc
.branch_trap_arm    => .{ .trace_status = ctrl.armBranchTrap(c) },
.branch_trap_clear  => .{ .trace_status = ctrl.clearBranchTrap() },
```

`branchTraceDump` mirrors `listBreakpoints` (worker.zig:266) / `clearBreakpoints`
(worker.zig:280): a stack `TraceDumpResult`, filled element-by-element from the ring.

### `src/debug/controller.zig`

New methods beside the breakpoint-management block (controller.zig:586). They read/mutate
`self.m.branch_trace` only — no CPU/guest mutation:

```zig
pub fn armBranchTrace(self: *Controller, on: bool, mask: u16) TraceStatus { ... } // armed/kind_mask
pub fn clearBranchTrace(self: *Controller) TraceStatus { self.m.branch_trace.clear(); ... }
pub fn dumpBranchTrace(self: *const Controller, out: []WireBranchEntry,
                       offset: u32, newest_first: bool) []WireBranchEntry { ... }    // chronological copy
pub fn branchTraceStatus(self: *const Controller) TraceStatus { ... }
pub fn armBranchTrap(self: *Controller, a: TrapArgs) TraceStatus { ... }            // sets predicate+armed
pub fn clearBranchTrap(self: *Controller) TraceStatus { self.m.branch_trace.trap = .{}; self.m.branch_trace.trap_hit = null; ... }
```

The dump walks the ring oldest→newest (or reversed) starting at `(head - len)`, mapping
`BranchEntry`→`WireBranchEntry` (compute `from_lin = (from_cs<<4)+from_ip` so the operator
can paste it straight into `add_breakpoint {execution_address:{linear}}` or `disassemble`).
The dump and status methods are `*const Controller` — side-effect-free, like
`forEachBreakpoint`/`peekStack`; the arm/clear methods take `*Controller` (they mutate
observer config, never guest state).

### `src/api/server.zig` (shared HTTP+MCP serializer)

Add two arms to `writeResponseBody` (server.zig:2451), the function both HTTP and MCP route
through:

```zig
.trace_status => |s| try self.writeValue(w, s),               // like .cleared / .status
.trace_dump   => |d| try self.writeTraceDump(w, d),           // like .bp_list -> writeBpList
```

`writeTraceDump` mirrors the `.bp_list` serializer: emit
`{"trace":[...],"total":N,"capacity":C}` via
`std.json.Stringify.value(d.items[0..d.count], ...)`. The `.stop` arm (server.zig:2454)
already serializes the new `branch_trap` `StopReason` for free (§4.3). No new serializer
machinery.

### `src/api/mcp_tools.zig`

Catalog entries (beside `list_breakpoints`, mcp_tools.zig:130) and `buildCommand` arms,
all `needs_debugger = false` (they touch only observer state, no guest advance — same as
`list_breakpoints`/`clear_breakpoints`):

| MCP tool | Schema (args) | `buildCommand` → `cmd(...)` |
|---|---|---|
| `branch_trace_arm` | `{enabled:bool, kinds?:[string]}` | `.{ .branch_trace_arm = .{ .on=…, .kind_mask=… } }, false` |
| `branch_trace_clear` | `{}` (`SCHEMA_EMPTY`) | `.branch_trace_clear, false` |
| `branch_trace_dump` | `{limit?:int<=1024, offset?:int, newest_first?:bool}` | `.{ .branch_trace_dump = … }, false` |
| `branch_trace_status` | `{}` | (returns `.trace_status`) |
| `branch_trap_arm` | `{to_range?:bool,to_lo?:int,to_hi?:int, sp_range?:bool,sp_lo?:int,sp_hi?:int, kinds?:[string]}` | `.{ .branch_trap_arm = … }, false` |
| `branch_trap_clear` | `{}` (`SCHEMA_EMPTY`) | `.branch_trap_clear, false` |

`kinds` (optional array of kind names) maps to `kind_mask` / `kind_trap_mask` in
`buildCommand` (an omitted `kinds` for the record arm ⇒ `0xFFFF` = all; for the trap arm an
omitted `kinds` simply leaves `kind_match=false`). `cmd`/`needs_debugger` plumbing is the
existing helper.

---

## 7. Composition with snapshot + replay — locate→reveal (and trap→reveal)

The trap **halts AT the bug**; the trace **locates cheaply and deeply**; snapshot+replay
**reveals exactly**. Two concrete loops for the motivating bug (control derails into low
memory / a data table):

**Trap path (primary).**
1. `branch_trace_arm {enabled:true}` and `branch_trap_arm {to_range:true, to_lo:<code lo>,
   to_hi:<code hi>}` (and/or `sp_range` with the stack bounds).
2. `run`. The instant a transfer lands outside the code range (or SP leaves bounds), the
   run stops with `branch_trap`, the machine paused **AT the target** (CS:IP = `to`), and
   the stop body carries the culprit entry.
3. **Reveal — already there.** `read_cpu`/`read_stack`/`read_memory`/`disassemble` at the
   current PC give the full registers and the trashed stack the lean trace omits. The
   newest `branch_trace_dump` row is the same culprit, with the call-chain run-up above it.

**Trace path (when you did not pre-arm a trap, or the stop was a watchdog/budget).**
1. After the stop, `branch_trace_dump {newest_first:true}`. Read down the `sp` column: the
   entry where `sp` jumps/inverts, or where `to_lin` first lands in a data/low-memory
   region, is the derailing transfer. Its `kind` tells you *how* (a `ret_near`/`ret_far` ⇒
   a trashed return address; a `jmp_far_ind` ⇒ a bad pointer table). `from_lin` is the
   culprit instruction; `to_lin` is where it went.
2. **Reveal.** With `at_cycle` present (§2): `snapshot` (or reload), `run_to_cycle
   {cycle: at_cycle}`, then inspect — this **lands at the transfer target** (CS:IP is
   already `to`, post-transfer), so `read_cpu`/`read_stack`/`read_memory`/`disassemble`
   read the trashed registers and stack image right there. (No "step across" is needed:
   `run_to_cycle` stops at the boundary where the transfer has *just* completed.) Without
   `at_cycle`, fall back to `add_breakpoint {execution_address:{linear: to_lin}}` + `run`
   — ambiguous on a hot address, the reason `at_cycle` is recommended.

**Restore + input-free-window preconditions (composition review).**
* **Restore auto-clears the trace.** A `restore` (or reload-to-snapshot) starts a new
  timeline; prior `at_cycle` coordinates are invalid, so the controller clears the ring on
  restore (§3) — otherwise a later dump interleaves two timelines with overlapping
  `at_cycle` and the reveal step jumps to the wrong cycle.
* **Input-free window.** The locate→reveal replay only reproduces the recorded transfer if
  **no input was injected** between the snapshot and that transfer. Injected keyboard/mouse
  events (`input_key`/`input_mouse`) are deliberate new INPUTS (the "same binary + SAME
  inputs" determinism category), **not** a replayable stream — a replay from the snapshot
  without re-injecting them, at the same cycles, diverges. So pre-arm the trap (no replay
  needed) for input-driven derails, or ensure the suspect window is input-free before
  relying on `run_to_cycle` replay.

The division of labor is the point: the trap stops you exactly at the bug, the ring keeps
thousands of meaningful transfers around it, and replay reconstructs any single one in full
fidelity on demand.

---

## 8. Related bug to note — execution breakpoint at linear 0 (VERIFIED: NOT a matcher sentinel)

The task asked to flag that an `execution_address` breakpoint at `linear 0` "silently
never fires — 0 appears to be treated as 'unset' in the breakpoint engine." **I checked
`src/debug/breakpoints.zig` and could not reproduce that in the matcher.** The relevant
code:

```zig
// breakpoints.zig:157
.execution_address => |k| return currentLinear(m) == k.linear,
```

`currentLinear` (breakpoints.zig:212) is `seg_base[CS] +% eip`; at CS:IP = 0:0 this is
`0`, and `0 == 0` is **true** — the matcher fires. There is **no zero-sentinel** in
`matches`, `scanBreakpoints` (controller.zig:523), `add` (breakpoints.zig:68), or the
`add_breakpoint` arg path (the MCP schema marks `linear` *required* for
`execution_address`, so an omitted field can't silently become 0). A tree-wide grep for
`linear == 0`/`!= 0`/`orelse 0` sentinels in `src/debug` found none on the breakpoint path.

**Honest verdict (ground rule 3):** as written, a linear-0 exec breakpoint *should* fire.
If the crash-at-`0:0` was genuinely uncatchable, the cause is **not** a 0-sentinel in the
breakpoint engine; the more plausible suspects are the **resume rule** ("step at least
once before evaluating breakpoints", controller.zig:451–458 — if you were already paused
*at* 0:0, a `run` steps *off* it before checking) or a `null`-vs-`0` ambiguity at an
optional-arg parse layer where a missing address would default to 0 (but the schema guards
that). I recommend the user reproduce with an explicit
`add_breakpoint {execution_address:{linear:0}}` + `run` against a known jump-to-0 stub
before committing a fix. **One-line defensive sketch *if* a real swallow is found at the
parse layer:** represent the optional address as `?u32` end-to-end (never collapse
"absent" to `0`) so a deliberate `linear:0` is distinguishable from "omitted" — but per the
above this is not currently needed in `breakpoints.zig`.

**The trap (§4) sidesteps this entirely for the derail case:** a transfer *into* 0:0 trips
the `to_range` predicate (0 is below any sane `to_lo`) and stops the run AT 0:0 regardless
of any breakpoint — which is exactly why a temporal transfer-trap beats a breakpoint here.

---

## 9. Phased plan, tests, determinism audit, risks, LOC

### Phases

1. **Core POD + CPU hook + trap.** `src/cpu/branch_trace.zig` (`BranchKind`/`BranchEntry`/
   `BranchTrace`/`TrapPredicate`); add `instr_start_cs` + `branch_trace: ?*…` +
   `recordBranch`/`recordBranchEx` to `cpu.zig`; set `instr_start_cs` in `interrupts.step`
   (interrupts.zig:65); add the `deliverViaIvt` record (interrupts.zig:~231); add the 10
   `exec_ctrl` record lines (incl. `call_near_direct` at exec_ctrl.zig:78). Add
   `branch_trace.zig` to the CPU determinism embed list (determinism_test.zig:68–74).
2. **Machine ownership + wiring + lifecycle.** `branch_trace` field on `Machine`
   (machine.zig:217); back-pointer bound once in `Machine.wire` (machine.zig:312);
   excluded from `Machine.Snapshot` (doc-comment); survives restore untouched
   (machine.zig:930); `resetTimeline()` called in `Machine.reset` (machine.zig:678,
   contents-clear / config-persist).
3. **Trap stop threading.** `StopReason.branch_trap` + `StopReason.no_progress`
   (controller.zig:81); `trap_hit` check in `runUntilEvent` (controller.zig:444) and the
   step paths; promote the watchdog to `no_progress` (controller.zig:464); `StopTag` +
   `run_pacer.zig:206` arms for both.
4. **API plumbing.** queue commands/responses + caps (incl. `TrapArgs`); worker dispatch +
   `branchTraceDump` helper; controller `arm/clear/dump/status` + `armBranchTrap`/
   `clearBranchTrap`; server `writeTraceDump` + 2 `writeResponseBody` arms; mcp_tools
   catalog + `buildCommand` arms (record + trap).

### Tests

* **Functional trace.** A guest stub that executes `ret` (returns to a planted address),
  an indirect `jmp [mem]`, an indirect `call reg`, a far `jmp`, a near `call` (E8), and an
  `int N`; assert the ring holds exactly those entries in order with the right `kind`,
  `from`, `to`, `sp` (and `at_cycle` monotonic).
* **Functional trap.** (a) `to_range` armed to the stub's code extent + a `ret` that pops a
  planted out-of-range target ⇒ `runUntilEvent` returns `branch_trap`, machine paused with
  `CS:IP == to`, `trap_hit` consumed, the entry surfaced. (b) `sp_range` armed + a `ret`
  that leaves SP outside bounds ⇒ trap. (c) `kind_match` with only the `iret` bit ⇒ stops
  on the next `iret`. Assert cycle count is **identical** to the same run with the trap
  disarmed up to the stop boundary (reporting-only).
* **Trap latch-first.** Two consecutive out-of-range transfers ⇒ `branch_trap.entry` is the
  **first** one (the latch is not overwritten).
* **Exclusion / no-flood.** A tight `jcc`/near-`jmp` loop (`dec cx; jnz`) for thousands of
  iterations records **zero** entries; a bounded `call`/`ret` recursion records ≤
  `TRACE_CAPACITY` and wraps correctly (oldest evicted, `total` keeps counting).
* **`call_near_direct` mask.** With `kind_mask` clearing the `call_near_direct` bit, a run
  of `E8` calls records nothing for that kind but still records the matching `ret`s.
* **Determinism double-trace.** Run the same stub twice from reset; assert the two ring
  dumps are byte-identical (`trace = f(execution)`), trap armed and disarmed alike.
* **Cycle-neutrality.** Run a fixed program to cycle N with trace+trap **armed** and
  **disarmed**; assert `cpu.st.cycles` and full `State` are identical via `stateEql`
  (determinism_test.zig:23) — recording/matching charge nothing and change nothing.
* **Snapshot/restore + reset independence.** Arm, record entries, `snapshot`/`restore` ⇒
  ring unchanged by restore, back-pointer survives (a post-restore transfer still records).
  `reset` ⇒ ring **contents** cleared but `armed`/`kind_mask`/`trap` **config** preserved.
* **No-progress watchdog.** A host-spin stub (frozen ledger) ⇒ `no_progress` after
  `NO_PROGRESS_LIMIT` steps (not a debug-print, not an infinite loop).
* **Zero-alloc.** The trace+trap path under the existing `PanicAllocator` step() test —
  fixed array, no alloc.

### Determinism-audit checklist

* [ ] `branch_trace.zig` added to the `src/cpu` determinism grep embed list
  (determinism_test.zig:68) — passes the forbidden set (no `std.time`/`std.Random`/
  `std.Thread`/`getenv`).
* [ ] No `f32`/`f64`/`Clock`/`Instant`/`Timer`/`nanoTimestamp` substrings in any new
  type/field name (would trip the **api** grep, since the wire types live in `queue.zig`,
  an embedded api source). Names chosen accordingly (`at_cycle`, `armed`, `trap`,
  `trap_hit`, `to_lo`, `sp_hi`, `head`, `len`, `total` — all clean).
* [ ] queue `Command`/`Response` additions (incl. `TrapArgs`, `WireBranchEntry`,
  `TraceStatus`) are pointer-free integer/POD. `WireBranchEntry.kind: []const u8` points
  only at a comptime string-literal table (like existing wire enums), not host memory.
* [ ] Recording AND trap-matching are gated by `armed`/`trap.armed` + an `?*` null-check —
  zero work, zero cycle charge when unwired/disarmed.
* [ ] `at_cycle`/`sp`/`cs`/`ip`/`to_lin` are read straight from `State`/the entry — no host
  clock, no RNG. The trap stop and `no_progress` are reporting-only (like `target_reached`).

### Risks

1. **Struct-size / by-value copies.** The slab (~48–96 KiB) lives on `Machine` (long-lived,
   effectively boxed) — fine. It is **not** added to the bare `CpuWith` struct, so
   stack-allocated test CPUs don't grow. *Mitigation:* `TRACE_CAPACITY` is a single tunable
   constant (e.g. 2048).
2. **Two hook regions, not one.** Forgetting a future new computed-transfer opcode (e.g. a
   new far-control form) would silently omit it from the trace **and** the trap.
   *Mitigation:* a comptime/disasm cross-check test asserting every `exec_ctrl` function
   that reloads CS or pops IP has a `recordBranch` call.
3. **`at_cycle` decision (§2).** If declined, the *trace* reveal degrades to address-based
   re-arming (the *trap* path is unaffected — it halts in place). Surfaced for sign-off.
4. **SP-range predicate is offset-only (§4.1b).** Approximate across an SS reload (far
   stack switch). Documented limitation; widen to linear `(ss<<4)+sp` if SS is added to the
   entry. Not a single-stack-segment concern today.
5. **`from_ip` truncation in 16-bit real mode.** Entries store `u16` IP (correct for real
   mode, CS.D=0, exec_ctrl masks with `ipMask`=0xFFFF). If unreal/32-bit code mode is ever
   in scope, widen to `u32`. Noted, not a real-mode concern today.

### LOC estimate (honest)

~**750–950 LOC** total: ~**500–600 non-test** (branch_trace.zig ~170 incl. `TrapPredicate`;
cpu.zig ~25; exec_ctrl.zig ~13; interrupts.zig ~6; machine.zig ~12; controller.zig ~85 incl.
trap arm/clear + `trap_hit`/watchdog stop + `no_progress`; run_control.zig ~3; run_pacer.zig
~6; queue.zig ~45; worker.zig ~50; server.zig ~40; mcp_tools.zig ~80) and ~**300–350 test**.

### Open decisions for the user

1. **`at_cycle` in each entry?** Recommended on (§2) — wanted by both trace-reveal and the
   trap stop body. The one deviation from the settled lean layout.
2. **`TRACE_CAPACITY`** default (4096 proposed; 2048 if footprint-sensitive). With
   `call_near_direct` ON, 4096 is the comfortable choice.
3. **`call_near_direct` default-ON** (§1a) — locked per review; confirm you want it ON by
   default (vs. ON-but-commonly-masked-off).
4. **Trap predicate composition = OR** across enabled clauses (§4.1) — confirm (vs. AND, or
   a caller-selected combinator). OR is the "stop at the first sign of trouble" default.
5. **Trap precedence below user breakpoints** at a tie (§4.2) — confirm (vs. trap-wins).
6. **Promote the no-progress watchdog to `StopReason.no_progress`** (§4.4) — confirm
   (recommended; it replaces the temporary debug-print at controller.zig:464).
7. **Ring on `Machine` (recommended) vs. on `Controller`** via a comptime sink (§3
   alternative) — confirm placement.
