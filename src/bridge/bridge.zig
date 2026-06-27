//! The callback-trampoline guest<->host bridge — the SHARED LEAF (D12/D16) that
//! BOTH `src/bios/` and `src/dos/` import; neither imports the other. This is the
//! foundation everything in those modules hangs off, and the literal differentiator
//! of zdos (the no-hole synthetic-cost charging, D5).
//!
//! What it owns:
//!   - Callback allocation (a stable id table, D14) + the 3-byte `0xFE 0x38 <id>`
//!     trap stub + per-id return tail (`IRET`/`RETF`/`IRET+STI`/`IRET+EOI`), D1/D4.
//!   - The `INT n; <stop-callback>` re-entrancy trampoline + `runGuestInt`, D3.
//!   - `setGuestCF/ZF/IF` (the FLAGS-image-on-the-IRET-frame patch, D4).
//!   - The synthetic-cost charge at dispatch (D5, via `cb_cost.zig`).
//!
//! It depends ONLY on the CPU surface (a comptime `Cpu` type param) + the bus
//! (through the CPU). It is generic over `Cpu` so the per-call path inlines and no
//! CPU type is named in any shared contract (the `bus_contract` leaf doctrine).
//!
//! Re-entrancy wiring (D3): the bridge sits BELOW the machine, so it cannot import
//! the machine to drive its step. The machine INJECTS a stepper at wire time
//! (`setStepper`) — a `fn(ctx) void` that runs ONE machine step (fireDue +
//! cpu.step + HLT fast-forward), so PIT/IRQ events fire during re-entry and the
//! BDA tick stays cycle-deterministic. `runGuestInt` loops that stepper until the
//! stop sentinel fires.

const std = @import("std");
const cb_cost = @import("cb_cost.zig");

pub const Kind = cb_cost.Kind;

/// The callback return-tail type (D4) — the bytes that follow the 3-byte trap
/// stub. Re-derived from the ISA:
///   IRET = 0xCF, RETF = 0xCB, STI = 0xFB, OUT 0x20,AL = 0xE6 0x20, MOV AL,0x20.
pub const CbType = enum {
    /// `IRET` — software-INT / hardware-INT handlers (the common case).
    iret,
    /// `RETF` — far-call services.
    retf,
    /// `STI; IRET` — IRQ handlers that re-enable interrupts on return.
    iret_sti,
    /// `MOV AL,0x20; OUT 0x20,AL; IRET` — master-PIC IRQ handlers that EOI first
    /// (IRQ0/IRQ1 — the INT 08h/09h path, D4).
    iret_eoi_pic1,
    /// `MOV AL,0x20; OUT 0xA0,AL; OUT 0x20,AL; IRET` — slave-PIC IRQ handlers
    /// (EOI to both the slave and the master cascade).
    iret_eoi_pic2,
    /// `INT 0x1C; PUSH AX; MOV AL,0x20; OUT 0x20,AL; POP AX; IRET` — the INT 08h
    /// timer-tick chain tail (Phase 1·0a). After the host-serviced tick trap
    /// (the slot's `0xFE 0x38 <id>` runs `int08.handle`, incrementing the BDA
    /// tick) this tail chains to the guest-overridable `INT 1Ch` (the user timer
    /// tick a program may hook), THEN EOIs the master PIC and IRETs. The chain is
    /// done at the STUB level (a real guest `INT 1Ch` through the IVT) rather than
    /// by nested host-stepping every ~18.2 Hz tick — the faithful, no-extra-hole
    /// path flagged at `int08.zig:7-13`. EOI is emitted AFTER the INT 1Ch returns
    /// (matching real BIOS: the tick ISR services the user hook before signalling
    /// end-of-interrupt). PUSH/POP AX preserve the interrupted guest's AL across
    /// the EOI's `MOV AL,0x20` (same rationale as `iret_eoi_pic1`).
    int1c_chain_eoi_pic1,
};

// --- ISA byte facts (re-derived, not copied) ---
const OP_TRAP0: u8 = 0xFE;
const OP_TRAP1: u8 = 0x38; // GRP4 /7
const OP_IRET: u8 = 0xCF;
const OP_RETF: u8 = 0xCB;
const OP_STI: u8 = 0xFB;
const OP_MOV_AL_IMM: u8 = 0xB0;
const OP_OUT_IMM_AL: u8 = 0xE6;
const OP_INT_IMM: u8 = 0xCD;
const OP_PUSH_AX: u8 = 0x50; // preserve the interrupted AX across the EOI sequence
const OP_POP_AX: u8 = 0x58;
// ISR-discipline register save/restore (the INT 74h mouse trampoline, Option C).
const OP_PUSHA: u8 = 0x60; // PUSHA  — save AX,CX,DX,BX,SP,BP,SI,DI (16-bit)
const OP_POPA: u8 = 0x61; // POPA   — restore them
const OP_PUSH_DS: u8 = 0x1E;
const OP_POP_DS: u8 = 0x1F;
const OP_PUSH_ES: u8 = 0x06;
const OP_POP_ES: u8 = 0x07;
const EOI: u8 = 0x20; // OCW2 non-specific EOI
const PIC1_CMD: u8 = 0x20;
const PIC2_CMD: u8 = 0xA0;
// Short relative control flow (the INT 16h poll-loop shell, Phase 1·0a). All are
// rel8: a single signed displacement byte added to EIP AFTER the 2-byte instr.
const OP_JZ_REL8: u8 = 0x74; // Jcc cc=0100 (ZF==1)
const OP_JNZ_REL8: u8 = 0x75; // Jcc cc=0101 (ZF==0)
const OP_JMP_REL8: u8 = 0xEB; // unconditional short JMP
const INT_KBD_ISR: u8 = 0x09; // IRQ1 keyboard ISR the blocking loop drives
// CMP AH, imm8 = 0x80 /7 ib. ModR/M 0xFC = mod=11 (reg-direct) reg=/7 rm=100 (AH,
// the 8-bit register #4). Used by the INT 16h hybrid preamble to branch on AH.
const OP_CMP_RM8_IMM8: u8 = 0x80;
const MODRM_CMP_AH: u8 = 0xFC;
const AH_GET_KEYSTROKE: u8 = 0x00; // AH=00 — blocking GET (folds enhanced keys)
const AH_GET_ENHANCED: u8 = 0x10; // AH=10 — blocking enhanced GET (keeps them)

