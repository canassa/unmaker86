//! Session-registry + MCP-lifecycle tests (multi-machine plan §10 Phase 3 / §11.2/§11.4),
//! driven IN-PROCESS against a real `SessionRegistry`: each `create` provisions a REAL
//! machine + Controller + queue + worker (booting the committed `examples/HELLO.COM`),
//! so these exercise the full provisioning/teardown path — no socket, no mocks.
//!
//! The load-bearing properties:
//!   - ISOLATION (§11.2): a step/write on session A does not perturb session B (real,
//!     independent machines). Asserted on per-session state at an EXPLICIT comparison
//!     point (cycle / memory byte), never on inter-session timing — the §11.5 rule that
//!     keeps a concurrent test's OUTCOME deterministic even though scheduling is not.
//!   - The minted id FORMAT (`zdos-sess-<seq>`), deterministic from the registry counter.
//!   - ROUTING by id (resolve) + the unknown-id → null contract.
//!   - The resource CAP (`MAX_SESSIONS`) + reuse after a destroy.
//!   - Leak-free create/destroy/teardown (run under `std.testing.allocator`).

const std = @import("std");
const build_options = @import("build_options");
const registry_mod = @import("session_registry.zig");
const session_mod = @import("session.zig");
const q = @import("queue.zig");

const SessionRegistry = registry_mod.SessionRegistry;
const Session = session_mod.Session;
const LoadRecipe = session_mod.LoadRecipe;
const Io = std.Io;

/// A registry over a real Threaded `io` with the committed examples dir mounted, ready to
/// boot `HELLO.COM` into each minted session. Stable-address note: the workers spawned by
/// `create` capture `&session.queue` (heap), NOT `&reg`, so `reg` may be returned by value
/// and used at the caller's address — provided `create` is called AFTER `init` returns.
const Fixture = struct {
    alloc: std.mem.Allocator,
    threaded: *Io.Threaded,
    io: Io,
    dir: Io.Dir,
    reg: SessionRegistry,

    fn init(alloc: std.mem.Allocator) !Fixture {
        const threaded = try alloc.create(Io.Threaded);
        threaded.* = Io.Threaded.init(alloc, .{});
        const io = threaded.io();
        const dir = try Io.Dir.cwd().openDir(io, build_options.examples_dir, .{ .iterate = true });
        var reg = SessionRegistry.init(alloc, io);
        try reg.prealloc();
        return .{ .alloc = alloc, .threaded = threaded, .io = io, .dir = dir, .reg = reg };
    }

    fn recipe(_: *Fixture) LoadRecipe {
        return LoadRecipe.init(2, "HELLO.COM", "");
    }

    fn create(self: *Fixture) !*Session {
        // `create` now returns `{session,id}` (the lifetime fix); these single-threaded
        // tests have no concurrent DELETE, so dereferencing `.session` is safe here.
        const res = try self.reg.create(self.recipe(), self.dir);
        return res.session;
    }

    fn deinit(self: *Fixture) void {
        self.reg.deinit();
        self.dir.close(self.io);
        self.threaded.deinit();
        self.alloc.destroy(self.threaded);
    }
};

/// The live machine cycle of `session`, via its OWN worker (off-worker reads are banned).
fn cyclesOf(session: *Session) u64 {
    var ctx: q.RequestCtx = .{ .cmd = .status };
    return switch (session.queue.submit(&ctx)) {
        .status => |s| s.cycles,
        else => unreachable,
    };
}

/// Read one physical byte of `session`'s machine via its worker.
fn peekByte(session: *Session, phys: u32) u8 {
    var ctx: q.RequestCtx = .{ .cmd = .{ .mem_peek = .{ .phys = phys, .len = 1 } } };
    return switch (session.queue.submit(&ctx)) {
        .mem => |m| m.bytes[0],
        else => unreachable,
    };
}

/// Write one physical byte into `session`'s machine via its worker.
fn pokeByte(session: *Session, phys: u32, val: u8) void {
    var ctx: q.RequestCtx = .{ .cmd = .{ .mem_write = .{ .phys = phys, .len = 1 } } };
    ctx.scratch[0] = val;
    _ = session.queue.submit(&ctx);
}

