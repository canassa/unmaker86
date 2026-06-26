//! The MCP tool catalog + the arguments→`Command` mapping (M3, mcp-plan.md §2/§4) —
//! PURE: imports `std`, `queue.zig` (`q`), `json_wire.zig` (`wire`), `cpu`, `debug`,
//! `timing`, and `bios.scancodes` exactly like `server.zig`, but NO `Server` and NO
//! machine access. It builds the SAME pointer-free `q.Command` PODs the HTTP handlers
//! build, so MCP and HTTP converge on one worker command set (the anti-drift
//! requirement, §3.2/§9).
//!
//! Phase 2 wires the FULL tool surface (§4). The per-tool VALIDATION/MAPPING that the
//! HTTP `handleX` methods used to own is EXTRACTED here into pure mapper helpers
//! (`mapRegSet`/`mapKey`/`mapMouseScripted`/`mapCpuSpeed`/`mapDisasm`/`buildSearch`),
//! which BOTH the HTTP handler and `buildCommand` call — one copy, zero drift (R4).
//! A mapper failure carries a `{code, message}` (`MapError`): the HTTP handler maps it
//! to `respondError(.bad_request, code, message)`; the MCP layer maps `message` to a
//! JSON-RPC `-32602` (the §6 dividing line — fix the CALL, not the plan).
//!
//! Determinism (CLAUDE prime directive): pure JSON/validation work; no host time, no
//! RNG, no float in any emitted byte (`inputSchema` strings are hand-authored ASCII,
//! §8 option a). The grep over this source is wired in `determinism_test.zig` (§3.6).

const std = @import("std");
const q = @import("queue.zig");
const wire = @import("json_wire.zig");
const cpu_mod = @import("cpu");
const debug = @import("debug");
const timing = @import("timing");
const scancodes = @import("bios").scancodes;

const Reg32 = cpu_mod.Reg32;
const Reg16 = debug.Reg16;
const Reg8 = debug.Reg8;
const Seg = cpu_mod.Seg;

/// One catalog entry. `input_schema` is a hand-authored JSON Schema object literal
/// (already valid JSON), spliced verbatim into the `tools/list` reply (§8 option a).
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

// A reusable "no arguments" schema (an empty, closed object).
const SCHEMA_EMPTY =
    \\{"type":"object","properties":{},"additionalProperties":false}
;