/// The BIOS-ROM segment the callback area lives in (DOSBox places the callback
/// area at F000:1000; we mirror the PLACEMENT, not its CB_SIZE=32 offset math).
pub const CB_SEG: u16 = 0xF000;
/// Offset of the callback area within the BIOS segment.
pub const CB_OFFSET: u16 = 0x1000;
/// Linear/physical base of the callback area (F000:1000 = 0xF1000).
pub const CB_BASE_PHYS: u32 = (@as(u32, CB_SEG) << 4) + CB_OFFSET;

/// zdos's OWN slot size (D1 — a deliberate divergence from DOSBox's CB_SIZE=32 /
/// 2-byte id). A slot is the 3-byte trap stub `0xFE 0x38 <id>` plus the largest
/// return tail. The largest tail is 9 bytes — both `iret_eoi_pic2` =
/// PUSH AX (1) + MOV AL,imm (2) + OUT 0xA0,AL (2) + OUT 0x20,AL (2) + POP AX (1)
/// + IRET (1), AND `int1c_chain_eoi_pic1` = INT 1Ch (2) + PUSH AX (1) +
/// MOV AL,imm (2) + OUT 0x20,AL (2) + POP AX (1) + IRET (1) (PUSH/POP preserve the
/// interrupted AX across the EOI). 3 + 9 = 12; round up to 16 so a slot is
/// paragraph-aligned (seg:off math is clean and a future tail can grow without
/// re-laying-out the table).
pub const CB_SLOT_SIZE: u16 = 16;

/// Max callback slots (provisional / comptime-asserted cap, D14). 128 ids fit in
/// a single byte (D1). The trampoline + all BIOS/DOS/EMS vectors are well under.
pub const CB_MAX: u8 = 128;

/// The re-entrancy trampoline location (D3) — in CONVENTIONAL RAM (0000:0600, the
/// DOS communication-area scratch), NOT the BIOS ROM (its `INT nn` immediate is
/// patched per `runGuestInt` call, and ROM writes are dropped).
pub const TRAMP_SEG: u16 = 0x0000;
pub const TRAMP_OFF: u16 = 0x0600;

comptime {
    // The largest tail must fit the slot (the by-construction layout guard, 0b).
    std.debug.assert(3 + 9 <= CB_SLOT_SIZE);
    // The whole table must fit inside the BIOS ROM window (0xF0000..0xFFFFF).
    std.debug.assert(CB_BASE_PHYS + @as(u32, CB_MAX) * CB_SLOT_SIZE <= 0x100000);
}

/// One registered callback (D14: ids assigned in fixed registration order).
pub const Slot = struct {
    cb_type: CbType,
    kind: Kind,
    /// True once `plantStub` has written this slot's bytes into the ROM image.
    planted: bool = false,
};