test "registry: create mints deterministic zdos-sess-<seq> ids in order" {
    var fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit();

    const a = try fx.create();
    const b = try fx.create();
    try std.testing.expectEqualStrings("zdos-sess-0", a.id.slice());
    try std.testing.expectEqualStrings("zdos-sess-1", b.id.slice());
    try std.testing.expectEqual(@as(usize, 2), fx.reg.liveCount());
}

test "registry: two sessions are isolated — a step/write on A never perturbs B" {
    var fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit();

    const a = try fx.create();
    const b = try fx.create();

    // Both machines start at their guest entry; capture B's baseline state.
    const b_cycles0 = cyclesOf(b);
    const phys: u32 = 0x2000; // a scratch RAM byte well inside the slab
    const b_byte0 = peekByte(b, phys);

    // Advance A by one instruction and stamp a byte into A's RAM.
    const a_cycles0 = cyclesOf(a);
    var step_ctx: q.RequestCtx = .{ .cmd = .step };
    _ = a.queue.submit(&step_ctx);
    pokeByte(a, phys, b_byte0 ^ 0xFF); // deliberately a DIFFERENT value than B's

    // A advanced and took the write; B is bit-for-bit unchanged (separate machines).
    try std.testing.expect(cyclesOf(a) > a_cycles0);
    try std.testing.expectEqual(b_cycles0, cyclesOf(b));
    try std.testing.expectEqual(b_byte0, peekByte(b, phys));
    // And A really did take the distinct write (proves we wrote A, not B).
    try std.testing.expectEqual(b_byte0 ^ 0xFF, peekByte(a, phys));
}

test "registry: resolve routes a known id and bumps/release the refcount; unknown → null" {
    var fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit();

    const a = try fx.create();
    const b = try fx.create();

    const ra = fx.reg.resolve("zdos-sess-0") orelse return error.MissingSession;
    try std.testing.expectEqual(a, ra);
    fx.reg.release(ra);

    const rb = fx.reg.resolve("zdos-sess-1") orelse return error.MissingSession;
    try std.testing.expectEqual(b, rb);
    fx.reg.release(rb);

    try std.testing.expect(fx.reg.resolve("zdos-sess-999") == null);
    try std.testing.expect(fx.reg.resolve("nonsense") == null);
}

test "registry: destroy tears a session down and its id stops resolving; reuse works" {
    var fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit();

    _ = try fx.create(); // zdos-sess-0
    const b = try fx.create(); // zdos-sess-1
    try std.testing.expectEqual(@as(usize, 2), fx.reg.liveCount());

    // Destroy A: worker joined, machine freed, id removed.
    try std.testing.expect(fx.reg.destroy("zdos-sess-0"));
    try std.testing.expectEqual(@as(usize, 1), fx.reg.liveCount());
    try std.testing.expect(fx.reg.resolve("zdos-sess-0") == null);

    // B is still alive and routable.
    const rb = fx.reg.resolve("zdos-sess-1") orelse return error.MissingSession;
    try std.testing.expectEqual(b, rb);
    fx.reg.release(rb);

    // Destroying an unknown id is a no-op false; a fresh create mints the NEXT seq (ids
    // are never reused), proving the counter is monotonic across teardown churn.
    try std.testing.expect(!fx.reg.destroy("zdos-sess-0"));
    const c = try fx.create();
    try std.testing.expectEqualStrings("zdos-sess-2", c.id.slice());
}

test "registry: the MAX_SESSIONS cap rejects with SessionLimitReached; a destroy frees a slot" {
    var fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit();

    // Fill to the cap.
    var i: usize = 0;
    while (i < SessionRegistry.MAX_SESSIONS) : (i += 1) _ = try fx.create();
    try std.testing.expectEqual(SessionRegistry.MAX_SESSIONS, fx.reg.liveCount());

    // One past the cap is rejected (the §9 reject-don't-evict behavior).
    try std.testing.expectError(error.SessionLimitReached, fx.create());

    // Freeing a slot lets a new create succeed again.
    try std.testing.expect(fx.reg.destroy("zdos-sess-0"));
    const again = try fx.create();
    try std.testing.expectEqualStrings("zdos-sess-8", again.id.slice()); // seq kept climbing
    try std.testing.expectEqual(SessionRegistry.MAX_SESSIONS, fx.reg.liveCount());
}