/// The full Phase-2 tool catalog (mcp-plan.md §4). Each row maps 1:1 to a `q.Command`
/// (built in `buildCommand`) — except `load`, whose recipe overlay/persist is
/// server-side (handled in `server.zig:handleMcpToolCall`). Field order is fixed → the
/// `tools/list` reply is byte-stable.
pub const tools = [_]Tool{
    // --- execution control ---
    .{
        .name = "step",
        .description = "Execute exactly one guest instruction and return the StopReason.",
        .input_schema = SCHEMA_EMPTY,
    },
    .{
        .name = "step_n",
        .description = "Execute n guest instructions (or until a stop event) and return the StopReason.",
        .input_schema =
        \\{"type":"object","properties":{"n":{"type":"integer","minimum":1,"description":"instruction count"}},"required":["n"],"additionalProperties":false}
        ,
    },
    .{
        .name = "step_over",
        .description = "Step one instruction, but run a CALL/INT/REP to completion (stepped_into=false when it was run over).",
        .input_schema = SCHEMA_EMPTY,
    },
    .{
        .name = "run",
        .description = "Run the guest until a breakpoint/stop event or the cycle cap. cycle_cap defaults to a large bound (never unbounded).",
        .input_schema =
        \\{"type":"object","properties":{"cycle_cap":{"type":"integer","minimum":1,"description":"max cycles to run before yielding"}},"additionalProperties":false}
        ,
    },
    .{
        .name = "run_to_cycle",
        .description = "Run the guest until the absolute machine cycle count reaches `cycle`.",
        .input_schema =
        \\{"type":"object","properties":{"cycle":{"type":"integer","minimum":0,"description":"absolute target cycle"}},"required":["cycle"],"additionalProperties":false}
        ,
    },
    .{
        .name = "run_to_address",
        .description = "Run the guest until CS:EIP reaches the given linear (physical) address.",
        .input_schema =
        \\{"type":"object","properties":{"linear":{"type":"integer","minimum":0,"description":"linear (physical) target address"}},"required":["linear"],"additionalProperties":false}
        ,
    },
    // --- breakpoints ---
    .{
        .name = "add_breakpoint",
        .description = "Add a breakpoint. kind is a tagged union, e.g. {\"execution_address\":{\"linear\":N}} or {\"cycle\":{\"at_cycle\":N}}.",
        .input_schema =
        \\{"type":"object","properties":{"kind":{"type":"object","description":"the discriminated BreakpointKind"},"one_shot":{"type":"boolean","default":false}},"required":["kind"],"additionalProperties":false}
        ,
    },
    .{
        .name = "remove_breakpoint",
        .description = "Remove the breakpoint with the given id.",
        .input_schema =
        \\{"type":"object","properties":{"id":{"type":"integer","minimum":0,"description":"breakpoint slot id"}},"required":["id"],"additionalProperties":false}
        ,
    },
    .{
        .name = "list_breakpoints",
        .description = "List all breakpoints (id, kind, enabled, one_shot).",
        .input_schema = SCHEMA_EMPTY,
    },
    .{
        .name = "clear_breakpoints",
        .description = "Remove all breakpoints; returns the count removed.",
        .input_schema = SCHEMA_EMPTY,
    },
    // --- cpu / registers ---
    .{
        .name = "read_cpu",
        .description = "Read the full CPU snapshot (registers, segments, flags, EIP, cycles).",
        .input_schema = SCHEMA_EMPTY,
    },
    .{
        .name = "set_register",
        .description = "Set a register/segment/flags. Provide exactly one arm: {reg32|reg16|reg8|seg:{name,value}} or {eip:{value}} or {flags:{cf,zf,...}}.",
        .input_schema =
        \\{"type":"object","oneOf":[{"properties":{"reg32":{"type":"object","properties":{"name":{"type":"string"},"value":{"type":"integer"}},"required":["name","value"]}},"required":["reg32"]},{"properties":{"reg16":{"type":"object","properties":{"name":{"type":"string"},"value":{"type":"integer"}},"required":["name","value"]}},"required":["reg16"]},{"properties":{"reg8":{"type":"object","properties":{"name":{"type":"string"},"value":{"type":"integer"}},"required":["name","value"]}},"required":["reg8"]},{"properties":{"seg":{"type":"object","properties":{"name":{"type":"string"},"value":{"type":"integer"}},"required":["name","value"]}},"required":["seg"]},{"properties":{"eip":{"type":"object","properties":{"value":{"type":"integer"}},"required":["value"]}},"required":["eip"]},{"properties":{"flags":{"type":"object"}},"required":["flags"]}]}
        ,
    },
    // --- memory ---
    .{
        .name = "read_memory",
        .description = "Read len bytes of physical guest memory starting at phys; returns lowercase hex.",
        .input_schema =
        \\{"type":"object","properties":{"phys":{"type":"integer","minimum":0,"description":"physical byte address"},"len":{"type":"integer","minimum":1,"description":"number of bytes to read"}},"required":["phys","len"],"additionalProperties":false}
        ,
    },
    .{
        .name = "write_memory",
        .description = "Write the hex-encoded bytes `data` at physical address phys.",
        .input_schema =
        \\{"type":"object","properties":{"phys":{"type":"integer","minimum":0},"data":{"type":"string","description":"lowercase/uppercase hex, even length"}},"required":["phys","data"],"additionalProperties":false}
        ,
    },
    .{
        .name = "read_memory_seg",
        .description = "Read len bytes from a real-mode seg:off (seg is a segment-register name: cs/ds/es/ss/fs/gs); returns lowercase hex.",
        .input_schema =
        \\{"type":"object","properties":{"seg":{"type":"string","description":"segment register name"},"off":{"type":"integer","minimum":0},"len":{"type":"integer","minimum":1}},"required":["seg","off","len"],"additionalProperties":false}
        ,
    },
    .{
        .name = "write_memory_seg",
        .description = "Write hex-encoded `data` at a real-mode seg:off (seg is a segment-register name).",
        .input_schema =
        \\{"type":"object","properties":{"seg":{"type":"string"},"off":{"type":"integer","minimum":0},"data":{"type":"string","description":"hex, even length"}},"required":["seg","off","data"],"additionalProperties":false}
        ,
    },
    .{
        .name = "search_memory",
        .description = "Search guest RAM for a byte needle. Give exactly one of pattern (hex) or ascii (literal text). Optional start/len window and max hit cap.",
        .input_schema =
        \\{"type":"object","properties":{"pattern":{"type":"string","description":"hex needle (mutually exclusive with ascii)"},"ascii":{"type":"string","description":"literal text needle (mutually exclusive with pattern)"},"start":{"type":"integer","minimum":0},"len":{"type":"integer","minimum":0,"description":"0 = to slab end"},"max":{"type":"integer","minimum":0,"description":"0 = default cap"}},"oneOf":[{"required":["pattern"]},{"required":["ascii"]}],"additionalProperties":false}
        ,
    },
    .{
        .name = "disassemble",
        .description = "Disassemble a window of instructions. Origin precedence: linear, else seg(+off), else the live CS:EIP. count defaults to 16 (1..64).",
        .input_schema =
        \\{"type":"object","properties":{"linear":{"type":"integer","minimum":0,"description":"linear origin (wins over seg)"},"seg":{"type":"integer","minimum":0,"description":"real-mode segment selector"},"off":{"type":"integer","minimum":0,"description":"offset within seg"},"count":{"type":"integer","minimum":1,"maximum":64,"default":16}},"additionalProperties":false}
        ,
    },
    // --- inspection ---
    .{
        .name = "read_screen",
        .description = "Read the active VGA text page (char grid + cursor/mode). attrs=true also returns the per-cell attribute bytes as hex.",
        .input_schema =
        \\{"type":"object","properties":{"attrs":{"type":"boolean","default":false}},"additionalProperties":false}
        ,
    },
    .{
        // Server-special (like `load`): captures the session render buffers and returns an
        // IMAGE content block, so its execution is hand-built in `server.zig`
        // (handleMcpScreenshot), not via `buildCommand`. The schema is still listed here.
        .name = "screenshot",
        .description = "Capture the current video frame as a PNG, returned as an image content block (base64, mimeType image/png). A video mode with no faithful rasterizer returns an isError result rather than a fabricated frame.",
        .input_schema = SCHEMA_EMPTY,
    },
    .{
        .name = "read_devices",
        .description = "Read the grouped chipset/A20/device snapshot. palette=true widens the VGA DAC palette; device selects one group (a20/pic/pit/vga/kbc/speaker/opl/ems).",
        .input_schema =
        \\{"type":"object","properties":{"palette":{"type":"boolean","default":false},"device":{"type":"string","enum":["a20","pic","pit","vga","kbc","speaker","opl","ems"]}},"additionalProperties":false}
        ,
    },
    .{
        .name = "read_stack",
        .description = "Read `count` 16-bit words from the top of the guest stack (SS:SP).",
        .input_schema =
        \\{"type":"object","properties":{"count":{"type":"integer","minimum":0,"maximum":65535}},"required":["count"],"additionalProperties":false}
        ,
    },
    .{
        .name = "read_ivt",
        .description = "Read one real-mode interrupt vector (0..255): returns its segment:offset.",
        .input_schema =
        \\{"type":"object","properties":{"vector":{"type":"integer","minimum":0,"maximum":255}},"required":["vector"],"additionalProperties":false}
        ,
    },
    .{
        .name = "read_console",
        .description = "Read the guest's accumulated CON (stdout/stderr) output as hex; side-effect-free (no clear-on-read).",
        .input_schema = SCHEMA_EMPTY,
    },
    .{
        .name = "read_io_port",
        .description = "Read the non-mutating shadow of one I/O port (never issues a live, stateful IN).",
        .input_schema =
        \\{"type":"object","properties":{"port":{"type":"integer","minimum":0,"maximum":65535}},"required":["port"],"additionalProperties":false}
        ,
    },
    // --- input injection (scripted/deterministic) ---
    .{
        .name = "input_key",
        .description = "Inject a keyboard key. Give exactly one of scancode (raw set-1, with make/ext) or char (a single ASCII char, resolved to its scancode).",
        .input_schema =
        \\{"type":"object","properties":{"scancode":{"type":"integer","minimum":0,"maximum":255},"char":{"type":"string","minLength":1,"maxLength":1},"make":{"type":"boolean","default":true},"ext":{"type":"boolean","default":false}},"additionalProperties":false}
        ,
    },
    .{
        .name = "input_mouse",
        .description = "Inject a scripted/deterministic mouse event: absolute x/y, relative dx/dy (mutually exclusive per axis), and/or a buttons mask. At least one field required.",
        .input_schema =
        \\{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"dx":{"type":"integer"},"dy":{"type":"integer"},"buttons":{"type":"integer","minimum":0}},"additionalProperties":false}
        ,
    },
    // --- clock / lifecycle ---
    .{
        .name = "get_clock",
        .description = "Read the active CPU:PIT multiplier and the derived cpu_hz / MHz / pacer slice.",
        .input_schema = SCHEMA_EMPTY,
    },
    .{
        .name = "set_clock",
        .description = "Set the CPU speed. Give exactly one of mult (the CPU:PIT multiplier) or mhz (converted to the nearest mult). The worker clamps to [1, max_mult].",
        .input_schema =
        \\{"type":"object","properties":{"mult":{"type":"integer","minimum":1},"mhz":{"type":"integer","minimum":1}},"additionalProperties":false}
        ,
    },
    .{
        .name = "reset",
        .description = "Reset the machine to its post-boot state (clears guest RAM/CPU; re-load a program with `load`).",
        .input_schema = SCHEMA_EMPTY,
    },
    .{
        .name = "load",
        .description = "Load a program via the server-held recipe; any of drive/file/cmdtail overlays + persists the recipe, then (re)loads.",
        .input_schema =
        \\{"type":"object","properties":{"drive":{"type":"integer","minimum":0,"maximum":255},"file":{"type":"string"},"cmdtail":{"type":"string"}},"additionalProperties":false}
        ,
    },
    .{
        .name = "status",
        .description = "Read the run status: runnable, terminated, ret_code, cycles, last_stop.",
        .input_schema = SCHEMA_EMPTY,
    },
};

