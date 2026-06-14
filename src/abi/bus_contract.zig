//! The comptime Bus contract (the CPU's only memory/port interface), plus the
//! comptime hook contracts (InterruptController, Scheduler, FaultSink).
//!
//! This is a SHARED LEAF module (B10): both `src/cpu/` and `src/bus/` import it,
//! and neither imports the other — the module graph stays acyclic. It is the
//! single source of truth for the contract so there is no hand-copied mirror to
//! drift (the dropped fallback). `src/cpu/bus.zig` re-exports these so existing
//! CPU call sites are unchanged; `src/bus/bus.zig` calls `assertBusContract(Bus)`
//! at comptime so `zig build test-bus` catches contract drift at the bus's own
//! layer.
//!
//! The CPU is generic over these at comptime so the per-instruction memory path
//! inlines to zero cost (no runtime vtable). Each contract is verified
//! independently with `@hasDecl`/`@TypeOf` and a `@compileError` on a mismatch.

const std = @import("std");

/// Verify that `Bus` implements the physical-memory + port contract.
///
/// readPhys* never fails (DECIDED Bus error model): physical access always
/// succeeds; unmapped reads return a deterministic fill (the bus's job per
/// CLAUDE constraint #5). Only CPU-side segmentation produces faults.
pub fn assertBusContract(comptime Bus: type) void {
    assertMethod(Bus, "readPhys8", fn (*Bus, u32) u8);
    assertMethod(Bus, "readPhys16", fn (*Bus, u32) u16);
    assertMethod(Bus, "readPhys32", fn (*Bus, u32) u32);
    assertMethod(Bus, "writePhys8", fn (*Bus, u32, u8) void);
    assertMethod(Bus, "writePhys16", fn (*Bus, u32, u16) void);
    assertMethod(Bus, "writePhys32", fn (*Bus, u32, u32) void);
    assertMethod(Bus, "portIn8", fn (*Bus, u16) u8);
    assertMethod(Bus, "portIn16", fn (*Bus, u16) u16);
    assertMethod(Bus, "portIn32", fn (*Bus, u16) u32);
    assertMethod(Bus, "portOut8", fn (*Bus, u16, u8) void);
    assertMethod(Bus, "portOut16", fn (*Bus, u16, u16) void);
    assertMethod(Bus, "portOut32", fn (*Bus, u16, u32) void);
}

/// Verify the InterruptController hook (the 8259 handshake, modeled faithfully:
/// IRR/ISR/priority live in the controller, not a one-way push). The CPU
/// recognizes via `getPendingInterrupt()` and acknowledges via `ackIrq()`.
pub fn assertInterruptControllerContract(comptime Pic: type) void {
    // getPendingInterrupt() -> ?u8 : highest-priority pending vector subject to
    // IF/priority, derived from the cycle ledger; null if none.
    assertMethod(Pic, "getPendingInterrupt", fn (*Pic) ?u8);
    // ackIrq(vector) : the acknowledge/EOI handshake so 8259 IRR/ISR/priority
    // stays modeled.
    assertMethod(Pic, "ackIrq", fn (*Pic, u8) void);
}

/// Verify the Scheduler hook (HLT/next-event coordination, D11).
pub fn assertSchedulerContract(comptime Sched: type) void {
    // nextEventCycle() -> u64 : the absolute cycle of the next scheduled event,
    // so the machine can fast-forward emulated time on a "halted" stop_reason.
    assertMethod(Sched, "nextEventCycle", fn (*Sched) u64);
}

/// Verify the fault/shutdown sink (the machine, not the CPU, decides reset
/// policy on triple-fault/shutdown).
pub fn assertFaultSinkContract(comptime Sink: type) void {
    assertMethod(Sink, "onShutdown", fn (*Sink) void);
}

/// Verify the CallbackSink hook (the guest->host callback-trap bridge, D2). The
/// CPU's Grp4 `/7` (`0xFE 0x38 <id>`) arm reads the id byte and calls
/// `sink.dispatchCallback(id)` synchronously, inline in `executeOne`.
///
/// CRITICAL (D2 refined): the contract must NOT name `*Cpu`. This is a shared
/// leaf both `src/cpu/` and `src/bus/` import; it cannot reference the CPU type
/// without inverting the module graph. The `Sink` therefore holds its OWN `*Cpu`
/// (set at wire time by the machine, exactly as the `Services` aggregate is
/// constructed with the CPU pointer), so the signature is only `fn (*Sink, u8)`.
pub fn assertCallbackSinkContract(comptime Sink: type) void {
    assertMethod(Sink, "dispatchCallback", fn (*Sink, u8) void);
}

fn assertMethod(comptime T: type, comptime name: []const u8, comptime Sig: type) void {
    if (!@hasDecl(T, name)) {
        @compileError("Bus contract: type '" ++ @typeName(T) ++
            "' is missing required method '" ++ name ++
            "' with signature " ++ @typeName(Sig));
    }
    const Actual = @TypeOf(@field(T, name));
    if (Actual != Sig) {
        @compileError("Bus contract: method '" ++ name ++ "' on '" ++
            @typeName(T) ++ "' has type " ++ @typeName(Actual) ++
            ", expected " ++ @typeName(Sig));
    }
}

test "assertBusContract accepts a conforming struct" {
    const Ok = struct {
        pub fn readPhys8(_: *@This(), _: u32) u8 {
            return 0;
        }
        pub fn readPhys16(_: *@This(), _: u32) u16 {
            return 0;
        }
        pub fn readPhys32(_: *@This(), _: u32) u32 {
            return 0;
        }
        pub fn writePhys8(_: *@This(), _: u32, _: u8) void {}
        pub fn writePhys16(_: *@This(), _: u32, _: u16) void {}
        pub fn writePhys32(_: *@This(), _: u32, _: u32) void {}
        pub fn portIn8(_: *@This(), _: u16) u8 {
            return 0;
        }
        pub fn portIn16(_: *@This(), _: u16) u16 {
            return 0;
        }
        pub fn portIn32(_: *@This(), _: u16) u32 {
            return 0;
        }
        pub fn portOut8(_: *@This(), _: u16, _: u8) void {}
        pub fn portOut16(_: *@This(), _: u16, _: u16) void {}
        pub fn portOut32(_: *@This(), _: u16, _: u32) void {}
    };
    comptime assertBusContract(Ok);
}