/// Build the bridge type for a given comptime `Cpu` type. Generic so the per-call
/// path inlines and no CPU type leaks into any shared contract.
pub fn Bridge(comptime Cpu: type) type {
    return struct {
        const Self = @This();
        pub const CpuType = Cpu;

        cpu: *Cpu = undefined,

        /// The callback table (stable ids 0..count). Slot 0 is the stop sentinel.
        slots: [CB_MAX]Slot = undefined,
        count: u8 = 0,

        /// The reserved re-entrancy stop sentinel id (D3) — allocated first so it
        /// is a known constant (0). Set by `init`.
        stop_id: u8 = 0,
        /// Re-entrancy "done" flag, set by the stop-sentinel handler.
        reentry_done: bool = false,
        /// Re-entrancy depth guard (D3) — flag overflow loudly, never recurse
        /// unboundedly.
        depth: u8 = 0,

        /// The trampoline location (D3): `INT n; <stop-callback>`. Planted at init.
        tramp_phys: u32 = 0,
        tramp_seg: u16 = 0,
        tramp_off: u16 = 0,

        /// The machine-injected stepper for re-entrancy (D3 wiring). `ctx` is the
        /// machine; `step_one` runs exactly one machine step (fireDue + cpu.step +
        /// HLT fast-forward). Injected at wire time so the bridge never imports the
        /// machine (acyclic graph).
        step_ctx: ?*anyopaque = null,
        step_one: ?*const fn (*anyopaque) void = null,

        /// A flat ROM image the bridge writes stubs into; the machine hands it to
        /// `bus.loadRom(0xF0000, image)` at POST so the stub bytes are REAL guest
        /// code at the vector (D4 faithfulness). Sized to cover the callback area.
        pub const IMAGE_BASE: u32 = 0xF0000;
        pub const IMAGE_LEN: u32 = 0x10000; // the whole 64 KiB BIOS segment

        /// Max re-entrancy depth (D3) before flagging loudly.
        pub const MAX_DEPTH: u8 = 8;

        pub fn init(self: *Self, cpu: *Cpu) void {
            self.cpu = cpu;
            self.count = 0;
            self.reentry_done = false;
            self.depth = 0;
            self.step_ctx = null;
            self.step_one = null;
            // Slot 0: the re-entrancy stop sentinel (D3). Allocated first so its
            // id is the documented constant 0.
            self.stop_id = self.allocCallback(.iret, .stop_sentinel);
            std.debug.assert(self.stop_id == 0);
            // The re-entrancy trampoline lives in CONVENTIONAL RAM (NOT the BIOS
            // ROM image): runGuestInt patches its `INT nn` immediate per call, and
            // ROM writes are dropped. A fixed reserved paragraph in the DOS
            // communication area (0000:0600) is used (below the program load area,
            // above the IVT+BDA).
            self.tramp_seg = TRAMP_SEG;
            self.tramp_off = TRAMP_OFF;
            self.tramp_phys = (@as(u32, TRAMP_SEG) << 4) + TRAMP_OFF;
        }

        /// Inject the machine's one-step primitive for re-entrancy (D3).
        pub fn setStepper(self: *Self, ctx: *anyopaque, step_one: *const fn (*anyopaque) void) void {
            self.step_ctx = ctx;
            self.step_one = step_one;
        }

        // -------------------------------------------------------------------
        // Allocation + planting (D1/D4).
        // -------------------------------------------------------------------

        /// Allocate a stable callback id (registration order, D14). Reserves the
        /// slot; `plantStub` writes the bytes; `setRealVec` points an IVT entry at
        /// it. The (cb_type, kind) pair fixes the return tail + the D5 cost.
        pub fn allocCallback(self: *Self, cb_type: CbType, kind: Kind) u8 {
            std.debug.assert(self.count < CB_MAX);
            const id = self.count;
            self.slots[id] = .{ .cb_type = cb_type, .kind = kind };
            self.count += 1;
            return id;
        }

        pub fn slotPhys(id: u8) u32 {
            return CB_BASE_PHYS + @as(u32, id) * CB_SLOT_SIZE;
        }
        pub fn slotSegOff(id: u8) struct { seg: u16, off: u16 } {
            const phys = slotPhys(id);
            return .{ .seg = CB_SEG, .off = @intCast(phys - (@as(u32, CB_SEG) << 4)) };
        }

        /// Write the 3-byte trap stub + return tail for `id` into `image` (the ROM
        /// image, indexed from `IMAGE_BASE`). `image` is later `loadRom`-ed so the
        /// bytes are real guest code (D4). Tail bytes re-derived from the ISA.
        pub fn plantStub(self: *Self, image: []u8, id: u8) void {
            const slot = &self.slots[id];
            const phys = slotPhys(id);
            var w = Emit{ .image = image, .pos = phys - IMAGE_BASE };
            w.byte(OP_TRAP0);
            w.byte(OP_TRAP1);
            w.byte(id);
            switch (slot.cb_type) {
                .iret => w.byte(OP_IRET),
                .retf => w.byte(OP_RETF),
                .iret_sti => {
                    w.byte(OP_STI);
                    w.byte(OP_IRET);
                },
                .iret_eoi_pic1 => {
                    // PUSH AX / ... / POP AX so the EOI's `MOV AL,0x20` does NOT
                    // clobber the interrupted guest's AL (a real BIOS IRQ handler
                    // preserves the register frame). Without this, an IRQ0 landing
                    // between a guest `MOV AL,x` and a following INT corrupts AL to
                    // 0x20 — observed as scattered 0x20 pixels in the VGA oracle.
                    w.byte(OP_PUSH_AX);
                    w.byte(OP_MOV_AL_IMM);
                    w.byte(EOI);
                    w.byte(OP_OUT_IMM_AL);
                    w.byte(PIC1_CMD);
                    w.byte(OP_POP_AX);
                    w.byte(OP_IRET);
                },
                .iret_eoi_pic2 => {
                    w.byte(OP_PUSH_AX);
                    w.byte(OP_MOV_AL_IMM);
                    w.byte(EOI);
                    w.byte(OP_OUT_IMM_AL);
                    w.byte(PIC2_CMD);
                    w.byte(OP_OUT_IMM_AL);
                    w.byte(PIC1_CMD);
                    w.byte(OP_POP_AX);
                    w.byte(OP_IRET);
                },
                .int1c_chain_eoi_pic1 => {
                    // INT 1Ch (chain to the guest-overridable user timer tick),
                    // THEN EOI(master) + IRET. The host tick (BDA inc) already ran
                    // in the slot's `0xFE 0x38 <id>` trap above; here we run the
                    // guest hook through the REAL IVT, then signal end-of-interrupt.
                    // 9 bytes — fits the 9-byte largest-tail budget (CB_SLOT_SIZE).
                    w.byte(OP_INT_IMM);
                    w.byte(0x1C);
                    w.byte(OP_PUSH_AX);
                    w.byte(OP_MOV_AL_IMM);
                    w.byte(EOI);
                    w.byte(OP_OUT_IMM_AL);
                    w.byte(PIC1_CMD);
                    w.byte(OP_POP_AX);
                    w.byte(OP_IRET);
                },
            }
            slot.planted = true;
        }

        /// The total byte length of the INT 16h blocking poll-loop shell
        /// (`emitPollLoop`). A fixed shape; exposed so the installer (Phase 1d)
        /// can size/place it.
        pub const POLL_LOOP_LEN: u16 = 14;

        /// Parameters for the INT 16h blocking poll-loop shell (Phase 1·0a).
        /// The shape is FIXED but it cannot be a `CbType` tail variant: a slot's
        /// `0xFE 0x38 <id>` stub carries only ITS OWN id, while the loop needs TWO
        /// DISTINCT callback ids (has-key + dequeue) plus the keyboard-ISR INT
        /// number. So it is a parameterized emitter in the SAME idiom as
        /// `plantStub` (multi-instruction ISA-byte composition via `Emit`), not a
        /// new return tail. Phase 1d allocates the two callbacks, then installs
        /// this shape and points the AH=00/10 arm of INT 16h at it.
        pub const PollLoop = struct {
            /// Callback id whose handler sets ZF=0 when a key is available, ZF=1
            /// when the ring is empty (the `CallbackHasKey` shape).
            has_key_id: u8,
            /// Callback id whose handler dequeues the cooked word into AX (the
            /// `CallbackDequeueAndSetAx` shape).
            dequeue_id: u8,
        };

        /// Emit the INT 16h blocking poll-loop shell into `image` at byte offset
        /// `pos` (relative to the start of `image`). Re-derived from the ISA, the
        /// spice86 `KeyboardInt16Handler.cs:168-206` AH=00/10 loop re-modeled to
        /// zdos's trap-callback bridge:
        ///
        ///   L_GET_KEY:
        ///     STI                       ; FB        — IF=1 so an injected IRQ1 is
        ///                               ;              recognized through the
        ///                               ;              normal fetch/execute loop
        ///                               ;              (the whole point of the
        ///                               ;              faithful blocking read)
        ///     <trap has_key_id>         ; FE 38 id  — ZF=0 when a key is present
        ///     JNZ have_key              ; 75 04
        ///     INT 09h                   ; CD 09     — run the IRQ1 keyboard ISR
        ///     JMP short L_GET_KEY       ; EB F6     — back to STI (rel8 = -10)
        ///   have_key:
        ///     <trap dequeue_id>         ; FE 38 id  — AX = cooked word
        ///     IRET                      ; CF
        ///
        /// The rel8 displacements are added to EIP AFTER the displacement byte
        /// (x86 semantics), so they are computed against the NEXT instruction.
        /// The loop runs as REAL guest code through the normal fetch/execute loop,
        /// so every iteration (and any IRQ0/INT 09h cycles that land mid-spin)
        /// charges its real cycle cost — no ledger hole.
        pub fn emitPollLoop(image: []u8, pos: u32, p: PollLoop) void {
            var w = Emit{ .image = image, .pos = pos };
            // off 0  — L_GET_KEY: STI
            w.byte(OP_STI);
            // off 1  — trap has-key (sets ZF per availability)
            w.byte(OP_TRAP0);
            w.byte(OP_TRAP1);
            w.byte(p.has_key_id);
            // off 4  — JNZ have_key. disp byte @5, next instr @6, target @10:
            //          rel8 = 10 - 6 = 4.
            w.byte(OP_JNZ_REL8);
            w.byte(4);
            // off 6  — INT 09h (the keyboard ISR that fetches/cooks a key)
            w.byte(OP_INT_IMM);
            w.byte(INT_KBD_ISR);
            // off 8  — JMP short L_GET_KEY. disp byte @9, next instr @10, target
            //          @0: rel8 = 0 - 10 = -10 (0xF6).
            w.byte(OP_JMP_REL8);
            w.byte(@bitCast(@as(i8, -10)));
            // off 10 — have_key: trap dequeue (AX = cooked word)
            w.byte(OP_TRAP0);
            w.byte(OP_TRAP1);
            w.byte(p.dequeue_id);
            // off 13 — IRET (return to the INT 16h caller)
            w.byte(OP_IRET);
            std.debug.assert(w.pos - pos == POLL_LOOP_LEN);
        }

        /// The total byte length of the INT 16h hybrid preamble that precedes the
        /// poll loop (`emitInt16Hybrid`). The preamble branches on AH: AH=00/10 fall
        /// through to the embedded poll loop, every other AH traps the host
        /// `int16.handle` and IRETs.
        pub const INT16_PREAMBLE_LEN: u16 = 14;
        /// The total byte length of the whole INT 16h hybrid block (preamble + the
        /// embedded poll loop). The INT 16h IVT vector points at the START of this.
        pub const INT16_HYBRID_LEN: u16 = INT16_PREAMBLE_LEN + POLL_LOOP_LEN;

        /// Physical address of the INT 16h hybrid block within the BIOS ROM image —
        /// placed immediately AFTER the callback-slot table (which spans
        /// `CB_BASE_PHYS .. CB_BASE_PHYS + CB_MAX*CB_SLOT_SIZE`). It is a fixed,
        /// paragraph-aligned region of real guest code the INT 16h vector targets.
        pub const INT16_HYBRID_PHYS: u32 = CB_BASE_PHYS + @as(u32, CB_MAX) * CB_SLOT_SIZE;

        comptime {
            // The hybrid block must fit inside the BIOS ROM window after the slots.
            std.debug.assert(INT16_HYBRID_PHYS >= CB_BASE_PHYS + @as(u32, CB_MAX) * CB_SLOT_SIZE);
            std.debug.assert(INT16_HYBRID_PHYS + INT16_HYBRID_LEN <= 0x100000);
        }

        /// The seg:off of the INT 16h hybrid block (the INT 16h vector target).
        pub fn int16HybridSegOff() struct { seg: u16, off: u16 } {
            return .{ .seg = CB_SEG, .off = @intCast(INT16_HYBRID_PHYS - (@as(u32, CB_SEG) << 4)) };
        }

        /// The EXEC "return into the child" RETF stub (a single `0xCB`) — the
        /// faithful analogue of dosbox `dos_execute.cpp:557` ("Jump to retf so that
        /// we only need to store cs:ip on the stack"). `loader.exec` pushes the
        /// child entry CS:IP onto the CHILD stack and points CS:IP here; the RETF
        /// pops that frame and the child's first instruction is the next thing the
        /// (controller-owned) step loop fetches — NO nested host loop, so every
        /// child instruction is visible to the debugger between-steps scan. Placed
        /// in the BIOS ROM image immediately AFTER the INT 16h hybrid block (real
        /// guest code at a fixed, paragraph-stable address; D4 faithfulness).
        pub const EXEC_RETF_PHYS: u32 = INT16_HYBRID_PHYS + INT16_HYBRID_LEN;

        comptime {
            // The 1-byte RETF stub must fit inside the BIOS ROM window after the
            // hybrid block.
            std.debug.assert(EXEC_RETF_PHYS + 1 <= 0x100000);
        }

        /// The seg:off of the EXEC RETF stub (the CS:IP `loader.exec` redirects to).
        pub fn execRetfSegOff() struct { seg: u16, off: u16 } {
            return .{ .seg = CB_SEG, .off = @intCast(EXEC_RETF_PHYS - (@as(u32, CB_SEG) << 4)) };
        }

        /// Plant the single `RETF` byte of the EXEC return stub into `image` (the
        /// BIOS ROM image). Call alongside `plantAll`/`emitInt16Hybrid` in `post`,
        /// before `loadRom`, so it is real guest code at `EXEC_RETF_PHYS`.
        pub fn emitExecRetf(image: []u8) void {
            image[EXEC_RETF_PHYS - IMAGE_BASE] = OP_RETF;
        }

        // -------------------------------------------------------------------
        // The INT 74h (IRQ12) mouse-callback trampoline (Option C — the faithful
        // PS/2-mouse-ISR shape that makes the INT 33h AX=0Ch handler FOREGROUND
        // and so breakpointable). Planted in the BIOS ROM image immediately after
        // the EXEC RETF stub; IVT[0x74] is pointed at INT74_ENTRY in POST. The
        // driver raises IRQ12; `serviceInterrupts` delivers INT 74h at the next
        // IF=1 boundary through the IVT, so the whole trampoline (incl. the user
        // handler) runs on the ONE controller-owned step loop. See
        // docs/callback-observability-plan.md §3.
        //
        //   INT74_ENTRY:                  ; IVT[0x74] -> here. CPU pushed FLAGS/CS/IP, IF=0.
        //     PUSHA                       ; 60   save foreground GP regs (ISR discipline)
        //     PUSH DS                     ; 1E
        //     PUSH ES                     ; 06
        //     <trap int74_prep_id>        ; FE 38 id   host Int33.prepareInt74(cpu)
        //     RETF                        ; CB   enter the user handler (or fall to EOI_STUB)
        //   EOI_STUB:                     ; the user handler's RETF returns here
        //     POP ES                      ; 07
        //     POP DS                      ; 1F
        //     POPA                        ; 61   restore the foreground GP regs
        //     PUSH AX                     ; 50   preserve AL across the EOI MOV
        //     MOV AL,0x20                 ; B0 20
        //     OUT 0xA0,AL                 ; E6 A0  slave EOI
        //     OUT 0x20,AL                 ; E6 20  master cascade EOI
        //     POP AX                      ; 58
        //     IRET                        ; CF   unwind the INT 74h frame; restores IF
        pub const INT74_PHYS: u32 = EXEC_RETF_PHYS + 1;
        /// Byte length of the whole trampoline (entry + EOI stub).
        pub const INT74_LEN: u16 = 19;
        /// Offset of EOI_STUB within the trampoline: PUSHA(1)+PUSH DS(1)+PUSH ES(1)+
        /// trap(3)+RETF(1) = 7.
        pub const INT74_EOI_STUB_OFFSET: u16 = 7;

        comptime {
            // The multi-byte trampoline must fit inside the BIOS ROM window after
            // the EXEC RETF stub (mirrors the EXEC_RETF_PHYS placement assert).
            std.debug.assert(INT74_PHYS + INT74_LEN <= 0x100000);
        }

        /// The seg:off of INT74_ENTRY (the IVT[0x74] target).
        pub fn int74SegOff() struct { seg: u16, off: u16 } {
            return .{ .seg = CB_SEG, .off = @intCast(INT74_PHYS - (@as(u32, CB_SEG) << 4)) };
        }
        /// The seg:off of EOI_STUB (the far-return target the prep trap pushes — the
        /// user handler's RETF lands here, OR the RETF lands here directly in the
        /// no-event / no-handler no-op-delivery case).
        pub fn int74EoiStubSegOff() struct { seg: u16, off: u16 } {
            return .{ .seg = CB_SEG, .off = @intCast(INT74_PHYS + INT74_EOI_STUB_OFFSET - (@as(u32, CB_SEG) << 4)) };
        }

        /// Emit the INT 74h trampoline into `image` (the BIOS ROM image) at the
        /// fixed `INT74_PHYS`. `prep_id` is the `allocCallback(.iret, .irq)` slot the
        /// embedded `FE 38 id` invokes (its own slot tail is never executed — the
        /// stub continues into RETF — exactly like the poll-loop has-key/dequeue
        /// slots). Call alongside `emitExecRetf` in `post`, before `loadRom`.
        pub fn emitInt74Trampoline(image: []u8, prep_id: u8) void {
            const start = INT74_PHYS - IMAGE_BASE;
            var w = Emit{ .image = image, .pos = start };
            w.byte(OP_PUSHA);
            w.byte(OP_PUSH_DS);
            w.byte(OP_PUSH_ES);
            w.byte(OP_TRAP0);
            w.byte(OP_TRAP1);
            w.byte(prep_id);
            w.byte(OP_RETF);
            // EOI_STUB (offset 7): unwind the saved context, then EOI slave+master.
            w.byte(OP_POP_ES);
            w.byte(OP_POP_DS);
            w.byte(OP_POPA);
            w.byte(OP_PUSH_AX);
            w.byte(OP_MOV_AL_IMM);
            w.byte(EOI);
            w.byte(OP_OUT_IMM_AL);
            w.byte(PIC2_CMD); // OUT 0xA0,AL — slave EOI
            w.byte(OP_OUT_IMM_AL);
            w.byte(PIC1_CMD); // OUT 0x20,AL — master cascade EOI
            w.byte(OP_POP_AX);
            w.byte(OP_IRET);
            std.debug.assert(w.pos - start == INT74_LEN);
        }

        /// Parameters for the INT 16h host/guest-asm HYBRID block (Phase 1d).
        pub const Int16Hybrid = struct {
            /// Callback id of the host `int16.handle` (the AH=01/02/05/11/12/... path).
            host_id: u8,
            /// Callback id whose handler sets the LIVE ZF (`cpu.st.eflags.zf`) — 0
            /// when a key is available, 1 when the ring is empty (poll-loop has-key).
            has_key_id: u8,
            /// Callback id whose handler dequeues the cooked word into AX (poll-loop).
            dequeue_id: u8,
        };

        /// Emit the INT 16h host/guest-asm HYBRID block into `image` at byte offset
        /// `pos` (relative to the start of `image`). The INT 16h IVT vector points
        /// at `pos`; on a real guest `INT 16h` the CPU has already pushed the
        /// FLAGS/CS/IP frame and AH holds the requested service. The preamble
        /// branches on AH (spice86 `KeyboardInt16Handler.cs:168-206` splits exactly
        /// this way: AH=00/10 run the guest-asm `INT 09h` loop, AH=01/02/05/11
        /// are host actions):
        ///
        ///   INT16_ENTRY:
        ///     CMP AH, 0x00          ; 80 FC 00 — blocking GET KEYSTROKE
        ///     JZ  L_GET_KEY         ; 74 09    — -> the embedded poll loop
        ///     CMP AH, 0x10          ; 80 FC 10 — blocking enhanced GET
        ///     JZ  L_GET_KEY         ; 74 04
        ///     <trap host_id>        ; FE 38 id — AH=01/02/05/11/12/... -> int16.handle
        ///     IRET                  ; CF       — (host sets regs/ZF/IF on the frame)
        ///   L_GET_KEY:              ; <- the poll loop (STI; has-key; JNZ; INT 09h;
        ///     <emitPollLoop>        ;    JMP back; dequeue; IRET) from emitPollLoop
        ///
        /// The poll loop is embedded so the AH=00/10 path is a straight fall-through
        /// (no extra jump). The whole block is REAL guest code through the normal
        /// fetch/execute loop — the blocking AH=00/10 wait advances emulated time
        /// (IRQ0/INT 1Ch tick, the injected IRQ1→INT 09h delivers the key), charged
        /// cycle-for-cycle, no ledger hole.
        pub fn emitInt16Hybrid(image: []u8, pos: u32, p: Int16Hybrid) void {
            var w = Emit{ .image = image, .pos = pos };
            // off 0  — CMP AH, 0x00
            w.byte(OP_CMP_RM8_IMM8);
            w.byte(MODRM_CMP_AH);
            w.byte(AH_GET_KEYSTROKE);
            // off 3  — JZ L_GET_KEY. disp @4, next instr @5, poll loop @14:
            //          rel8 = 14 - 5 = 9.
            w.byte(OP_JZ_REL8);
            w.byte(9);
            // off 5  — CMP AH, 0x10
            w.byte(OP_CMP_RM8_IMM8);
            w.byte(MODRM_CMP_AH);
            w.byte(AH_GET_ENHANCED);
            // off 8  — JZ L_GET_KEY. disp @9, next instr @10, poll loop @14:
            //          rel8 = 14 - 10 = 4.
            w.byte(OP_JZ_REL8);
            w.byte(4);
            // off 10 — trap host int16.handle (AH=01/02/05/11/12/... path)
            w.byte(OP_TRAP0);
            w.byte(OP_TRAP1);
            w.byte(p.host_id);
            // off 13 — IRET (return to the INT 16h caller; the host handler patched
            //          the FLAGS image — e.g. ZF for AH=01, IF for the poll path)
            w.byte(OP_IRET);
            std.debug.assert(w.pos - pos == INT16_PREAMBLE_LEN);
            // off 14 — L_GET_KEY: the embedded poll loop (AH=00/10 fall through here).
            emitPollLoop(image, pos + INT16_PREAMBLE_LEN, .{
                .has_key_id = p.has_key_id,
                .dequeue_id = p.dequeue_id,
            });
            std.debug.assert(w.pos + POLL_LOOP_LEN - pos == INT16_HYBRID_LEN);
        }

        /// Plant ALL allocated stubs into `image` (the BIOS ROM image). Call once
        /// after every module has registered its callbacks, before `loadRom`
        /// (Phase 2 POST order). The re-entrancy trampoline is planted SEPARATELY
        /// into conventional RAM via `plantTrampoline` (it must be writable).
        pub fn plantAll(self: *Self, image: []u8) void {
            var id: u8 = 0;
            while (id < self.count) : (id += 1) self.plantStub(image, id);
        }

        /// Plant the `INT nn; 0xFE 0x38 <stop_id>` trampoline (D3) into conventional
        /// RAM via the bus (NOT the ROM image — the `nn` immediate is patched per
        /// `runGuestInt` call). Call AFTER reset (which zeros RAM) — the machine
        /// calls this in `post`.
        pub fn plantTrampoline(self: *Self) void {
            const b = self.cpu.bus;
            b.writePhys8(self.tramp_phys, OP_INT_IMM);
            b.writePhys8(self.tramp_phys + 1, 0x00); // placeholder; patched per call
            b.writePhys8(self.tramp_phys + 2, OP_TRAP0);
            b.writePhys8(self.tramp_phys + 3, OP_TRAP1);
            b.writePhys8(self.tramp_phys + 4, self.stop_id);
        }

        /// Point IVT[intnum] (guest RAM at intnum*4) at `id`'s slot seg:off (D4).
        /// AH=25/35 read/write the SAME guest-RAM IVT, so a guest that hooks a
        /// vector sees the exact bytes the bridge wrote (single source of truth).
        pub fn setRealVec(self: *Self, id: u8, intnum: u8) void {
            const so = slotSegOff(id);
            const addr: u32 = @as(u32, intnum) * 4;
            self.cpu.bus.writePhys16(addr, so.off);
            self.cpu.bus.writePhys16(addr + 2, so.seg);
        }

        // -------------------------------------------------------------------
        // The synthetic cost (D5) — charged by the Services CallbackSink before
        // the handler. Exposed here so the cost contract has ONE source.
        // -------------------------------------------------------------------

        /// Charge the fixed base cost for `id` (rule 1). Returns the per-byte rate
        /// so the handler can add the work-proportional increment (rule 2).
        pub fn chargeBase(self: *Self, id: u8) u64 {
            const c = cb_cost.costFor(self.slots[id].kind);
            self.cpu.st.cycles += c.base;
            return c.per_byte;
        }

        /// Charge a work-proportional increment of `count * per_byte` (rule 2),
        /// where `count` is a guest-register input (never a host measurement).
        pub fn chargeWork(self: *Self, count: u64, per_byte: u64) void {
            self.cpu.st.cycles += count * per_byte;
        }

        pub fn isStopSentinel(self: *const Self, id: u8) bool {
            return id == self.stop_id;
        }

        // -------------------------------------------------------------------
        // FLAGS-image patch on the IRET frame (D4). The guest stack after the
        // CPU's IVT delivery is IP@SP, CS@SP+2, FLAGS@SP+4 (interrupts.zig push
        // order: FLAGS, CS, IP — so IP is on top). The handler patches FLAGS so
        // the stub's IRET returns the right carry/zero/IF to the guest.
        // -------------------------------------------------------------------

        fn flagsFrameOff(self: *Self) u16 {
            return self.cpu.st.getReg16(@intFromEnum(@import("cpu").state.Reg32.esp)) +% 4;
        }

        /// Set/clear the carry flag in the guest's IRET FLAGS image.
        pub fn setGuestCF(self: *Self, value: bool) void {
            self.patchFlag(0x0001, value);
        }
        /// Set/clear the zero flag.
        pub fn setGuestZF(self: *Self, value: bool) void {
            self.patchFlag(0x0040, value);
        }
        /// Set/clear the interrupt-enable flag.
        pub fn setGuestIF(self: *Self, value: bool) void {
            self.patchFlag(0x0200, value);
        }

        /// Read the carry flag from the guest's IRET FLAGS image (the value the
        /// stub's IRET will restore). Lets a service that delegates to another
        /// service (e.g. AH=6C reusing the AH=3D/3C finish path) learn whether the
        /// delegate set CF without re-deriving success. Defaults to "set" (failed)
        /// if the frame can't be read, the conservative choice.
        pub fn guestCF(self: *Self) bool {
            const off = self.flagsFrameOff();
            const cur = self.cpu.segRead16(.ss, off) catch return true;
            return (cur & 0x0001) != 0;
        }

        fn patchFlag(self: *Self, mask: u16, value: bool) void {
            const off = self.flagsFrameOff();
            const cur = self.cpu.segRead16(.ss, off) catch return;
            const new: u16 = if (value) (cur | mask) else (cur & ~mask);
            self.cpu.segWrite16(.ss, off, new) catch {};
        }

        // -------------------------------------------------------------------
        // Re-entrancy: runGuestInt via a REAL `INT n` trampoline (D3).
        // -------------------------------------------------------------------

        /// Execute a guest `INT intnum` from host code and return when its handler
        /// IRETs (D3). Used by the EXEC path / BIOS-calling-BIOS. Drives the
        /// MACHINE step (injected stepper) so PIT/IRQ events fire during re-entry;
        /// the nested guest instructions charge their REAL cycle cost through the
        /// normal ledger (no separate timing path) — only leaf services add the
        /// synthetic cost, and the stop sentinel is cost-exempt.
        pub fn runGuestInt(self: *Self, intnum: u8) void {
            std.debug.assert(self.step_one != null); // stepper must be wired
            std.debug.assert(self.depth < MAX_DEPTH); // depth guard (D3)
            self.depth += 1;
            defer self.depth -= 1;

            const cpu = self.cpu;
            const Reg32 = @import("cpu").state.Reg32;
            const Seg = @import("cpu").state.Seg;

            // (1) Save CS:IP/SP + the re-entry seam scratch (cpu.dec +
            // instr_start_eip): a nested step runs cpu.dec.reset() and overwrites
            // instr_start_eip, clobbering the outer executeOne's decode scratch.
            const save_cs = cpu.st.selector[@intFromEnum(Seg.cs)];
            const save_cs_base = cpu.st.seg_base[@intFromEnum(Seg.cs)];
            const save_eip = cpu.st.eip;
            const save_sp = cpu.st.getReg16(@intFromEnum(Reg32.esp));
            const save_dec = cpu.dec;
            const save_start_eip = cpu.instr_start_eip;
            const save_done = self.reentry_done;

            // (2) Patch the trampoline's INT immediate to `intnum`; point CS:IP at
            // the trampoline.
            cpu.bus.writePhys8(self.tramp_phys + 1, intnum);
            cpu.loadSegment(.cs, self.tramp_seg);
            cpu.st.eip = self.tramp_off;
            self.reentry_done = false;

            // (3) Drive the re-entry loop through the machine step. The real `INT
            // n` builds its own IRET frame + dispatches through the IVT; when the
            // guest handler IRETs it lands on the trampoline's stop callback ->
            // reentry_done = true -> exit.
            var guard: u64 = 0;
            const max_steps: u64 = 5_000_000; // bounded; flag loudly if exceeded
            while (!self.reentry_done) {
                self.step_one.?(self.step_ctx.?);
                guard += 1;
                if (guard >= max_steps) {
                    std.debug.panic("runGuestInt(0x{X}) did not return within {d} steps", .{ intnum, max_steps });
                }
            }

            // (4) Restore CS:IP/SP + the seam scratch.
            cpu.st.selector[@intFromEnum(Seg.cs)] = save_cs;
            cpu.st.seg_base[@intFromEnum(Seg.cs)] = save_cs_base;
            cpu.st.eip = save_eip;
            cpu.st.setReg16(@intFromEnum(Reg32.esp), save_sp);
            cpu.dec = save_dec;
            cpu.instr_start_eip = save_start_eip;
            self.reentry_done = save_done;
        }

        /// The stop-sentinel handler (D3): sets `reentry_done`. The CPU's Grp4 arm
        /// dispatches this through the Services sink like any callback, but the
        /// cost is `.stop_sentinel` (0, guard-exempt).
        pub fn onStopSentinel(self: *Self) void {
            self.reentry_done = true;
        }
        // NB: the old `runUntil` (a nested host loop that drove a loaded CHILD to
        // termination inside the parent's INT 21h handler) was DELETED in the
        // nested-EXEC de-nest (plans/nested-exec-debug.md). EXEC now returns INTO
        // the child via `emitExecRetf` and the child runs on the ONE controller-
        // owned step loop — so breakpoints/watchpoints/step/pause work inside a
        // child. `runGuestInt` remains: it models the one genuinely re-entrant,
        // bounded host->guest->host call that still needs the handler's RESULT —
        // the INT 23h Ctrl-C handler (`src/dos/int21.zig`) — which EXEC was never
        // an instance of. (The mouse AX=0Ch callback USED to ride a sibling
        // `runGuestFarCall` here; Option C moved it to a real IRQ12/INT 74h
        // foreground trampoline, so that primitive was removed — host-invoked
        // guest code that does NOT need a return value now runs as foreground.)
    };
}