/// Look up a tool by name (`null` if not in the catalog → `-32602` at the caller).
pub fn find(name: []const u8) ?*const Tool {
    for (&tools) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

/// Emit the `tools/list` result VALUE: `{"tools":[{name,description,inputSchema},...]}`.
/// `inputSchema` is spliced as a raw JSON object literal (already valid JSON); the
/// `name`/`description` strings are escaped via std.json (descriptions carry quotes).
pub fn writeToolsList(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("{\"tools\":[");
    for (&tools, 0..) |*t, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try std.json.Stringify.encodeJsonString(t.name, .{}, w);
        try w.writeAll(",\"description\":");
        try std.json.Stringify.encodeJsonString(t.description, .{}, w);
        try w.writeAll(",\"inputSchema\":");
        try w.writeAll(t.input_schema);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

// ===========================================================================
// Serialization options the inner tool body needs (mcp-plan.md §3.2). Threaded from
// `buildCommand` through `BuildResult.command.opts` to `server.zig:writeResponseBody`
// so the MCP front-end reproduces the per-route flags the HTTP routes parse from the
// path/query (`?attrs`, `?palette`, `/api/device/<name>`, the search `pattern` echo).
// ===========================================================================

pub const RespondOpts = struct {
    /// `read_screen {attrs}` → emit the per-cell attribute hex array.
    want_attrs: bool = false,
    /// `read_devices {palette}` → widen the VGA DAC palette.
    want_palette: bool = false,
    /// `read_devices {device}` → serialize one group instead of the whole snapshot.
    device: ?[]const u8 = null,
    /// `search_memory` → the decoded needle (lives in `RequestCtx.scratch`), echoed as
    /// the `pattern` hex in the result. Empty for every other tool.
    search_needle: []const u8 = &.{},
};

// ===========================================================================
// Shared mapper failure type + result (resolves R4): the ONE copy of each tool's
// validation/mapping, called by BOTH the HTTP `handleX` and `buildCommand`.
// ===========================================================================

/// A validation failure. `code` is the stable HTTP error-body code string (always under
/// a 400 in the HTTP path); `message` is the human detail (the MCP `-32602` text).
pub const MapError = struct { code: []const u8, message: []const u8 };

pub fn MapResult(comptime T: type) type {
    return union(enum) { ok: T, fail: MapError };
}

const bad_name: MapError = .{ .code = "bad_request", .message = "unknown register/segment name" };

/// `set_register`: resolve the enum NAME → typed enum and range-check the value to the
/// register width (the EXTRACTED `handleRegSet` body — server.zig + buildCommand share
/// this). The overflow check precedes the name lookup, matching the HTTP order.
pub fn mapRegSet(r: wire.RegSetReq) MapResult(q.RegSetCmd) {
    const c: q.RegSetCmd = switch (r) {
        .reg32 => |x| .{ .reg32 = .{
            .reg = std.meta.stringToEnum(Reg32, x.name) orelse return .{ .fail = bad_name },
            .value = x.value,
        } },
        .reg16 => |x| blk: {
            if (x.value > std.math.maxInt(u16)) return .{ .fail = .{ .code = "out_of_range", .message = "value overflows 16-bit register" } };
            break :blk .{ .reg16 = .{
                .reg = std.meta.stringToEnum(Reg16, x.name) orelse return .{ .fail = bad_name },
                .value = @intCast(x.value),
            } };
        },
        .reg8 => |x| blk: {
            if (x.value > std.math.maxInt(u8)) return .{ .fail = .{ .code = "out_of_range", .message = "value overflows 8-bit register" } };
            break :blk .{ .reg8 = .{
                .reg = std.meta.stringToEnum(Reg8, x.name) orelse return .{ .fail = bad_name },
                .value = @intCast(x.value),
            } };
        },
        .seg => |x| blk: {
            if (x.value > std.math.maxInt(u16)) return .{ .fail = .{ .code = "out_of_range", .message = "value overflows segment selector" } };
            break :blk .{ .seg = .{
                .seg = std.meta.stringToEnum(Seg, x.name) orelse return .{ .fail = bad_name },
                .value = @intCast(x.value),
            } };
        },
        .eip => |x| .{ .eip = .{ .value = x.value } },
        .flags => |f| .{ .flags = f.toFlags() },
    };
    return .{ .ok = c };
}

/// `input_key`: resolve scancode-xor-char into the fully-typed `.input_key` command
/// (the EXTRACTED `handleInputKey` body). A char is resolved over the REAL set-1 table
/// (`scancodes.resolveChar`) — never a fabricated map.
pub fn mapKey(r: wire.KeyReq) MapResult(q.Command) {
    if (r.scancode != null and r.char != null) return .{ .fail = .{ .code = "bad_request", .message = "give either scancode or char, not both" } };
    if (r.scancode) |sc| return .{ .ok = .{ .input_key = .{
        .scancode = sc,
        .make = r.make,
        .ext = r.ext,
        .press = false,
        .shift = false,
    } } };
    if (r.char) |ch| {
        if (ch.len != 1) return .{ .fail = .{ .code = "bad_request", .message = "char must be a single ASCII character" } };
        const res = scancodes.resolveChar(ch[0]) orelse return .{ .fail = .{ .code = "bad_request", .message = "no single set-1 scancode for that char" } };
        return .{ .ok = .{ .input_key = .{
            .scancode = res.scancode,
            .make = true,
            .ext = false,
            .press = true,
            .shift = res.shift,
        } } };
    }
    return .{ .fail = .{ .code = "bad_request", .message = "provide scancode or char" } };
}

/// `input_mouse` SCRIPTED path: per-axis mutual exclusion + the `set_*` flag mapping
/// (the EXTRACTED `handleInputMouse` scripted tail). The LIVE coalesced browser path
/// (nx_q16/ny_q16/mdx/mdy) is HTTP-only and stays in `server.zig` — MCP is scripted.
pub fn mapMouseScripted(r: wire.MouseReq) MapResult(q.Command) {
    if (r.x != null and r.dx != null) return .{ .fail = .{ .code = "bad_request", .message = "give either x or dx, not both" } };
    if (r.y != null and r.dy != null) return .{ .fail = .{ .code = "bad_request", .message = "give either y or dy, not both" } };
    if (r.x == null and r.y == null and r.dx == null and r.dy == null and r.buttons == null)
        return .{ .fail = .{ .code = "bad_request", .message = "provide at least one of x/y/dx/dy/buttons" } };
    return .{ .ok = .{ .input_mouse = .{
        .x = r.x orelse 0,
        .y = r.y orelse 0,
        .dx = r.dx orelse 0,
        .dy = r.dy orelse 0,
        .buttons = r.buttons orelse 0,
        .set_x = r.x != null,
        .set_y = r.y != null,
        .set_dx = r.dx != null,
        .set_dy = r.dy != null,
        .set_buttons = r.buttons != null,
    } } };
}

/// `set_clock`: mult-xor-mhz validation + the integer mhz→mult conversion (the
/// EXTRACTED `handleCpuSpeedSet` validation). Returns the REQUESTED mult (the worker
/// clamps to `[1, MAX_MULT]`). INTEGER math only — no host float on the wire.
pub fn mapCpuSpeed(mult: ?u64, mhz: ?u64) MapResult(u64) {
    if (mult != null and mhz != null) return .{ .fail = .{ .code = "bad_request", .message = "give either mult or mhz, not both" } };
    if (mult) |m| {
        if (m == 0) return .{ .fail = .{ .code = "bad_request", .message = "mult must be >= 1" } };
        return .{ .ok = m };
    }
    if (mhz) |mv| {
        if (mv == 0) return .{ .fail = .{ .code = "bad_request", .message = "mhz must be >= 1" } };
        // Clamp `mhz` to the MHz ceiling that already maps PAST `MAX_MULT`, BEFORE the
        // multiply. An unbounded `mv * 1_000_000` overflows u64 for any `mv > ~1.8e13` →
        // a checked-arithmetic panic that kills the whole server (this mapper is shared by
        // MCP `set_clock` AND HTTP `POST /api/cpu/clock`). The worker already clamps the
        // returned mult to `[1, MAX_MULT]`, so every `mhz` at or above the MHz that maps to
        // `MAX_MULT` is INDISTINGUISHABLE after that clamp; bounding `mv` here makes a huge
        // `mhz` clamp EXACTLY like a huge `mult` already does, with no overflow. The ceiling
        // is DERIVED from the timing model — the active CPU rate is `PIT_TICK_RATE * mult`,
        // so `PIT_TICK_RATE * MAX_MULT` = `1_193_182 * 55` ≈ 65.6 MHz ⇒ 66 — never a magic
        // number; in-range values (≤ 66 MHz) are byte-identical to before this clamp.
        const mhz_ceil: u64 = timing.PIT_TICK_RATE * timing.MAX_MULT / 1_000_000 + 1; // ≈ 66
        const mhz_b: u64 = @min(mv, mhz_ceil); // ≤ 66
        const mhz_hz: u64 = mhz_b * 1_000_000; // ≤ 66_000_000 — cannot overflow
        return .{ .ok = (mhz_hz + timing.PIT_TICK_RATE / 2) / timing.PIT_TICK_RATE };
    }
    return .{ .fail = .{ .code = "bad_request", .message = "provide mult or mhz" } };
}

pub const DisasmCmd = struct { origin: debug.DisasmOrigin, count: u16 };

/// `disassemble`: the origin PRECEDENCE (linear > seg(+off) > CS:EIP) + the count bound
/// (1..MAX_DISASM_INSNS). The EXTRACTED decision shared by `handleDisasm` (which parses
/// the query strings per this precedence, then calls here) and `buildCommand`.
pub fn mapDisasm(linear: ?u32, seg: ?u16, off: ?u32, count_opt: ?u32) MapResult(DisasmCmd) {
    const count: u16 = blk: {
        const n = count_opt orelse 16;
        if (n == 0 or n > debug.MAX_DISASM_INSNS) return .{ .fail = .{ .code = "out_of_range", .message = "count must be 1..64" } };
        break :blk @intCast(n);
    };
    const origin: debug.DisasmOrigin = if (linear) |l|
        .{ .linear = l }
    else if (seg) |s|
        .{ .seg_off = .{ .seg = s, .off = off orelse 0 } }
    else
        .cs_eip;
    return .{ .ok = .{ .origin = origin, .count = count } };
}

/// `search_memory`: with the needle already DECODED into `RequestCtx.scratch` (hex vs
/// percent-decode vs JSON literal is transport-specific and stays at the call site),
/// bound-check the window/needle and build the command. Shared by `handleMemSearch`
/// and `buildCommand`.
pub fn buildSearch(needle: []const u8, start: u32, len: u32, max: u32) MapResult(q.MemSearchCmd) {
    if (max > std.math.maxInt(u16)) return .{ .fail = .{ .code = "out_of_range", .message = "max too large" } };
    if (needle.len == 0) return .{ .fail = .{ .code = "bad_request", .message = "empty search pattern" } };
    if (needle.len > q.MAX_SEARCH_NEEDLE) return .{ .fail = .{ .code = "out_of_range", .message = "needle too long" } };
    return .{ .ok = .{
        .start = start,
        .len = len,
        .needle_len = @intCast(needle.len),
        .max = @intCast(max),
    } };
}

/// The `read_devices {device}` selector allowlist — the SINGLE source of truth for the
/// valid device-group names. The pure `buildCommand` (which cannot reach a live snapshot)
/// uses it here to reject an unknown group as `-32602` before dispatch; the typed name→
/// field dispatcher `server.zig:writeNamedDevice` `inline for`s over this SAME list (each
/// name is also its `DevicesSnapshot` field name, reached by `@field`), so the two can
/// never drift. Each name MUST remain a `DevicesSnapshot` field name (the `@field` access).
pub const device_groups = [_][]const u8{ "a20", "pic", "pit", "vga", "kbc", "speaker", "opl", "ems" };

fn isDeviceGroup(name: []const u8) bool {
    for (device_groups) |g| if (std.mem.eql(u8, g, name)) return true;
    return false;
}

// ===========================================================================
// MCP-only argument structs (tools whose HTTP counterpart parses the path/query, so
// there is no existing `wire.*Req`). Pure: parsed via `parseFromValueLeaky`.
// ===========================================================================

const IdReq = struct { id: u32 };
const PortReq = struct { port: u16 };
const ScreenReq = struct { attrs: bool = false };
const DevicesReq = struct { palette: bool = false, device: ?[]const u8 = null };
const DisasmReq = struct { linear: ?u32 = null, seg: ?u16 = null, off: ?u32 = null, count: ?u32 = null };
const SearchReq = struct {
    pattern: ?[]const u8 = null,
    ascii: ?[]const u8 = null,
    start: u32 = 0,
    len: u32 = 0,
    max: u32 = 0,
};

// ===========================================================================
// buildCommand — map `(name, args)` to a `q.Command` (+ debugger flag + RespondOpts).
// ===========================================================================

/// The result of mapping a tool call to a worker command. A `command` is dispatched
/// (and may still come back as an emulator `ErrCode` → an `isError` tool result); an
/// `invalid_params` failure is a VALIDATION error → JSON-RPC `-32602` (the model fixes
/// the CALL, not its plan — mcp-plan.md §6 dividing line).
pub const BuildResult = union(enum) {
    command: struct { cmd: q.Command, needs_debugger: bool = false, opts: RespondOpts = .{} },
    invalid_params: []const u8,
};

/// Map `(name, args)` to a `q.Command` — the MCP counterpart of the per-`handleX`
/// validation/mapping in `server.zig`. `args` is the JSON-RPC `params.arguments`
/// sub-tree (`.null`/`.object`); it is parsed into the matching `*Req` via
/// `parseFromValueLeaky` over `arena` (the per-request arena, reset by the caller).
///
/// `ctx.scratch` holds the decoded byte payload for the hex/needle tools
/// (`write_memory`/`write_memory_seg`/`search_memory`), exactly like the HTTP handlers.
///
/// `load` is NOT handled here: its recipe overlay/persist needs `Server` state, so
/// `server.zig:handleMcpToolCall` builds that command itself (mcp-plan.md §4.4).
pub fn buildCommand(
    arena: std.mem.Allocator,
    name: []const u8,
    args: std.json.Value,
    ctx: *q.RequestCtx,
) BuildResult {
    // --- execution control (debugger-owned for their duration, like the HTTP path) ---
    if (is(name, "step")) return cmd(.step, true);
    if (is(name, "step_over")) return cmd(.step_over, true);
    if (is(name, "step_n")) {
        const r = parse(wire.StepNReq, arena, args) orelse return invalid("step_n expects {n:integer}");
        return cmd(.{ .step_n = .{ .n = r.n } }, true);
    }
    if (is(name, "run")) {
        const default_cap: u64 = 1 << 32;
        var capv: u64 = default_cap;
        if (args == .object) {
            const r = parse(wire.RunReq, arena, args) orelse return invalid("run expects {cycle_cap?:integer}");
            capv = r.cycle_cap orelse default_cap;
        }
        return cmd(.{ .run = .{ .cycle_cap = capv } }, true);
    }
    if (is(name, "run_to_cycle")) {
        const r = parse(wire.RunToCycleReq, arena, args) orelse return invalid("run_to_cycle expects {cycle:integer}");
        return cmd(.{ .run_to_cycle = .{ .cycle = r.cycle } }, true);
    }
    if (is(name, "run_to_address")) {
        const r = parse(wire.RunToAddrReq, arena, args) orelse return invalid("run_to_address expects {linear:integer}");
        return cmd(.{ .run_to_address = .{ .linear = r.linear } }, true);
    }

    // --- breakpoints ---
    if (is(name, "add_breakpoint")) {
        const r = parse(wire.AddBpReq, arena, args) orelse return invalid("add_breakpoint expects {kind:object, one_shot?:bool}");
        return cmd(.{ .add_bp = .{ .kind = r.kind, .one_shot = r.one_shot } }, false);
    }
    if (is(name, "remove_breakpoint")) {
        const r = parse(IdReq, arena, args) orelse return invalid("remove_breakpoint expects {id:integer}");
        return cmd(.{ .remove_bp = .{ .id = r.id } }, false);
    }
    if (is(name, "list_breakpoints")) return cmd(.list_bp, false);
    if (is(name, "clear_breakpoints")) return cmd(.clear_bp, false);

    // --- cpu / registers ---
    if (is(name, "read_cpu")) return cmd(.cpu_get, false);
    if (is(name, "set_register")) {
        const r = parse(wire.RegSetReq, arena, args) orelse return invalid("set_register expects a register union, e.g. {reg32:{name,value}}");
        return switch (mapRegSet(r)) {
            .fail => |e| invalid(e.message),
            .ok => |c| cmd(.{ .reg_set = c }, false),
        };
    }

    // --- memory ---
    if (is(name, "read_memory")) {
        const r = parse(wire.MemPeekReq, arena, args) orelse return invalid("read_memory expects {phys:integer, len:integer}");
        return cmd(.{ .mem_peek = .{ .phys = r.phys, .len = r.len } }, false);
    }
    if (is(name, "write_memory")) {
        const r = parse(wire.MemWriteReq, arena, args) orelse return invalid("write_memory expects {phys:integer, data:hex}");
        const decoded = wire.hexDecode(ctx.scratch[0..], r.data) catch return invalid("invalid hex in data");
        return cmd(.{ .mem_write = .{ .phys = r.phys, .len = @intCast(decoded.len) } }, false);
    }
    if (is(name, "read_memory_seg")) {
        const r = parse(wire.MemPeekSegReq, arena, args) orelse return invalid("read_memory_seg expects {seg:string, off:integer, len:integer}");
        const seg = std.meta.stringToEnum(Seg, r.seg) orelse return invalid("unknown segment name");
        return cmd(.{ .mem_peek_seg = .{ .seg = seg, .off = r.off, .len = r.len } }, false);
    }
    if (is(name, "write_memory_seg")) {
        const r = parse(wire.MemWriteSegReq, arena, args) orelse return invalid("write_memory_seg expects {seg:string, off:integer, data:hex}");
        const seg = std.meta.stringToEnum(Seg, r.seg) orelse return invalid("unknown segment name");
        const decoded = wire.hexDecode(ctx.scratch[0..], r.data) catch return invalid("invalid hex in data");
        return cmd(.{ .mem_write_seg = .{ .seg = seg, .off = r.off, .len = @intCast(decoded.len) } }, false);
    }
    if (is(name, "search_memory")) return buildSearchTool(arena, args, ctx);
    if (is(name, "disassemble")) return buildDisasmTool(arena, args);

    // --- inspection ---
    if (is(name, "read_screen")) {
        var o: RespondOpts = .{};
        if (args == .object) {
            const r = parse(ScreenReq, arena, args) orelse return invalid("read_screen expects {attrs?:bool}");
            o.want_attrs = r.attrs;
        }
        return .{ .command = .{ .cmd = .screen_get, .opts = o } };
    }
    if (is(name, "read_devices")) return buildDevicesTool(arena, args);
    if (is(name, "read_stack")) {
        const r = parse(wire.StackReq, arena, args) orelse return invalid("read_stack expects {count:integer 0..65535}");
        return cmd(.{ .stack_get = .{ .count = r.count } }, false);
    }
    if (is(name, "read_ivt")) {
        const r = parse(wire.IvtReq, arena, args) orelse return invalid("read_ivt expects {vector:integer 0..255}");
        return cmd(.{ .ivt_get = .{ .vector = r.vector } }, false);
    }
    if (is(name, "read_console")) return cmd(.console_get, false);
    if (is(name, "read_io_port")) {
        const r = parse(PortReq, arena, args) orelse return invalid("read_io_port expects {port:integer 0..65535}");
        return cmd(.{ .io_shadow = .{ .port = r.port } }, false);
    }

    // --- input injection (scripted/deterministic) ---
    if (is(name, "input_key")) {
        const r = parse(wire.KeyReq, arena, args) orelse return invalid("input_key expects {scancode?:int, char?:string, make?:bool, ext?:bool}");
        return switch (mapKey(r)) {
            .fail => |e| invalid(e.message),
            .ok => |c| cmd(c, false),
        };
    }
    if (is(name, "input_mouse")) {
        const r = parse(wire.MouseReq, arena, args) orelse return invalid("input_mouse expects {x?,y?,dx?,dy?,buttons?}");
        return switch (mapMouseScripted(r)) {
            .fail => |e| invalid(e.message),
            .ok => |c| cmd(c, false),
        };
    }

    // --- clock / lifecycle ---
    if (is(name, "get_clock")) return cmd(.clock_get, false);
    if (is(name, "set_clock")) {
        const r = parse(wire.CpuSpeedReq, arena, args) orelse return invalid("set_clock expects {mult?:integer} or {mhz?:integer}");
        return switch (mapCpuSpeed(r.mult, r.mhz)) {
            .fail => |e| invalid(e.message),
            .ok => |m| cmd(.{ .set_clock = .{ .mult = m } }, false),
        };
    }
    if (is(name, "reset")) return cmd(.reset, false);
    if (is(name, "status")) return cmd(.status, false);

    // `load` (recipe overlay/persist) and `screenshot` (session render buffers + image
    // response) are server-special — handled before this call, never reaching here.
    return invalid("unknown tool");
}

fn buildSearchTool(arena: std.mem.Allocator, args: std.json.Value, ctx: *q.RequestCtx) BuildResult {
    const r = parse(SearchReq, arena, args) orelse return invalid("search_memory expects {pattern?:hex | ascii?:string, start?, len?, max?}");
    // Exactly one of pattern/ascii (the HTTP `?pattern`/`?ascii` mutual exclusion).
    if ((r.pattern == null) == (r.ascii == null)) return invalid("specify exactly one of pattern/ascii");
    const needle: []const u8 = blk: {
        if (r.pattern) |p| {
            const d = wire.hexDecode(ctx.scratch[0..], p) catch return invalid("invalid hex in pattern");
            break :blk d;
        }
        // ascii: a JSON string literal copies straight into scratch (no percent-decode;
        // that is HTTP-query-only). Bound it so the copy never overruns scratch.
        const a = r.ascii.?;
        if (a.len > ctx.scratch.len) return invalid("needle too long");
        @memcpy(ctx.scratch[0..a.len], a);
        break :blk ctx.scratch[0..a.len];
    };
    return switch (buildSearch(needle, r.start, r.len, r.max)) {
        .fail => |e| invalid(e.message),
        .ok => |c| .{ .command = .{ .cmd = .{ .mem_search = c }, .opts = .{ .search_needle = needle } } },
    };
}

fn buildDisasmTool(arena: std.mem.Allocator, args: std.json.Value) BuildResult {
    var linear: ?u32 = null;
    var seg: ?u16 = null;
    var off: ?u32 = null;
    var count: ?u32 = null;
    if (args == .object) {
        const r = parse(DisasmReq, arena, args) orelse return invalid("disassemble expects {linear?|seg?,off?|count?}");
        linear = r.linear;
        seg = r.seg;
        off = r.off;
        count = r.count;
    }
    return switch (mapDisasm(linear, seg, off, count)) {
        .fail => |e| invalid(e.message),
        .ok => |c| cmd(.{ .disasm = .{ .origin = c.origin, .count = c.count } }, false),
    };
}

fn buildDevicesTool(arena: std.mem.Allocator, args: std.json.Value) BuildResult {
    var o: RespondOpts = .{};
    if (args == .object) {
        const r = parse(DevicesReq, arena, args) orelse return invalid("read_devices expects {palette?:bool, device?:string}");
        o.want_palette = r.palette;
        if (r.device) |dname| {
            if (!isDeviceGroup(dname)) return invalid("unknown device group");
            o.device = dname;
        }
    }
    return .{ .command = .{ .cmd = .devices_get, .opts = o } };
}

fn cmd(c: q.Command, needs_debugger: bool) BuildResult {
    return .{ .command = .{ .cmd = c, .needs_debugger = needs_debugger } };
}

fn invalid(msg: []const u8) BuildResult {
    return .{ .invalid_params = msg };
}

fn is(name: []const u8, lit: []const u8) bool {
    return std.mem.eql(u8, name, lit);
}

/// Parse the `arguments` sub-tree into a `*Req`. Returns `null` on any decode failure
/// (missing required field, wrong type) — the caller maps that to `-32602`.
fn parse(comptime T: type, arena: std.mem.Allocator, args: std.json.Value) ?T {
    return std.json.parseFromValueLeaky(T, arena, args, wire.parse_options) catch null;
}

// ===========================================================================
// Tests
// ===========================================================================

test "find resolves the full catalog and rejects others" {
    try std.testing.expect(find("step") != null);
    try std.testing.expect(find("read_cpu") != null);
    try std.testing.expect(find("set_register") != null);
    try std.testing.expect(find("search_memory") != null);
    try std.testing.expect(find("load") != null);
    try std.testing.expect(find("status") != null);
    try std.testing.expect(find("nope") == null);
}

test "buildCommand maps step/read_cpu with the right debugger flag" {
    var ctx: q.RequestCtx = .{ .cmd = .status };
    const s = buildCommand(std.testing.allocator, "step", .null, &ctx);
    try std.testing.expect(s == .command);
    try std.testing.expect(s.command.cmd == .step);
    try std.testing.expect(s.command.needs_debugger);

    const c = buildCommand(std.testing.allocator, "read_cpu", .null, &ctx);
    try std.testing.expect(c == .command);
    try std.testing.expect(c.command.cmd == .cpu_get);
    try std.testing.expect(!c.command.needs_debugger);
}

test "buildCommand: run/step_n/run_to_* set needs_debugger" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: q.RequestCtx = .{ .cmd = .status };
    const a = arena.allocator();

    const run = buildCommand(a, "run", .null, &ctx);
    try std.testing.expect(run.command.needs_debugger);
    try std.testing.expectEqual(@as(u64, 1 << 32), run.command.cmd.run.cycle_cap);

    const sn = buildCommand(a, "step_n", try jsonValue(a, "{\"n\":5}"), &ctx);
    try std.testing.expect(sn.command.needs_debugger);
    try std.testing.expectEqual(@as(u64, 5), sn.command.cmd.step_n.n);

    const rtc = buildCommand(a, "run_to_cycle", try jsonValue(a, "{\"cycle\":99}"), &ctx);
    try std.testing.expect(rtc.command.needs_debugger);
    try std.testing.expectEqual(@as(u64, 99), rtc.command.cmd.run_to_cycle.cycle);
}

test "buildCommand maps read_memory and rejects a malformed call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: q.RequestCtx = .{ .cmd = .status };

    const ok = buildCommand(arena.allocator(), "read_memory", try jsonValue(arena.allocator(),
        \\{"phys":1024,"len":16}
    ), &ctx);
    try std.testing.expect(ok == .command);
    try std.testing.expectEqual(@as(u32, 1024), ok.command.cmd.mem_peek.phys);
    try std.testing.expectEqual(@as(u32, 16), ok.command.cmd.mem_peek.len);

    const bad = buildCommand(arena.allocator(), "read_memory", .null, &ctx);
    try std.testing.expect(bad == .invalid_params);
}

