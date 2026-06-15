//! The single REAL-SOCKET integration test (opt-in: `zig build test-api-integration`,
//! NOT in the default `test` aggregate). It covers the one piece that cannot be
//! unit-tested: the listener + `net.Server.accept` + `http.Server` over a real
//! localhost TCP socket. It asserts CORRECTNESS of one request — NOT determinism
//! (real socket I/O — port numbers, timing — is not byte-reproducible; determinism
//! is proved by the in-process tests 1-9 below the socket).

const std = @import("std");
const server_mod = @import("server.zig");
const debug = @import("debug");
const cpu_mod = @import("cpu");
const machine_mod = @import("machine");

const Machine = machine_mod.Machine;
const Controller = debug.Controller;
const Server = server_mod.Server;
const net = std.Io.net;
const Reg32 = cpu_mod.state.Reg32;

const PORT: u16 = 39517; // a fixed high port for the opt-in test

const PROG: u32 = 0x0500;
fn loadNopProg(m: *Machine) void {
    const b = &m.bus;
    var i: u32 = 0;
    while (i < 8) : (i += 1) b.writePhys8(PROG + i, 0x90);
    b.writePhys8(PROG + 8, 0xF4);
    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ds, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x7000);
    m.cpu.st.eip = PROG;
}

fn runServer(srv: *Server) void {
    srv.run() catch {};
}

test "real socket: GET /api/status returns valid JSON" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const m = try alloc.create(Machine);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    try m.init(alloc, &.{});
    m.wire();
    loadNopProg(m);
    var ctrl = Controller.init(m);

    var srv = Server.init(alloc, io, &ctrl, PORT, server_mod.LoadRecipe.init(2, "PROG.COM", ""));
    defer srv.deinit();

    const listener = try std.Thread.spawn(.{}, runServer, .{&srv});

    // Connect (retry until the listener is bound).
    const addr: net.IpAddress = .{ .ip4 = .loopback(PORT) };
    var stream: net.Stream = blk: {
        var attempt: usize = 0;
        while (attempt < 200) : (attempt += 1) {
            const s = net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch {
                std.Thread.yield() catch {};
                continue;
            };
            break :blk s;
        }
        srv.shutdown();
        listener.join();
        return error.CouldNotConnect;
    };

    // Send the request.
    {
        var wbuf: [256]u8 = undefined;
        var sw = stream.writer(io, &wbuf);
        try sw.interface.writeAll("GET /api/status HTTP/1.1\r\nHost: localhost\r\n\r\n");
        try sw.interface.flush();
    }

    // Read the response.
    var resp_buf: [4096]u8 = undefined;
    var rbuf: [4096]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    const n = sr.interface.readSliceShort(&resp_buf) catch 0;
    const resp = resp_buf[0..n];

    stream.close(io);
    srv.shutdown();
    listener.join();

    // Assert one correct request: 200 + the status JSON keys.
    try std.testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"runnable\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"cycles\":") != null);
}