/// A tiny byte emitter into a flat image at an offset (no alloc).
const Emit = struct {
    image: []u8,
    pos: u32,
    fn byte(self: *Emit, b: u8) void {
        self.image[self.pos] = b;
        self.pos += 1;
    }
};

test "slot/trampoline layout fits the BIOS segment" {
    try std.testing.expectEqual(@as(u32, 0xF1000), CB_BASE_PHYS);
    try std.testing.expectEqual(@as(u32, 0xF1000), slotPhysFor(0));
    try std.testing.expectEqual(@as(u32, 0xF1000) + CB_SLOT_SIZE, slotPhysFor(1));
}

fn slotPhysFor(id: u8) u32 {
    return CB_BASE_PHYS + @as(u32, id) * CB_SLOT_SIZE;
}

// A standalone bridge (no CPU needed) for byte-emission tests: plantStub only
// reads self.slots + writes the image; emitPollLoop is a free function.
const cpu_mod = @import("cpu");
const TestBridge = Bridge(cpu_mod.Cpu(cpu_mod.TestBus));

test "plantStub: int1c_chain_eoi_pic1 emits INT 1Ch; EOI(master); IRET (exact bytes)" {
    var br: TestBridge = .{};
    // Reserve an id with the new tail (allocCallback touches no CPU).
    const id = br.allocCallback(.int1c_chain_eoi_pic1, .irq);
    var image = std.mem.zeroes([TestBridge.IMAGE_LEN]u8);
    br.plantStub(&image, id);

    const off: usize = @intCast(slotPhysFor(id) - TestBridge.IMAGE_BASE);
    // 0xFE 0x38 <id> | INT 0x1C | PUSH AX | MOV AL,0x20 | OUT 0x20,AL | POP AX | IRET
    const want = [_]u8{
        0xFE, 0x38, id, // trap stub -> int08.handle (BDA tick)
        0xCD, 0x1C, // INT 1Ch (guest-overridable user timer tick)
        0x50, // PUSH AX
        0xB0, 0x20, // MOV AL,0x20 (EOI)
        0xE6, 0x20, // OUT 0x20,AL (master PIC EOI)
        0x58, // POP AX
        0xCF, // IRET
    };
    try std.testing.expectEqualSlices(u8, &want, image[off .. off + want.len]);
}