test "buildCommand write_memory decodes hex into ctx.scratch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: q.RequestCtx = .{ .cmd = .status };
    const r = buildCommand(arena.allocator(), "write_memory", try jsonValue(arena.allocator(),
        \\{"phys":512,"data":"deadbeef"}
    ), &ctx);
    try std.testing.expect(r == .command);
    try std.testing.expectEqual(@as(u32, 512), r.command.cmd.mem_write.phys);
    try std.testing.expectEqual(@as(u32, 4), r.command.cmd.mem_write.len);
    try std.testing.expectEqual(@as(u8, 0xde), ctx.scratch[0]);
    try std.testing.expectEqual(@as(u8, 0xef), ctx.scratch[3]);

    const bad = buildCommand(arena.allocator(), "write_memory", try jsonValue(arena.allocator(),
        \\{"phys":512,"data":"xyz"}
    ), &ctx);
    try std.testing.expect(bad == .invalid_params);
}

test "buildCommand search_memory: exactly-one + needle echo via opts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: q.RequestCtx = .{ .cmd = .status };
    const a = arena.allocator();

    const both = buildCommand(a, "search_memory", try jsonValue(a, "{\"pattern\":\"aa\",\"ascii\":\"x\"}"), &ctx);
    try std.testing.expect(both == .invalid_params);

    const neither = buildCommand(a, "search_memory", try jsonValue(a, "{}"), &ctx);
    try std.testing.expect(neither == .invalid_params);

    const okp = buildCommand(a, "search_memory", try jsonValue(a, "{\"pattern\":\"cafe\"}"), &ctx);
    try std.testing.expect(okp == .command);
    try std.testing.expectEqual(@as(u16, 2), okp.command.cmd.mem_search.needle_len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xca, 0xfe }, okp.command.opts.search_needle);

    const oka = buildCommand(a, "search_memory", try jsonValue(a, "{\"ascii\":\"Hi\"}"), &ctx);
    try std.testing.expect(oka == .command);
    try std.testing.expectEqualSlices(u8, "Hi", oka.command.opts.search_needle);
}

test "mapRegSet: enum resolution + width range checks" {
    try std.testing.expect(mapRegSet(.{ .reg32 = .{ .name = "eax", .value = 0x1234 } }) == .ok);
    try std.testing.expect(mapRegSet(.{ .reg32 = .{ .name = "nope", .value = 1 } }) == .fail);
    const ovf = mapRegSet(.{ .reg8 = .{ .name = "al", .value = 256 } });
    try std.testing.expect(ovf == .fail);
    try std.testing.expectEqualStrings("out_of_range", ovf.fail.code);
}

test "mapDisasm: precedence + count bound" {
    const lin = mapDisasm(0x1000, 0x10, 0x20, 4);
    try std.testing.expect(lin.ok.origin == .linear);
    try std.testing.expectEqual(@as(u16, 4), lin.ok.count);
    const seg = mapDisasm(null, 0x10, 0x20, null);
    try std.testing.expect(seg.ok.origin == .seg_off);
    try std.testing.expectEqual(@as(u16, 16), seg.ok.count);
    const eip = mapDisasm(null, null, null, null);
    try std.testing.expect(eip.ok.origin == .cs_eip);
    try std.testing.expect(mapDisasm(null, null, null, 0) == .fail);
    try std.testing.expect(mapDisasm(null, null, null, 65) == .fail);
}