test "emitPollLoop: INT 16h blocking shell emits the exact STI/has-key/INT09/JMP/dequeue/IRET bytes" {
    var image = std.mem.zeroes([64]u8);
    const has_key: u8 = 0x11;
    const dequeue: u8 = 0x22;
    TestBridge.emitPollLoop(&image, 7, .{ .has_key_id = has_key, .dequeue_id = dequeue });

    const want = [_]u8{
        0xFB, // STI               (L_GET_KEY)
        0xFE, 0x38, has_key, // trap has-key (ZF=0 if key present)
        0x75, 0x04, // JNZ have_key (+4)
        0xCD, 0x09, // INT 09h
        0xEB, 0xF6, // JMP L_GET_KEY (-10)
        0xFE, 0x38, dequeue, // have_key: trap dequeue -> AX
        0xCF, // IRET
    };
    try std.testing.expectEqual(TestBridge.POLL_LOOP_LEN, @as(u16, want.len));
    try std.testing.expectEqualSlices(u8, &want, image[7 .. 7 + want.len]);
    // Bytes outside the emitted window are untouched (no over-write).
    try std.testing.expectEqual(@as(u8, 0), image[6]);
    try std.testing.expectEqual(@as(u8, 0), image[7 + want.len]);
}

test "emitInt16Hybrid: AH-branch preamble + embedded poll loop emit the exact bytes" {
    var image = std.mem.zeroes([64]u8);
    const host: u8 = 0x33;
    const has_key: u8 = 0x11;
    const dequeue: u8 = 0x22;
    TestBridge.emitInt16Hybrid(&image, 5, .{
        .host_id = host,
        .has_key_id = has_key,
        .dequeue_id = dequeue,
    });

    const want = [_]u8{
        // --- preamble (AH branch) ---
        0x80, 0xFC, 0x00, // CMP AH,0x00
        0x74, 0x09, // JZ L_GET_KEY (+9)
        0x80, 0xFC, 0x10, // CMP AH,0x10
        0x74, 0x04, // JZ L_GET_KEY (+4)
        0xFE, 0x38, host, // trap int16.handle (AH=01/02/05/11/...)
        0xCF, // IRET
        // --- L_GET_KEY: embedded poll loop ---
        0xFB, // STI
        0xFE, 0x38, has_key, // trap has-key (ZF=0 if key present)
        0x75, 0x04, // JNZ have_key (+4)
        0xCD, 0x09, // INT 09h
        0xEB, 0xF6, // JMP L_GET_KEY (-10)
        0xFE, 0x38, dequeue, // have_key: trap dequeue -> AX
        0xCF, // IRET
    };
    try std.testing.expectEqual(TestBridge.INT16_HYBRID_LEN, @as(u16, want.len));
    try std.testing.expectEqualSlices(u8, &want, image[5 .. 5 + want.len]);
    // The JZ at the AH=00 arm lands exactly on L_GET_KEY (the poll-loop STI).
    try std.testing.expectEqual(@as(u8, 0xFB), image[5 + TestBridge.INT16_PREAMBLE_LEN]);
    // Bytes outside the window are untouched.
    try std.testing.expectEqual(@as(u8, 0), image[4]);
    try std.testing.expectEqual(@as(u8, 0), image[5 + want.len]);
}