test "mapCpuSpeed: mult-xor-mhz + integer conversion" {
    try std.testing.expectEqual(@as(u64, 12), mapCpuSpeed(12, null).ok);
    try std.testing.expect(mapCpuSpeed(12, 5) == .fail);
    try std.testing.expect(mapCpuSpeed(0, null) == .fail);
    try std.testing.expect(mapCpuSpeed(null, 0) == .fail);
    try std.testing.expect(mapCpuSpeed(null, null) == .fail);
    // mhz>=1 always rounds to a mult >= 1.
    try std.testing.expect(mapCpuSpeed(null, 14).ok >= 1);
}

test "buildDevicesTool: device allowlist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = buildDevicesTool(a, try jsonValue(a, "{\"device\":\"pic\",\"palette\":true}"));
    try std.testing.expect(ok == .command);
    try std.testing.expectEqualStrings("pic", ok.command.opts.device.?);
    try std.testing.expect(ok.command.opts.want_palette);
    const bad = buildDevicesTool(a, try jsonValue(a, "{\"device\":\"nope\"}"));
    try std.testing.expect(bad == .invalid_params);
}

test "buildCommand rejects an unknown tool" {
    var ctx: q.RequestCtx = .{ .cmd = .status };
    const r = buildCommand(std.testing.allocator, "frobnicate", .null, &ctx);
    try std.testing.expect(r == .invalid_params);
}

fn jsonValue(arena: std.mem.Allocator, s: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, s, wire.parse_options);
}