test "emitInt74Trampoline: PUSHA/PUSH DS/ES; trap; RETF; EOI_STUB emits the exact bytes" {
    var image = std.mem.zeroes([TestBridge.IMAGE_LEN]u8);
    const prep_id: u8 = 0x2A;
    TestBridge.emitInt74Trampoline(&image, prep_id);

    const off: usize = @intCast(TestBridge.INT74_PHYS - TestBridge.IMAGE_BASE);
    const want = [_]u8{
        0x60, // PUSHA
        0x1E, // PUSH DS
        0x06, // PUSH ES
        0xFE, 0x38, prep_id, // trap -> Int33.prepareInt74
        0xCB, // RETF -> the user handler (or straight to EOI_STUB)
        0x07, // EOI_STUB: POP ES
        0x1F, // POP DS
        0x61, // POPA
        0x50, // PUSH AX
        0xB0, 0x20, // MOV AL,0x20
        0xE6, 0xA0, // OUT 0xA0,AL  (slave EOI)
        0xE6, 0x20, // OUT 0x20,AL  (master cascade EOI)
        0x58, // POP AX
        0xCF, // IRET
    };
    try std.testing.expectEqual(TestBridge.INT74_LEN, @as(u16, want.len));
    try std.testing.expectEqualSlices(u8, &want, image[off .. off + want.len]);
    // EOI_STUB sits exactly at the documented offset (the prep trap's RETF target).
    try std.testing.expectEqual(@as(u8, 0x07), image[off + TestBridge.INT74_EOI_STUB_OFFSET]);
    // Bytes outside the emitted window are untouched (no over-write).
    try std.testing.expectEqual(@as(u8, 0), image[off - 1]);
    try std.testing.expectEqual(@as(u8, 0), image[off + want.len]);
}
