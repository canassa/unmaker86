//! `src/debug/core/expr.zig` — the M-S3 `evaluate` C-expression evaluator (READ-ONLY).
//!
//! Generalizes the bounded M-S2 `inspect` path grammar (`vars.zig:inspectPath`) to the full
//! C-expression grammar via a Pratt (precedence-climbing) parser over a totally-tokenized,
//! bounded input, then an AST walk with faithful 16-bit-`int` C integer semantics. It reuses
//! the M-S2 resolver/renderer (`vars.zig`: `Cursor`/`Place`, `readMem`/`readReg`, `ptrTarget`,
//! `fieldAccess`/`derefStep`, `signExtend`, `typeSize`, `renderValueAt`) and adds the NEW
//! pieces evaluation needs: the integer-literal type ladder, integer promotion + usual
//! arithmetic conversions, pointer arithmetic, casts, short-circuit `&&`/`||`, the ternary,
//! the UNEVALUATED `sizeof` type pass, and synthesized-scalar/pointer rendering.
//!
//! Determinism (CLAUDE.md §1): a PURE, PEEK-ONLY, ZERO-CYCLE function of the machine state at
//! the stop. Every read is `vars.readMem`/`readReg` → `cpuSnapshot`/`peekMemPhys` (RAM-slab
//! bounds-checked), NEVER a raw guest bus read or a device I/O port; it NEVER executes the guest (function calls
//! are a PARSE-level rejection), never charges cycles, never has a side effect (no `=`/`++`),
//! never touches a host clock/RNG/FLOAT. On the `src/debug` grep gate + a dedicated
//! guest-exec/write-symbol assertion (`determinism_test.zig`), so the peek-only invariant is
//! structurally enforced. The WRITE EFFECT of `set_variable` (M3-b) lives on the WORKER, never
//! here (D1) — this module is strictly read-only.
//!
//! No fabrication (CLAUDE.md §2): a wrong number is the WORST outcome for a debugger. Every
//! form we cannot evaluate faithfully returns a TYPED error (`Unsupported`/`Unresolved`/
//! `NotLvalue`/`TypeError`/`DivByZero`), never a guessed value. The parser is TOTAL and
//! bounded (a parser is an attack surface): every byte is a token or a typed error (no
//! `unreachable`/panic), depth ≤ `MAX_EVAL_DEPTH` at every recursive entry, length ≤
//! `DBG_EXPR_CAP`, an integer literal overflowing `u64` is refused.

const std = @import("std");
const core = @import("core.zig");
const vars = @import("vars.zig");
const debugger = @import("debugger.zig");
const types = @import("../symbols/types.zig");
const format = @import("../symbols/format.zig");

const SourceDebugger = debugger.SourceDebugger;
const Frame = core.Frame;
const Addr = core.Addr;
const Variable = core.Variable;
const Local = types.Local;
const TypeId = format.TypeId;
const PtrKind = types.PtrKind;
const Cursor = vars.Cursor;

/// The honest-degradation vocabulary (mapped to `q.ErrCode` on the worker).
pub const EvalError = error{ Unsupported, Unresolved, NotLvalue, TypeError, DivByZero };

/// Max expression length (mirrors `q.DBG_EXPR_CAP`). A longer input is REJECTED (never
/// truncated — a truncated expression is a different, silently-wrong expression).
pub const DBG_EXPR_CAP: usize = 256;
/// Recursion cap at EVERY recursive entry (parse, eval, and the `sizeof` type pass) — hit
/// before native stack overflow on a deeply-nested `((((…))))`.
pub const MAX_EVAL_DEPTH: u32 = 64;
/// Bounded token / AST-node working sets (no heap). A 256-byte expression cannot exceed these.
const MAX_TOKENS: usize = 512;
const MAX_NODES: usize = 512;

// ─────────────────────────── value / type model (A.3) ───────────────────────────

const Scalar = struct { bits: u8, signed: bool };
const PtrType = struct { pointee: u16, kind: PtrKind, far: bool };

/// The resolved C type of an intermediate value.
const EvalType = union(enum) {
    graph: u16, // a TypeGraph type_ref (identifiers, members, derefs) — always an lvalue
    scalar: Scalar, // a SYNTHESIZED int (literal / arith result / sizeof / cast)
    pointer: PtrType, // a SYNTHESIZED pointer (`&`, cast-to-pointer, pointer arithmetic)
};

const Store = union(enum) {
    lvalue: Cursor, // an addressable object — assignable / address-takeable / navigable
    rvalue: u64, // a materialized bit pattern, width-MASKED to the type width (C4)
};

/// One evaluated value. `terminal`, when set, is a `<null>`/`unreadable`/`outer_frame_register`
/// honest terminal (rendered as-is at top level; a `TypeError` if used as an operand).
const Val = struct {
    ty: EvalType,
    store: Store,
    terminal: ?Variable = null,
};

/// An operand classified for arithmetic: a promoted integer, or a pointer value.
const Kind = union(enum) {
    num: Num,
    ptr: Ptr,
};
/// A promoted integer operand (`bits` ≥ 16), `val` masked to `bits`.
const Num = struct { bits: u8, signed: bool, val: u64 };
/// A pointer operand: `bits` is the pointer representation (near = offset; far = seg<<16|off).
const Ptr = struct { pointee: u16, kind: PtrKind, far: bool, bits: u64 };

// ─────────────────────────── public entry point ───────────────────────────

/// Evaluate C expression `src` in `frame` and render the result into `scratch` as a
/// `core.Variable`. PURE / peek-only / zero-cycle. Errors are typed (never a guessed value).
pub fn evaluate(sd: *SourceDebugger, frame: Frame, src: []const u8, scratch: []u8) EvalError!Variable {
    const v = try evalExpr(sd, frame, src);
    return render(sd, frame, v, src, scratch);
}

/// Parse + evaluate `src` into a `Val` (PURE / peek-only). Shared by `evaluate` (which then
/// renders it) and the M3-b `set_variable` value-as-expression path. A `Val` is self-contained
/// (integers + a `Cursor` of integers + an optional static-string terminal), so it safely
/// outlives the on-stack token/node pools built here.
fn evalExpr(sd: *SourceDebugger, frame: Frame, src: []const u8) EvalError!Val {
    if (src.len > DBG_EXPR_CAP) return error.Unsupported; // P1: reject, never truncate

    var toks: [MAX_TOKENS]Tok = undefined;
    const ntok = try tokenize(src, &toks);

    var pool: NodePool = .{ .toks = toks[0..ntok] };
    var p: Parser = .{ .pool = &pool };
    const root = try p.parseExpr(0, 0);
    // C2: explicit end-of-input — any leftover token is a hard error (no partial eval).
    if (p.peek().kind != .eof) return error.Unsupported;

    var ev: Eval = .{ .sd = sd, .frame = frame, .pool = &pool };
    return ev.eval(root, 0);
}

/// Parse + evaluate `src` and classify the result as a scalar/pointer operand (`Kind`). The
/// M3-b `set_variable` value-as-expression path: an aggregate/array/terminal RHS → a typed
/// error (never a fabricated value).
fn evalScalarExpr(sd: *SourceDebugger, frame: Frame, src: []const u8) EvalError!Kind {
    const v = try evalExpr(sd, frame, src);
    var ev: Eval = .{ .sd = sd, .frame = frame, .pool = undefined }; // classify() never reads pool
    return ev.classify(v);
}

// ─────────────────────────── tokenizer (A.8 — TOTAL, maximal munch) ───────────────────────────

const TokKind = enum {
    int,
    ident,
    // operators used by the grammar
    plus,
    minus,
    star,
    slash,
    percent,
    amp,
    pipe,
    caret,
    tilde,
    bang,
    lt,
    gt,
    le,
    ge,
    eqeq,
    ne,
    shl,
    shr,
    andand,
    oror,
    lparen,
    rparen,
    lbracket,
    rbracket,
    dot,
    arrow,
    question,
    colon,
    // a tokenized-but-REJECTED form (assignment / compound / `++` / `--` / `,` / string /
    // an unknown byte). Any of these anywhere in the grammar → `Unsupported` (never a
    // partial-eval / fabricated result). Kept as ONE kind so tokenization stays total.
    unsupported,
    eof,
};

const Tok = struct {
    kind: TokKind,
    text: []const u8 = "",
    ival: u64 = 0,
    itype: Scalar = .{ .bits = 16, .signed = true },
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}
fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Tokenize `src` into `out`, returning the token count (an `.eof` is appended). TOTAL: every
/// byte becomes a token or a clean `error.Unsupported` — never `unreachable`/panic.
fn tokenize(src: []const u8, out: *[MAX_TOKENS]Tok) EvalError!usize {
    var i: usize = 0;
    var n: usize = 0;
    const emit = struct {
        fn f(o: *[MAX_TOKENS]Tok, cnt: *usize, t: Tok) EvalError!void {
            if (cnt.* >= MAX_TOKENS) return error.Unsupported;
            o[cnt.*] = t;
            cnt.* += 1;
        }
    }.f;
    while (i < src.len) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        // identifier
        if (isIdentStart(c)) {
            const start = i;
            i += 1;
            while (i < src.len and isIdentChar(src[i])) i += 1;
            try emit(out, &n, .{ .kind = .ident, .text = src[start..i] });
            continue;
        }
        // integer literal
        if (std.ascii.isDigit(c)) {
            const tok = try lexInt(src, &i);
            try emit(out, &n, tok);
            continue;
        }
        // char literal → an int (value = the byte)
        if (c == '\'') {
            const tok = try lexChar(src, &i);
            try emit(out, &n, tok);
            continue;
        }
        // string literal → tokenized (consumed) but REJECTED (no production, P4).
        if (c == '"') {
            i += 1;
            while (i < src.len and src[i] != '"') {
                if (src[i] == '\\' and i + 1 < src.len) i += 1;
                i += 1;
            }
            if (i < src.len) i += 1; // closing quote (if any)
            try emit(out, &n, .{ .kind = .unsupported, .text = "\"" });
            continue;
        }
        // operators / punctuation (maximal munch, C2)
        const two: ?u8 = if (i + 1 < src.len) src[i + 1] else null;
        var kind: TokKind = .unsupported;
        var adv: usize = 1;
        switch (c) {
            '+' => {
                if (two == '+') {
                    kind = .unsupported; // `++` — a side effect, never `+(+x)`
                    adv = 2;
                } else if (two == '=') {
                    kind = .unsupported;
                    adv = 2;
                } else kind = .plus;
            },
            '-' => {
                if (two == '-') {
                    kind = .unsupported; // `--`
                    adv = 2;
                } else if (two == '>') {
                    kind = .arrow;
                    adv = 2;
                } else if (two == '=') {
                    kind = .unsupported;
                    adv = 2;
                } else kind = .minus;
            },
            '*' => {
                if (two == '=') {
                    kind = .unsupported;
                    adv = 2;
                } else kind = .star;
            },
            '/' => {
                if (two == '=') {
                    kind = .unsupported;
                    adv = 2;
                } else kind = .slash;
            },
            '%' => {
                if (two == '=') {
                    kind = .unsupported;
                    adv = 2;
                } else kind = .percent;
            },
            '^' => {
                if (two == '=') {
                    kind = .unsupported;
                    adv = 2;
                } else kind = .caret;
            },
            '~' => kind = .tilde,
            '!' => {
                if (two == '=') {
                    kind = .ne;
                    adv = 2;
                } else kind = .bang;
            },
            '&' => {
                if (two == '&') {
                    kind = .andand;
                    adv = 2;
                } else if (two == '=') {
                    kind = .unsupported;
                    adv = 2;
                } else kind = .amp;
            },
            '|' => {
                if (two == '|') {
                    kind = .oror;
                    adv = 2;
                } else if (two == '=') {
                    kind = .unsupported;
                    adv = 2;
                } else kind = .pipe;
            },
            '<' => {
                if (two == '<') {
                    kind = .shl;
                    adv = 2;
                } else if (two == '=') {
                    kind = .le;
                    adv = 2;
                } else kind = .lt;
            },
            '>' => {
                if (two == '>') {
                    kind = .shr;
                    adv = 2;
                } else if (two == '=') {
                    kind = .ge;
                    adv = 2;
                } else kind = .gt;
            },
            '=' => {
                if (two == '=') {
                    kind = .eqeq;
                    adv = 2;
                } else {
                    kind = .unsupported; // assignment — a side effect (use set_variable)
                }
            },
            '(' => kind = .lparen,
            ')' => kind = .rparen,
            '[' => kind = .lbracket,
            ']' => kind = .rbracket,
            '.' => kind = .dot,
            '?' => kind = .question,
            ':' => kind = .colon,
            ',' => kind = .unsupported, // comma operator — sequencing, no side effects here
            else => kind = .unsupported, // any unknown byte
        }
        try emit(out, &n, .{ .kind = kind, .text = src[i .. i + 1] });
        i += adv;
    }
    try emit(out, &n, .{ .kind = .eof });
    return n;
}

/// Lex an integer literal starting at `src[i.*]`, advancing `i`. Applies the C1 type LADDER.
fn lexInt(src: []const u8, i: *usize) EvalError!Tok {
    const start = i.*;
    var base: u8 = 10;
    if (src[i.*] == '0' and i.* + 1 < src.len and (src[i.* + 1] == 'x' or src[i.* + 1] == 'X')) {
        base = 16;
        i.* += 2;
    } else if (src[i.*] == '0' and i.* + 1 < src.len and std.ascii.isDigit(src[i.* + 1])) {
        base = 8;
        i.* += 1;
    }
    const dstart = i.*;
    while (i.* < src.len and isBaseDigit(src[i.*], base)) i.* += 1;
    if (i.* == dstart and base != 8) return error.Unsupported; // e.g. `0x` with no digits
    const digits = if (base == 8) src[dstart - 1 .. i.*] else src[dstart..i.*];
    // suffix: any run of u/U/l/L (maximal munch); a following alnum is a bad token.
    var u_count: u8 = 0;
    var l_count: u8 = 0;
    while (i.* < src.len) {
        switch (src[i.*]) {
            'u', 'U' => u_count += 1,
            'l', 'L' => l_count += 1,
            else => break,
        }
        i.* += 1;
    }
    if (i.* < src.len and isIdentChar(src[i.*])) return error.Unsupported; // e.g. `12ax`
    if (u_count > 1 or l_count > 2) return error.Unsupported;

    const value = std.fmt.parseInt(u64, digits, base) catch return error.Unsupported; // overflow → refuse
    const min_bits: u8 = if (l_count >= 2) 64 else if (l_count == 1) 32 else 16;
    const sc = try litType(value, base == 10, u_count >= 1, min_bits);
    _ = start;
    return .{ .kind = .int, .ival = value, .itype = sc, .text = digits };
}

fn isBaseDigit(c: u8, base: u8) bool {
    return switch (base) {
        16 => std.ascii.isHex(c),
        8 => c >= '0' and c <= '7',
        else => std.ascii.isDigit(c),
    };
}

/// The C1 integer-literal type ladder: the FIRST type on the ladder that represents `value`.
fn litType(value: u64, decimal: bool, uns: bool, min_bits: u8) EvalError!Scalar {
    const ranks = [_]u8{ 16, 32, 64 };
    for (ranks) |r| {
        if (r < min_bits) continue;
        if (!uns and fitsSigned(value, r)) return .{ .bits = r, .signed = true };
        if ((uns or !decimal) and fitsUnsigned(value, r)) return .{ .bits = r, .signed = false };
    }
    return error.Unsupported;
}
fn fitsSigned(value: u64, bits: u8) bool {
    if (bits >= 64) return value <= @as(u64, std.math.maxInt(i64));
    return value <= (@as(u64, 1) << @intCast(bits - 1)) - 1;
}
fn fitsUnsigned(value: u64, bits: u8) bool {
    if (bits >= 64) return true;
    return value <= (@as(u64, 1) << @intCast(bits)) - 1;
}

/// Lex a `'c'` char literal (value = the byte, type int). A multi-char / unterminated literal
/// → `Unsupported` (P4 — never a fabricated multi-byte value).
fn lexChar(src: []const u8, i: *usize) EvalError!Tok {
    i.* += 1; // opening quote
    if (i.* >= src.len) return error.Unsupported;
    var val: u8 = 0;
    if (src[i.*] == '\\') {
        i.* += 1;
        if (i.* >= src.len) return error.Unsupported;
        val = switch (src[i.*]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '0' => 0,
            '\\' => '\\',
            '\'' => '\'',
            '"' => '"',
            else => return error.Unsupported,
        };
        i.* += 1;
    } else {
        val = src[i.*];
        i.* += 1;
    }
    if (i.* >= src.len or src[i.*] != '\'') return error.Unsupported; // multi-char / unterminated
    i.* += 1; // closing quote
    return .{ .kind = .int, .ival = val, .itype = .{ .bits = 16, .signed = true } };
}

// ─────────────────────────── AST + Pratt parser (A.1/A.2) ───────────────────────────

const NodeKind = enum {
    int_lit,
    ident,
    unary,
    binary,
    ternary,
    cast,
    sizeof_expr,
    sizeof_type,
    index,
    member,
};

const TagKind = types.TypeGraph.TagKind;

/// A parsed cast/sizeof type-name: a scalar primitive, `void`, or a struct/union/enum tag,
/// with a pointer-suffix depth. Resolution to a `type_ref` (via `typeRefForTag`/`Primitive`)
/// happens at eval time (needs the type graph).
const TypeName = struct {
    base: union(enum) {
        prim: Scalar,
        void_: void,
        tag: struct { name: []const u8, kind: TagKind },
    },
    ptr_depth: u8 = 0,
};

const Node = struct {
    kind: NodeKind,
    op: TokKind = .eof, // for unary/binary
    a: u32 = 0, // child / lhs / cond / base
    b: u32 = 0, // rhs / then / index
    c: u32 = 0, // ternary else
    ival: u64 = 0, // int_lit value
    itype: Scalar = .{ .bits = 16, .signed = true }, // int_lit type
    name: []const u8 = "", // ident / member name
    arrow: bool = false, // member: `->` vs `.`
    tn: TypeName = undefined, // cast / sizeof_type
};

const NodePool = struct {
    toks: []const Tok,
    nodes: [MAX_NODES]Node = undefined,
    count: u32 = 0,

    fn add(self: *NodePool, node: Node) EvalError!u32 {
        if (self.count >= MAX_NODES) return error.Unsupported;
        self.nodes[self.count] = node;
        self.count += 1;
        return self.count - 1;
    }
    fn get(self: *NodePool, idx: u32) Node {
        return self.nodes[idx];
    }
};

/// The infix binding power (level) of a binary operator (A.2), or null if not infix. Higher
/// = binds tighter. `&` (6) correctly binds BELOW `==` (7) — a validated C subtlety.
fn infixBp(k: TokKind) ?u8 {
    return switch (k) {
        .question => 1,
        .oror => 2,
        .andand => 3,
        .pipe => 4,
        .caret => 5,
        .amp => 6,
        .eqeq, .ne => 7,
        .lt, .gt, .le, .ge => 8,
        .shl, .shr => 9,
        .plus, .minus => 10,
        .star, .slash, .percent => 11,
        else => null,
    };
}

const Parser = struct {
    pool: *NodePool,
    i: usize = 0,

    fn peek(self: *Parser) Tok {
        if (self.i >= self.pool.toks.len) return .{ .kind = .eof };
        return self.pool.toks[self.i];
    }
    fn peekAt(self: *Parser, k: usize) Tok {
        if (self.i + k >= self.pool.toks.len) return .{ .kind = .eof };
        return self.pool.toks[self.i + k];
    }
    fn advance(self: *Parser) Tok {
        const t = self.peek();
        self.i += 1;
        return t;
    }

    /// Precedence climbing: parse an expression binding at ≥ `min_bp`.
    fn parseExpr(self: *Parser, min_bp: u8, depth: u32) EvalError!u32 {
        if (depth > MAX_EVAL_DEPTH) return error.Unsupported;
        var lhs = try self.parseUnary(depth + 1);
        while (true) {
            const op = self.peek().kind;
            const bp = infixBp(op) orelse break;
            if (bp < min_bp) break;
            if (op == .question) {
                _ = self.advance();
                const then_n = try self.parseExpr(0, depth + 1);
                if (self.peek().kind != .colon) return error.Unsupported;
                _ = self.advance();
                const else_n = try self.parseExpr(1, depth + 1); // right-assoc
                lhs = try self.pool.add(.{ .kind = .ternary, .a = lhs, .b = then_n, .c = else_n });
                continue;
            }
            _ = self.advance();
            const rhs = try self.parseExpr(bp + 1, depth + 1); // left-assoc
            lhs = try self.pool.add(.{ .kind = .binary, .op = op, .a = lhs, .b = rhs });
        }
        return lhs;
    }

    fn parseUnary(self: *Parser, depth: u32) EvalError!u32 {
        if (depth > MAX_EVAL_DEPTH) return error.Unsupported;
        const t = self.peek();
        switch (t.kind) {
            .star, .amp, .minus, .plus, .tilde, .bang => {
                _ = self.advance();
                const child = try self.parseUnary(depth + 1);
                return self.pool.add(.{ .kind = .unary, .op = t.kind, .a = child });
            },
            .ident => {
                if (std.mem.eql(u8, t.text, "sizeof")) {
                    _ = self.advance();
                    // `sizeof ( typename )` (unevaluated) vs `sizeof unary`.
                    if (self.peek().kind == .lparen and self.startsTypeName(1)) {
                        _ = self.advance(); // (
                        const tn = try self.parseTypeName(depth + 1);
                        if (self.peek().kind != .rparen) return error.Unsupported;
                        _ = self.advance();
                        return self.pool.add(.{ .kind = .sizeof_type, .tn = tn });
                    }
                    const child = try self.parseUnary(depth + 1);
                    return self.pool.add(.{ .kind = .sizeof_expr, .a = child });
                }
                return self.parsePostfix(try self.parsePrimary(depth + 1), depth + 1);
            },
            .lparen => {
                // cast `( typename ) unary` vs a parenthesized expression.
                if (self.startsTypeName(1)) {
                    _ = self.advance(); // (
                    const tn = try self.parseTypeName(depth + 1);
                    if (self.peek().kind != .rparen) return error.Unsupported;
                    _ = self.advance();
                    const child = try self.parseUnary(depth + 1);
                    return self.pool.add(.{ .kind = .cast, .tn = tn, .a = child });
                }
                return self.parsePostfix(try self.parsePrimary(depth + 1), depth + 1);
            },
            else => return self.parsePostfix(try self.parsePrimary(depth + 1), depth + 1),
        }
    }

    fn parsePrimary(self: *Parser, depth: u32) EvalError!u32 {
        if (depth > MAX_EVAL_DEPTH) return error.Unsupported;
        const t = self.peek();
        switch (t.kind) {
            .int => {
                _ = self.advance();
                return self.pool.add(.{ .kind = .int_lit, .ival = t.ival, .itype = t.itype });
            },
            .ident => {
                _ = self.advance();
                return self.pool.add(.{ .kind = .ident, .name = t.text });
            },
            .lparen => {
                _ = self.advance();
                const inner = try self.parseExpr(0, depth + 1);
                if (self.peek().kind != .rparen) return error.Unsupported;
                _ = self.advance();
                return inner;
            },
            else => return error.Unsupported, // string / operator / stray token
        }
    }

    fn parsePostfix(self: *Parser, node0: u32, depth: u32) EvalError!u32 {
        if (depth > MAX_EVAL_DEPTH) return error.Unsupported;
        var node = node0;
        while (true) {
            const t = self.peek();
            switch (t.kind) {
                .dot, .arrow => {
                    _ = self.advance();
                    const nm = self.peek();
                    if (nm.kind != .ident) return error.Unsupported;
                    _ = self.advance();
                    node = try self.pool.add(.{ .kind = .member, .a = node, .name = nm.text, .arrow = (t.kind == .arrow) });
                },
                .lbracket => {
                    _ = self.advance();
                    const idx = try self.parseExpr(0, depth + 1);
                    if (self.peek().kind != .rbracket) return error.Unsupported;
                    _ = self.advance();
                    node = try self.pool.add(.{ .kind = .index, .a = node, .b = idx });
                },
                else => break,
            }
        }
        return node;
    }

    /// Does the token at `+k` begin a type-name (a type keyword or `struct`/`union`/`enum`)?
    /// A typedef NAME is NOT recognized (G2) — resolves to `Unsupported`/`Unresolved`, never a
    /// wrong value. Used to disambiguate a cast `(T)x` from a parenthesized `(expr)`.
    fn startsTypeName(self: *Parser, k: usize) bool {
        const t = self.peekAt(k);
        if (t.kind != .ident) return false;
        return isTypeKeyword(t.text) or isTagKeyword(t.text) != null;
    }

    fn parseTypeName(self: *Parser, depth: u32) EvalError!TypeName {
        if (depth > MAX_EVAL_DEPTH) return error.Unsupported;
        const first = self.peek();
        if (first.kind != .ident) return error.Unsupported;
        var tn: TypeName = undefined;
        if (isTagKeyword(first.text)) |tk| {
            _ = self.advance();
            const tag = self.peek();
            if (tag.kind != .ident) return error.Unsupported;
            _ = self.advance();
            tn = .{ .base = .{ .tag = .{ .name = tag.text, .kind = tk } } };
        } else {
            // primitive keyword run
            var uns = false;
            var longs: u8 = 0;
            var is_char = false;
            var is_short = false;
            var is_void = false;
            var saw = false;
            while (self.peek().kind == .ident and isTypeKeyword(self.peek().text)) {
                const w = self.advance().text;
                saw = true;
                if (std.mem.eql(u8, w, "unsigned")) uns = true //
                else if (std.mem.eql(u8, w, "signed")) {} // explicit signed (the default anyway)
                else if (std.mem.eql(u8, w, "long")) longs += 1 //
                else if (std.mem.eql(u8, w, "char")) is_char = true //
                else if (std.mem.eql(u8, w, "short")) is_short = true //
                else if (std.mem.eql(u8, w, "void")) is_void = true //
                else if (std.mem.eql(u8, w, "int")) {} // plain int
            }
            if (!saw) return error.Unsupported;
            if (is_void) {
                tn = .{ .base = .{ .void_ = {} } };
            } else {
                const signed_default = !uns; // Borland `char` is signed by default
                const bits: u8 = if (is_char) 8 else if (longs >= 2) 64 else if (longs == 1) 32 else if (is_short) 16 else 16;
                tn = .{ .base = .{ .prim = .{ .bits = bits, .signed = signed_default } } };
            }
        }
        // pointer suffixes
        while (self.peek().kind == .star) {
            _ = self.advance();
            tn.ptr_depth += 1;
        }
        return tn;
    }
};

fn isTypeKeyword(s: []const u8) bool {
    const kws = [_][]const u8{ "int", "char", "short", "long", "unsigned", "signed", "void" };
    for (kws) |k| if (std.mem.eql(u8, s, k)) return true;
    return false;
}
fn isTagKeyword(s: []const u8) ?TagKind {
    if (std.mem.eql(u8, s, "struct")) return .struct_;
    if (std.mem.eql(u8, s, "union")) return .union_;
    if (std.mem.eql(u8, s, "enum")) return .enum_;
    return null;
}

// ─────────────────────────── evaluator (A.3/A.4) ───────────────────────────

const Eval = struct {
    sd: *SourceDebugger,
    frame: Frame,
    pool: *NodePool,

    fn eval(self: *Eval, ni: u32, depth: u32) EvalError!Val {
        if (depth > MAX_EVAL_DEPTH) return error.Unsupported;
        const node = self.pool.get(ni);
        switch (node.kind) {
            .int_lit => return .{ .ty = .{ .scalar = node.itype }, .store = .{ .rvalue = maskTo(node.ival, node.itype.bits) } },
            .ident => return self.resolveIdent(node.name),
            .unary => return self.evalUnary(node.op, node.a, depth),
            .binary => return self.evalBinary(node.op, node.a, node.b, depth),
            .ternary => {
                const cond = try self.eval(node.a, depth + 1);
                if (try self.truthy(cond)) return self.eval(node.b, depth + 1);
                return self.eval(node.c, depth + 1);
            },
            .cast => return self.evalCast(node.tn, node.a, depth),
            .sizeof_expr, .sizeof_type => {
                const t: EvalType = if (node.kind == .sizeof_type)
                    try self.resolveTypeName(node.tn)
                else
                    try self.typeOfExpr(node.a, depth + 1);
                const sz = try self.sizeOf(t);
                return scalarVal(.{ .bits = 16, .signed = false }, sz); // size_t = unsigned int
            },
            .index => return self.evalIndex(node.a, node.b, depth),
            .member => return self.evalMember(node.a, node.name, node.arrow, depth),
        }
    }

    // ---- identifier resolution (A.7) ----
    fn resolveIdent(self: *Eval, name: []const u8) EvalError!Val {
        const sd = self.sd;
        // 1. frame locals (innermost-shadowing), exactly as inspectPath head resolution.
        var lbuf: [core.MAX_LOCALS]Local = undefined;
        const ls = vars.frameLocals(sd, self.frame, lbuf[0..]);
        for (ls) |l| {
            if (!std.mem.eql(u8, vars.tdsName(sd, l.name_index), name)) continue;
            return self.headFromLocal(l);
        }
        // 2. globals / statics / functions via nameToSymbol. CRITICAL: `nameToSymbol` indexes
        //    EVERY named symbol — including the auto/register/constant LOCALS of OTHER functions
        //    (a param `v` of `clamp`, etc.). Those are NOT globals; resolving one here as a
        //    `segment:offset` static would fabricate a wild address (CLAUDE.md §2). So accept
        //    ONLY a `.static`-class symbol (a real global/static datum or a function code
        //    address) — everything else is out of scope → `Unresolved`.
        if (sd.syms) |*sy| {
            if (sy.tds) |tds_ptr| {
                if (sy.index.nameToSymbol(name)) |ref| {
                    if (ref.sym_index >= 1 and ref.sym_index <= tds_ptr.symbols.len and
                        tds_ptr.symbols[ref.sym_index - 1].class() == .static)
                    {
                        if (sd.map) |m| return self.headFromSymbol(ref, m);
                    }
                }
            }
        }
        // 3. unknown — never a guess.
        return error.Unresolved;
    }

    fn headFromLocal(self: *Eval, l: Local) EvalError!Val {
        const sd = self.sd;
        const is_frame0 = self.frame.index == 0;
        switch (l.storage) {
            .auto => |off| {
                const snap = sd.ctrl.cpuSnapshot();
                const eff: u16 = @truncate(self.frame.frame_base +% @as(u16, @bitCast(off)));
                const linear = snap.ss_base +% eff;
                return lvalueVal(.{ .type_ref = l.type_ref, .place = .{ .mem = linear }, .addr = .{ .seg = snap.ss, .off = eff, .linear = linear } });
            },
            .static => |st| {
                const m = sd.map orelse return error.Unresolved;
                const linear = m.toRuntimeLinear(st.segment, st.offset);
                return lvalueVal(.{ .type_ref = l.type_ref, .place = .{ .mem = linear }, .addr = .{ .seg = st.segment, .off = st.offset, .linear = linear } });
            },
            .register => |rn| {
                if (!is_frame0) return .{ .ty = .{ .graph = l.type_ref }, .store = .{ .rvalue = 0 }, .terminal = .{ .name = "", .type_ref = l.type_ref, .avail = .outer_frame_register } };
                return lvalueVal(.{ .type_ref = l.type_ref, .place = .{ .reg = rn }, .addr = null });
            },
            // A constant/absolute has no memory address — usable as a value (place `.imm`),
            // but `&` of it → NotLvalue (addr == null).
            .constant => |cval| return lvalueVal(.{ .type_ref = l.type_ref, .place = .{ .imm = cval }, .addr = null }),
            .absolute => |aval| return lvalueVal(.{ .type_ref = l.type_ref, .place = .{ .imm = @as(i64, aval) }, .addr = null }),
            .other => return .{ .ty = .{ .graph = l.type_ref }, .store = .{ .rvalue = 0 }, .terminal = .{ .name = "", .type_ref = l.type_ref, .avail = .no_storage } },
        }
    }

    fn headFromSymbol(self: *Eval, ref: anytype, m: anytype) EvalError!Val {
        const sd = self.sd;
        // A bare FUNCTION name decays to its ADDRESS (a code pointer, no call — H2).
        if (vars.typeInfoOf(sd, ref.type_index)) |ti| {
            if (ti == .function) {
                const seg_para: u16 = @truncate(m.base_para + ref.segment);
                const bits: u64 = (@as(u64, seg_para) << 16) | ref.offset;
                return .{ .ty = .{ .pointer = .{ .pointee = ref.type_index, .kind = .far, .far = true } }, .store = .{ .rvalue = bits } };
            }
        }
        const linear = m.toRuntimeLinear(ref.segment, ref.offset);
        return lvalueVal(.{ .type_ref = ref.type_index, .place = .{ .mem = linear }, .addr = .{ .seg = ref.segment, .off = ref.offset, .linear = linear } });
    }

    // ---- unary (A.4) ----
    fn evalUnary(self: *Eval, op: TokKind, an: u32, depth: u32) EvalError!Val {
        if (op == .amp) {
            // address-of: requires an lvalue with a memory address; `&bitfield`/`&register`/
            // `&rvalue` are refused (H1 / NotLvalue).
            const v = try self.eval(an, depth + 1);
            if (v.terminal != null) return error.NotLvalue;
            const cur = switch (v.store) {
                .lvalue => |c| c,
                .rvalue => return error.NotLvalue,
            };
            if (cur.bit != null) return error.TypeError; // &bitfield is forbidden in C (H1)
            const a = cur.addr orelse return error.NotLvalue; // a register/immediate has no address
            return .{ .ty = .{ .pointer = .{ .pointee = cur.type_ref, .kind = .near_ds, .far = false } }, .store = .{ .rvalue = a.off } };
        }
        if (op == .star) return self.derefValue(try self.eval(an, depth + 1));

        const v = try self.eval(an, depth + 1);
        if (op == .bang) {
            const t = try self.truthy(v);
            return scalarVal(.{ .bits = 16, .signed = true }, if (t) 0 else 1);
        }
        const k = try self.classify(v);
        const nb = switch (k) {
            .num => |x| x,
            .ptr => return error.TypeError, // -/+/~ of a pointer is ill-typed
        };
        switch (op) {
            .minus => {
                const r = maskTo(0 -% nb.val, nb.bits);
                return .{ .ty = .{ .scalar = .{ .bits = nb.bits, .signed = nb.signed } }, .store = .{ .rvalue = r } };
            },
            .plus => return .{ .ty = .{ .scalar = .{ .bits = nb.bits, .signed = nb.signed } }, .store = .{ .rvalue = nb.val } },
            .tilde => {
                const r = maskTo(~nb.val, nb.bits);
                return .{ .ty = .{ .scalar = .{ .bits = nb.bits, .signed = nb.signed } }, .store = .{ .rvalue = r } };
            },
            else => return error.Unsupported,
        }
    }

    // ---- deref (A.4) ----
    fn derefValue(self: *Eval, v: Val) EvalError!Val {
        const sd = self.sd;
        if (v.terminal != null) return error.TypeError;
        const k = try self.classify(v);
        const p = switch (k) {
            .ptr => |x| x,
            .num => return error.TypeError, // deref of a non-pointer
        };
        const t = ptrTargetOf(sd, p);
        if (t.is_null) return .{ .ty = .{ .graph = p.pointee }, .store = .{ .rvalue = 0 }, .terminal = vars.nullVar("") };
        return lvalueVal(.{ .type_ref = p.pointee, .place = .{ .mem = t.addr.linear }, .addr = t.addr });
    }

    // ---- index a[i] ≡ *(a + i) (A.4, indexAccessExpr — runtime index) ----
    fn evalIndex(self: *Eval, base_n: u32, idx_n: u32, depth: u32) EvalError!Val {
        const sd = self.sd;
        const base = try self.eval(base_n, depth + 1);
        const idxv = try self.eval(idx_n, depth + 1);
        const ik = try self.classify(idxv);
        const i: i64 = switch (ik) {
            .num => |x| numSigned(x),
            .ptr => return error.TypeError,
        };
        if (base.terminal != null) return error.TypeError;
        if (base.ty == .graph) {
            const ti = vars.typeInfoOf(sd, base.ty.graph) orelse return error.TypeError;
            if (ti == .array) {
                const arr = ti.array;
                if (i < 0 or @as(u64, @intCast(i)) >= arr.count) return error.TypeError; // bounds — never a wild read
                const addr = base.store.lvalue.addr orelse return error.TypeError;
                const esize = vars.typeSize(sd, arr.element);
                const delta: u32 = @intCast(@as(i64, @intCast(esize)) * i);
                const child_lin = addr.linear +% delta;
                const a = Addr{ .seg = addr.seg, .off = @truncate(addr.off +% @as(u16, @truncate(delta))), .linear = child_lin };
                return lvalueVal(.{ .type_ref = arr.element, .place = .{ .mem = child_lin }, .addr = a });
            }
        }
        // pointer index: *(p + i)
        const k = try self.classify(base);
        const p = switch (k) {
            .ptr => |x| x,
            .num => return error.TypeError,
        };
        const scaled = try self.ptrAdd(p, i);
        return self.derefValue(scaled);
    }

    // ---- member .field / ->field (A.4, reuse fieldAccess/derefStep with typed errors) ----
    fn evalMember(self: *Eval, base_n: u32, name: []const u8, arrow: bool, depth: u32) EvalError!Val {
        const sd = self.sd;
        var base = try self.eval(base_n, depth + 1);
        if (arrow) {
            base = try self.derefValue(base);
            if (base.terminal) |term| return .{ .ty = base.ty, .store = .{ .rvalue = 0 }, .terminal = term };
        }
        if (base.terminal != null) return error.TypeError;
        const cur = switch (base.store) {
            .lvalue => |c| c,
            .rvalue => return error.TypeError, // a non-lvalue aggregate is not navigable
        };
        // Distinguish member-of-non-aggregate (TypeError) from missing-member (Unresolved).
        const ti = vars.typeInfoOf(sd, cur.type_ref) orelse return error.TypeError;
        if (ti != .aggregate) return error.TypeError;
        const step = vars.fieldAccess(sd, cur, name) catch |e| switch (e) {
            error.Unresolved => return error.Unresolved, // missing member
            error.Unsupported => return error.Unsupported,
        };
        switch (step) {
            .cur => |c2| return lvalueVal(c2),
            .terminal => |term| return .{ .ty = .{ .graph = cur.type_ref }, .store = .{ .rvalue = 0 }, .terminal = term },
        }
    }

    // ---- binary (A.4) ----
    fn evalBinary(self: *Eval, op: TokKind, ln: u32, rn: u32, depth: u32) EvalError!Val {
        // short-circuit && / || — NEVER evaluate the dead branch (so `0 && (1/0)` is 0, no trap).
        if (op == .andand or op == .oror) {
            const lv = try self.eval(ln, depth + 1);
            const lt = try self.truthy(lv);
            if (op == .oror and lt) return scalarVal(.{ .bits = 16, .signed = true }, 1);
            if (op == .andand and !lt) return scalarVal(.{ .bits = 16, .signed = true }, 0);
            const rv = try self.eval(rn, depth + 1);
            const rt = try self.truthy(rv);
            return scalarVal(.{ .bits = 16, .signed = true }, if (rt) 1 else 0);
        }

        const lv = try self.eval(ln, depth + 1);
        const rv = try self.eval(rn, depth + 1);
        const lk = try self.classify(lv);
        const rk = try self.classify(rv);

        // pointer arithmetic / comparison
        if (lk == .ptr or rk == .ptr) return self.pointerBinary(op, lk, rk);

        const a = lk.num;
        const b = rk.num;
        switch (op) {
            .shl, .shr => return self.shiftNum(op, a, b),
            .plus, .minus, .star, .slash, .percent, .amp, .pipe, .caret => return self.arithNum(op, a, b),
            .lt, .gt, .le, .ge, .eqeq, .ne => return cmpNum(op, a, b),
            else => return error.Unsupported,
        }
    }

    fn pointerBinary(self: *Eval, op: TokKind, lk: Kind, rk: Kind) EvalError!Val {
        const sd = self.sd;
        // ptr ± int / int + ptr
        if (op == .plus) {
            if (lk == .ptr and rk == .num) return self.ptrAdd(lk.ptr, numSigned(rk.num));
            if (lk == .num and rk == .ptr) return self.ptrAdd(rk.ptr, numSigned(lk.num));
            return error.TypeError;
        }
        if (op == .minus) {
            if (lk == .ptr and rk == .num) return self.ptrAdd(lk.ptr, -numSigned(rk.num));
            if (lk == .ptr and rk == .ptr) {
                const esize = vars.typeSize(sd, lk.ptr.pointee);
                if (esize == 0) return error.TypeError;
                const da: i64 = @as(i64, @intCast(lk.ptr.bits & 0xFFFF)) - @as(i64, @intCast(rk.ptr.bits & 0xFFFF));
                const diff = @divTrunc(da, @as(i64, @intCast(esize)));
                return scalarVal(.{ .bits = 16, .signed = true }, maskTo(@bitCast(diff), 16));
            }
            return error.TypeError;
        }
        // comparisons
        switch (op) {
            .eqeq, .ne, .lt, .gt, .le, .ge => {
                const av = ptrCmpKey(sd, lk);
                const bv = ptrCmpKey(sd, rk);
                const res: bool = switch (op) {
                    .eqeq => av == bv,
                    .ne => av != bv,
                    .lt => av < bv,
                    .gt => av > bv,
                    .le => av <= bv,
                    .ge => av >= bv,
                    else => unreachable,
                };
                return scalarVal(.{ .bits = 16, .signed = true }, if (res) 1 else 0);
            },
            else => return error.TypeError, // * / % & | ^ << >> on a pointer
        }
    }

    fn ptrAdd(self: *Eval, p: Ptr, n: i64) EvalError!Val {
        const sd = self.sd;
        const esize = vars.typeSize(sd, p.pointee);
        if (esize == 0) return error.TypeError; // void* / incomplete pointee arithmetic
        const delta: i64 = n * @as(i64, @intCast(esize));
        const old_off: u16 = @truncate(p.bits);
        const new_off: u16 = old_off +% @as(u16, @truncate(@as(u64, @bitCast(delta))));
        const bits: u64 = if (p.far) (p.bits & 0xFFFF0000) | new_off else new_off;
        return .{ .ty = .{ .pointer = .{ .pointee = p.pointee, .kind = p.kind, .far = p.far } }, .store = .{ .rvalue = bits } };
    }

    fn shiftNum(self: *Eval, op: TokKind, a: Num, b: Num) EvalError!Val {
        _ = self;
        // result type = the (promoted) LEFT operand; count from the right.
        const count = numSigned(b);
        if (count < 0 or count >= @as(i64, a.bits)) return error.TypeError; // C6 — never a Zig panic
        const sh: u6 = @intCast(count);
        var r: u64 = undefined;
        if (op == .shl) {
            r = maskTo(a.val << sh, a.bits);
        } else {
            if (a.signed) {
                const sv = numSigned(a);
                r = maskTo(@bitCast(sv >> sh), a.bits); // arithmetic (sign-preserving)
            } else {
                r = a.val >> sh; // logical
            }
        }
        return .{ .ty = .{ .scalar = .{ .bits = a.bits, .signed = a.signed } }, .store = .{ .rvalue = r } };
    }

    fn arithNum(self: *Eval, op: TokKind, a: Num, b: Num) EvalError!Val {
        _ = self;
        const ct = commonType(a, b);
        const af = convert(a, ct);
        const bf = convert(b, ct);
        var r: u64 = 0;
        switch (op) {
            .plus => r = maskTo(af +% bf, ct.bits),
            .minus => r = maskTo(af -% bf, ct.bits),
            .star => r = maskTo(af *% bf, ct.bits),
            .amp => r = maskTo(af & bf, ct.bits),
            .pipe => r = maskTo(af | bf, ct.bits),
            .caret => r = maskTo(af ^ bf, ct.bits),
            .slash, .percent => {
                if (bf == 0) return error.DivByZero;
                if (ct.signed) {
                    const ia = signExtendBits(af, ct.bits);
                    const ib = signExtendBits(bf, ct.bits);
                    // INT_MIN / -1 overflow (well-defined refusal, never a wild wrap/trap).
                    if (ib == -1 and ia == minSigned(ct.bits)) return error.TypeError;
                    const q = if (op == .slash) @divTrunc(ia, ib) else @rem(ia, ib); // C3
                    r = maskTo(@bitCast(q), ct.bits);
                } else {
                    r = maskTo(if (op == .slash) af / bf else af % bf, ct.bits);
                }
            },
            else => return error.Unsupported,
        }
        return .{ .ty = .{ .scalar = .{ .bits = ct.bits, .signed = ct.signed } }, .store = .{ .rvalue = r } };
    }

    // ---- cast (A.5, C5) ----
    fn evalCast(self: *Eval, tn: TypeName, an: u32, depth: u32) EvalError!Val {
        const v = try self.eval(an, depth + 1);
        if (v.terminal != null) return error.TypeError;
        // A float SOURCE cast has no x87 path → honest refusal.
        if (v.ty == .graph) {
            if (vars.typeInfoOf(self.sd, v.ty.graph)) |ti| {
                if (ti == .primitive and isFloat(ti.primitive.id)) return error.Unsupported;
            }
        }
        if (tn.ptr_depth == 0) {
            // scalar target
            const target: Scalar = switch (tn.base) {
                .prim => |sc| sc,
                .void_ => return error.Unsupported, // (void)x has no value
                .tag => return error.Unsupported, // casting a scalar to an aggregate by value
            };
            const src64 = try self.castSourceBits(v);
            // C5: extend by SOURCE signedness already folded into src64; mask to target, reinterpret.
            return .{ .ty = .{ .scalar = target }, .store = .{ .rvalue = maskTo(src64, target.bits) } };
        }
        // pointer target (single level)
        if (tn.ptr_depth != 1) return error.Unsupported; // T** not supported in M-S3
        const pointee: u16 = switch (tn.base) {
            .prim => |sc| try self.primitiveTypeRef(sc) orelse return error.Unsupported,
            .void_ => return error.Unsupported, // void* pointee has size 0
            .tag => |tg| self.tagTypeRef(tg.name, tg.kind) orelse return error.Unsupported,
        };
        const k = try self.classify(v);
        switch (k) {
            .num => |nx| return .{ .ty = .{ .pointer = .{ .pointee = pointee, .kind = .near_ds, .far = false } }, .store = .{ .rvalue = nx.val & 0xFFFF } },
            .ptr => |px| return .{ .ty = .{ .pointer = .{ .pointee = pointee, .kind = px.kind, .far = px.far } }, .store = .{ .rvalue = px.bits } },
        }
    }

    /// The source value as a 64-bit pattern extended by the SOURCE signedness (C5 step 1).
    fn castSourceBits(self: *Eval, v: Val) EvalError!u64 {
        const k = try self.classify(v);
        return switch (k) {
            .num => |x| if (x.signed) @bitCast(numSigned(x)) else x.val,
            .ptr => |x| x.bits,
        };
    }

    // ---- operand classification / loads (A.3) ----
    fn classify(self: *Eval, v: Val) EvalError!Kind {
        const sd = self.sd;
        if (v.terminal != null) return error.TypeError; // a null/unreadable/outer terminal mid-arith
        switch (v.ty) {
            .scalar => |sc| {
                const raw = v.store.rvalue;
                if (sc.bits < 16) return .{ .num = promoteToInt(raw, sc.bits) };
                return .{ .num = .{ .bits = sc.bits, .signed = sc.signed, .val = maskTo(raw, sc.bits) } };
            },
            .pointer => |p| return .{ .ptr = .{ .pointee = p.pointee, .kind = p.kind, .far = p.far, .bits = v.store.rvalue } },
            .graph => |tr| {
                // A bitfield operand: extract → promote to int.
                if (v.store == .lvalue) if (v.store.lvalue.bit) |bf| {
                    const field = try self.loadBitfield(v.store.lvalue, bf.width, bf.start);
                    return .{ .num = .{ .bits = 16, .signed = true, .val = maskTo(field, 16) } };
                };
                const ti = vars.typeInfoOf(sd, tr) orelse return error.TypeError;
                switch (ti) {
                    .primitive => |pr| {
                        if (isFloat(pr.id)) return error.Unsupported;
                        const size: u16 = @min(vars.typeSize(sd, tr), 8);
                        const raw = try self.loadBits(v, size);
                        const bits: u8 = @intCast(size * 8);
                        if (bits < 16) {
                            // promote per source signedness
                            return .{ .num = promoteToIntSigned(raw, bits, vars.isSigned(pr.id)) };
                        }
                        return .{ .num = .{ .bits = bits, .signed = vars.isSigned(pr.id), .val = maskTo(raw, bits) } };
                    },
                    .enumeration => {
                        // C7: sign-extend by typeSize → signed int (NOT isSigned, false for enums).
                        const size: u16 = @min(vars.typeSize(sd, tr), 8);
                        const raw = try self.loadBits(v, size);
                        const s = signExtendBits(raw, @intCast(size * 8));
                        return .{ .num = .{ .bits = 16, .signed = true, .val = maskTo(@bitCast(s), 16) } };
                    },
                    .pointer => |p| {
                        const psize = @min(vars.typeSize(sd, tr), 8);
                        const raw = try self.loadBits(v, psize);
                        const far = (p.kind == .far or p.kind == .huge);
                        const bits: u64 = if (far) raw & 0xFFFFFFFF else raw & 0xFFFF;
                        return .{ .ptr = .{ .pointee = p.pointee, .kind = p.kind, .far = far, .bits = bits } };
                    },
                    .array => |arr| {
                        // array-to-pointer decay (a scalar-context array operand).
                        const addr = (switch (v.store) {
                            .lvalue => |c| c.addr,
                            .rvalue => null,
                        }) orelse return error.TypeError;
                        return .{ .ptr = .{ .pointee = arr.element, .kind = .near_ds, .far = false, .bits = addr.off } };
                    },
                    .aggregate => return error.TypeError, // struct arithmetic is ill-typed
                    else => return error.TypeError,
                }
            },
        }
    }

    /// Read up to `size` bytes of `v`'s scalar as a little-endian u64. An out-of-slab memory
    /// read → `TypeError` (an unreadable operand mid-arithmetic, never a wild read).
    fn loadBits(self: *Eval, v: Val, size: u16) EvalError!u64 {
        const sd = self.sd;
        switch (v.store) {
            .rvalue => |r| return r,
            .lvalue => |cur| {
                var b: [8]u8 = @splat(0);
                switch (cur.place) {
                    .mem => |lin| if (!vars.readMem(sd, lin, b[0..size])) return error.TypeError,
                    .reg => |r| vars.readReg(sd, r, b[0..size]),
                    .imm => |iv| std.mem.writeInt(u64, &b, @bitCast(iv), .little),
                }
                return vars.leBytes(b[0..size]);
            },
        }
    }

    fn loadBitfield(self: *Eval, cur: Cursor, width: u8, start: u32) EvalError!u64 {
        const sd = self.sd;
        const csize = @min(vars.typeSize(sd, cur.type_ref), 8);
        var b: [8]u8 = @splat(0);
        switch (cur.place) {
            .mem => |lin| if (!vars.readMem(sd, lin, b[0..csize])) return error.TypeError,
            .reg => |r| vars.readReg(sd, r, b[0..csize]),
            .imm => |iv| std.mem.writeInt(u64, &b, @bitCast(iv), .little),
        }
        const container = vars.leBytes(b[0..csize]);
        const mask: u64 = if (width >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(width)) - 1;
        return (container >> @intCast(start)) & mask;
    }

    fn truthy(self: *Eval, v: Val) EvalError!bool {
        const k = try self.classify(v);
        return switch (k) {
            .num => |x| x.val != 0,
            .ptr => |x| x.bits != 0,
        };
    }

    // ---- the UNEVALUATED sizeof type pass (A.6) — NO peek reads ----
    fn typeOfExpr(self: *Eval, ni: u32, depth: u32) EvalError!EvalType {
        if (depth > MAX_EVAL_DEPTH) return error.Unsupported;
        const node = self.pool.get(ni);
        switch (node.kind) {
            .int_lit => return .{ .scalar = node.itype },
            .ident => {
                const v = try self.resolveIdent(node.name);
                if (v.terminal) |term| return .{ .graph = term.type_ref };
                return v.ty;
            },
            .cast => return self.resolveTypeName(node.tn),
            .sizeof_expr, .sizeof_type => return .{ .scalar = .{ .bits = 16, .signed = false } },
            .unary => {
                switch (node.op) {
                    .amp => {
                        const t = try self.typeOfExpr(node.a, depth + 1);
                        const pointee = switch (t) {
                            .graph => |g| g,
                            else => return error.TypeError,
                        };
                        return .{ .pointer = .{ .pointee = pointee, .kind = .near_ds, .far = false } };
                    },
                    .star => {
                        const t = try self.typeOfExpr(node.a, depth + 1);
                        return self.pointeeType(t);
                    },
                    .bang => return .{ .scalar = .{ .bits = 16, .signed = true } },
                    else => {
                        const t = try self.typeOfExpr(node.a, depth + 1);
                        return promotedType(t);
                    },
                }
            },
            .binary => {
                const lt = try self.typeOfExpr(node.a, depth + 1);
                const rt = try self.typeOfExpr(node.b, depth + 1);
                if (lt == .pointer or lt == .graph) {
                    if (self.isPointerish(lt)) return lt;
                }
                if (self.isPointerish(rt)) return rt;
                return commonEvalType(promotedType(lt), promotedType(rt));
            },
            .ternary => {
                const t2 = try self.typeOfExpr(node.b, depth + 1);
                return t2;
            },
            .member => {
                const bt = try self.typeOfExpr(node.a, depth + 1);
                const agg: u16 = if (node.arrow) blk: {
                    const pt = try self.pointeeType(bt);
                    break :blk switch (pt) {
                        .graph => |g| g,
                        else => return error.TypeError,
                    };
                } else switch (bt) {
                    .graph => |g| g,
                    else => return error.TypeError,
                };
                const mref = self.memberTypeRef(agg, node.name) orelse return error.Unresolved;
                return .{ .graph = mref };
            },
            .index => {
                const bt = try self.typeOfExpr(node.a, depth + 1);
                return self.elementType(bt);
            },
        }
    }

    fn pointeeType(self: *Eval, t: EvalType) EvalError!EvalType {
        const sd = self.sd;
        switch (t) {
            .pointer => |p| return .{ .graph = p.pointee },
            .graph => |g| {
                const ti = vars.typeInfoOf(sd, g) orelse return error.TypeError;
                return switch (ti) {
                    .pointer => |p| .{ .graph = p.pointee },
                    .array => |arr| .{ .graph = arr.element },
                    else => error.TypeError,
                };
            },
            else => return error.TypeError,
        }
    }

    fn elementType(self: *Eval, t: EvalType) EvalError!EvalType {
        return self.pointeeType(t);
    }

    fn isPointerish(self: *Eval, t: EvalType) bool {
        if (t == .pointer) return true;
        if (t == .graph) {
            if (vars.typeInfoOf(self.sd, t.graph)) |ti| return (ti == .pointer or ti == .array);
        }
        return false;
    }

    fn memberTypeRef(self: *Eval, agg: u16, name: []const u8) ?u16 {
        const sd = self.sd;
        const s = if (sd.syms) |*sy| sy else return null;
        const tg = if (s.typegraph) |*g| g else return null;
        for (tg.members(agg)) |m| {
            if (m.kind != .data) continue;
            if (std.mem.eql(u8, vars.tdsName(sd, m.name_index), name)) return m.type_ref;
        }
        return null;
    }

    // ---- type-name / size resolution ----
    fn resolveTypeName(self: *Eval, tn: TypeName) EvalError!EvalType {
        if (tn.ptr_depth >= 1) {
            const pointee: u16 = switch (tn.base) {
                .prim => |sc| (try self.primitiveTypeRef(sc)) orelse 0,
                .void_ => 0,
                .tag => |tg| self.tagTypeRef(tg.name, tg.kind) orelse return error.Unresolved,
            };
            return .{ .pointer = .{ .pointee = pointee, .kind = .near_ds, .far = false } };
        }
        return switch (tn.base) {
            .prim => |sc| .{ .scalar = sc },
            .void_ => error.TypeError, // sizeof(void) is ill-formed
            .tag => |tg| .{ .graph = self.tagTypeRef(tg.name, tg.kind) orelse return error.Unresolved },
        };
    }

    fn sizeOf(self: *Eval, t: EvalType) EvalError!u64 {
        const sd = self.sd;
        switch (t) {
            .scalar => |sc| return sc.bits / 8,
            .pointer => |p| return if (p.far) 4 else 2,
            .graph => |g| {
                const sz = vars.typeSize(sd, g);
                if (sz == 0) return error.TypeError; // incomplete / size-0 type
                return sz;
            },
        }
    }

    fn tagTypeRef(self: *Eval, name: []const u8, kind: TagKind) ?u16 {
        const sd = self.sd;
        const s = if (sd.syms) |*sy| sy else return null;
        const tg = if (s.typegraph) |*g| g else return null;
        return tg.typeRefForTag(name, kind);
    }

    fn primitiveTypeRef(self: *Eval, sc: Scalar) EvalError!?u16 {
        const sd = self.sd;
        const s = if (sd.syms) |*sy| sy else return null;
        const tg = if (s.typegraph) |*g| g else return null;
        const id: TypeId = scalarPrimId(sc);
        return tg.typeRefForPrimitive(id);
    }
};

// ─────────────────────────── result rendering (A.7) ───────────────────────────

fn render(sd: *SourceDebugger, frame: Frame, v: Val, name: []const u8, scratch: []u8) Variable {
    if (v.terminal) |t| {
        var tv = t;
        tv.name = name;
        return tv;
    }
    switch (v.store) {
        .lvalue => |cur| {
            var out = if (cur.bit) |bf|
                vars.renderBitfieldAt(sd, name, cur.type_ref, (cur.addr orelse Addr{ .seg = 0, .off = 0, .linear = 0 }).linear, cur.addr orelse Addr{ .seg = 0, .off = 0, .linear = 0 }, bf.width, bf.start, scratch)
            else
                vars.renderValueAt(sd, name, cur.type_ref, cur.place, cur.addr, 0, frame.index, scratch);
            out.writable = switch (cur.place) {
                .imm => false, // a constant/absolute is not assignable
                else => true,
            };
            return out;
        },
        .rvalue => |bits| {
            switch (v.ty) {
                .scalar => |sc| return renderSyntheticScalar(name, sc, bits, scratch),
                .pointer => |p| return renderSyntheticPointer(sd, frame, name, p, bits, scratch),
                .graph => |tr| return vars.renderValueAt(sd, name, tr, .{ .imm = @bitCast(bits) }, null, 0, frame.index, scratch),
            }
        },
    }
}

/// renderSyntheticScalar (NEW code, A.7): decimal + hex value, a static `type_text`.
fn renderSyntheticScalar(name: []const u8, sc: Scalar, bits: u64, scratch: []u8) Variable {
    const masked = maskTo(bits, sc.bits);
    const text = if (sc.signed) blk: {
        const sv = signExtendBits(masked, sc.bits);
        break :blk std.fmt.bufPrint(scratch, "{d} (0x{X})", .{ sv, masked }) catch "?";
    } else std.fmt.bufPrint(scratch, "{d} (0x{X})", .{ masked, masked }) catch "?";
    return .{ .name = name, .value_text = text, .type_text = scalarName(sc), .avail = .ok };
}

/// A synthesized pointer result (`&x`, cast-to-pointer, pointer arithmetic): pointer text +
/// a `pointee *` type name, and a minted `.pointee` handle so the result is expandable.
fn renderSyntheticPointer(sd: *SourceDebugger, frame: Frame, name: []const u8, p: PtrType, bits: u64, scratch: []u8) Variable {
    const half = scratch.len / 2;
    const value = if (p.far)
        std.fmt.bufPrint(scratch[0..half], "{X:0>4}:{X:0>4}", .{ @as(u16, @truncate(bits >> 16)), @as(u16, @truncate(bits)) }) catch "?"
    else
        std.fmt.bufPrint(scratch[0..half], "0x{X:0>4}", .{@as(u16, @truncate(bits))}) catch "?";

    // type_text = pointee name + " *"
    var tw: std.Io.Writer = .fixed(scratch[half..]);
    var type_text: []const u8 = "?";
    if (sd.syms) |*sy| {
        if (sy.typegraph) |*tg| {
            tg.typeName(p.pointee, &tw) catch {};
            tw.writeAll(" *") catch {};
            type_text = tw.buffered();
        }
    }

    // mint a .pointee handle (expandable) — mirrors vars.mintPointee.
    const pv: Ptr = .{ .pointee = p.pointee, .kind = p.kind, .far = p.far, .bits = bits };
    const t = ptrTargetOf(sd, pv);
    const ref = sd.mintHandle(.{
        .target = .pointee,
        .frame_index = frame.index,
        .type_ref = p.pointee,
        .base = t.addr,
        .seg_sel = p.kind,
        .elem_count = if (t.is_null) 1 else 0,
    });
    return .{ .name = name, .value_text = value, .type_text = type_text, .avail = .ok, .variables_ref = ref };
}

fn scalarName(sc: Scalar) []const u8 {
    return switch (sc.bits) {
        8 => if (sc.signed) "char" else "unsigned char",
        16 => if (sc.signed) "int" else "unsigned int",
        32 => if (sc.signed) "long" else "unsigned long",
        64 => if (sc.signed) "long long" else "unsigned long long",
        else => "int",
    };
}

fn scalarPrimId(sc: Scalar) TypeId {
    return switch (sc.bits) {
        8 => if (sc.signed) .schar else .uchar,
        16 => if (sc.signed) .sint else .uint,
        32 => if (sc.signed) .slong else .ulong,
        64 => if (sc.signed) .squad else .uquad,
        else => .sint,
    };
}

// ─────────────────────────── numeric helpers ───────────────────────────

fn maskTo(v: u64, bits: u8) u64 {
    if (bits >= 64) return v;
    return v & ((@as(u64, 1) << @intCast(bits)) - 1);
}
fn signExtendBits(v: u64, bits: u8) i64 {
    return vars.signExtend(v, @as(usize, bits) / 8);
}
fn numSigned(n: Num) i64 {
    if (n.signed) return signExtendBits(n.val, n.bits);
    return @bitCast(n.val);
}
fn minSigned(bits: u8) i64 {
    if (bits >= 64) return std.math.minInt(i64);
    return -(@as(i64, 1) << @intCast(bits - 1));
}
fn promoteToInt(raw: u64, from_bits: u8) Num {
    return promoteToIntSigned(raw, from_bits, true); // synthetic sub-int scalars are signed (char)
}
fn promoteToIntSigned(raw: u64, from_bits: u8, signed: bool) Num {
    // integer promotion: any type of rank < int → int (16-bit signed), value-preserving.
    const val: u64 = if (signed) @bitCast(signExtendBits(raw, from_bits)) else maskTo(raw, from_bits);
    return .{ .bits = 16, .signed = true, .val = maskTo(val, 16) };
}
fn commonType(a: Num, b: Num) Scalar {
    const cb = @max(a.bits, b.bits);
    const cs = if (a.bits == b.bits) (a.signed and b.signed) else if (a.bits > b.bits) a.signed else b.signed;
    return .{ .bits = cb, .signed = cs };
}
/// Convert `n` into the value pattern of common type `ct` (value-preserving widening).
fn convert(n: Num, ct: Scalar) u64 {
    const widened: u64 = if (n.signed) @bitCast(signExtendBits(n.val, n.bits)) else n.val;
    return maskTo(widened, ct.bits);
}
fn cmpNum(op: TokKind, a: Num, b: Num) EvalError!Val {
    const ct = commonType(a, b);
    const af = convert(a, ct);
    const bf = convert(b, ct);
    const res: bool = if (ct.signed) blk: {
        const ia = signExtendBits(af, ct.bits);
        const ib = signExtendBits(bf, ct.bits);
        break :blk switch (op) {
            .lt => ia < ib,
            .gt => ia > ib,
            .le => ia <= ib,
            .ge => ia >= ib,
            .eqeq => ia == ib,
            .ne => ia != ib,
            else => return error.Unsupported,
        };
    } else switch (op) {
        .lt => af < bf,
        .gt => af > bf,
        .le => af <= bf,
        .ge => af >= bf,
        .eqeq => af == bf,
        .ne => af != bf,
        else => return error.Unsupported,
    };
    return scalarVal(.{ .bits = 16, .signed = true }, if (res) 1 else 0);
}

fn promotedType(t: EvalType) EvalType {
    switch (t) {
        .scalar => |sc| return if (sc.bits < 16) .{ .scalar = .{ .bits = 16, .signed = true } } else .{ .scalar = sc },
        else => return .{ .scalar = .{ .bits = 16, .signed = true } },
    }
}
fn commonEvalType(a: EvalType, b: EvalType) EvalType {
    const sa: Scalar = if (a == .scalar) a.scalar else .{ .bits = 16, .signed = true };
    const sb: Scalar = if (b == .scalar) b.scalar else .{ .bits = 16, .signed = true };
    return .{ .scalar = commonType(.{ .bits = sa.bits, .signed = sa.signed, .val = 0 }, .{ .bits = sb.bits, .signed = sb.signed, .val = 0 }) };
}

fn isFloat(id: TypeId) bool {
    return switch (id) {
        .float, .double, .ldouble, .tpreal, .tbyte => true,
        else => false,
    };
}

/// The comparison key for a pointer operand (or a pointer-vs-int mix): the pointer's stored
/// REPRESENTATION — the offset for a near pointer, `seg<<16|off` for a far pointer. Using the
/// representation (not the resolved linear) makes the null test correct: a null NEAR pointer
/// has offset 0 (so `np == 0` is true) even though its linear is `DS:0000 == ds_base`. Near
/// pointers thus compare by offset (C real-mode semantics); far pointers compare by the
/// seg:off key — a documented real-mode approximation for `<`/`>`, never silently wrong (a real
/// monotonic ordering), and exact for `==`/`!=`.
fn ptrCmpKey(sd: *SourceDebugger, k: Kind) u64 {
    _ = sd;
    return switch (k) {
        .num => |x| x.val,
        .ptr => |p| p.bits,
    };
}

fn ptrTargetOf(sd: *SourceDebugger, p: Ptr) vars.PtrTarget {
    var b: [8]u8 = @splat(0);
    if (p.far) {
        std.mem.writeInt(u16, b[0..2], @truncate(p.bits), .little);
        std.mem.writeInt(u16, b[2..4], @truncate(p.bits >> 16), .little);
        return vars.ptrTarget(sd, p.kind, b[0..4]);
    }
    std.mem.writeInt(u16, b[0..2], @truncate(p.bits), .little);
    return vars.ptrTarget(sd, p.kind, b[0..2]);
}

// ─────────────────────────── small Val constructors ───────────────────────────

fn lvalueVal(cur: Cursor) Val {
    return .{ .ty = .{ .graph = cur.type_ref }, .store = .{ .lvalue = cur } };
}
fn scalarVal(sc: Scalar, val: u64) Val {
    return .{ .ty = .{ .scalar = sc }, .store = .{ .rvalue = maskTo(val, sc.bits) } };
}

// ─────────────────────────── set_variable (M3-b, §B) — the WRITE PLAN ───────────────────────────
//
// D1: this module stays strictly READ-ONLY. `resolveWrite` RESOLVES the lvalue (reusing the
// evaluator), peeks the bytes it needs (the bitfield RMW container — bounds-checked, never
// stale), fit-checks + type-directed ENCODES the new value, and returns a NEUTRAL
// `{destination, bytes}` plan. The WORKER commits it (the deterministic poke); this module never
// calls a `ctrl` mutator (structurally enforced by the dedicated grep gate). Every path is either
// the exact bytes at the exact address, or an honest typed error — never a partial / neighbor-
// clobbering / silently-wrapped write (CLAUDE.md §1/§2).

/// Where a resolved write lands. Pointer-free (the worker commits it via its existing guarded
/// poke path). The low `mem.len` / `reg.size` bytes of `WritePlan.bytes` (little-endian) are
/// the value.
pub const WriteDest = union(enum) {
    mem: struct { linear: u32, len: u8 }, // a physical linear address (worker slab-guards it)
    reg: struct { num: u8, size: u8 }, // a frame-0 register (format.Reg 0-15) of natural width
};

/// A validated, committed-elsewhere write: the destination + the LE value bytes.
pub const WritePlan = struct {
    dest: WriteDest,
    bytes: [8]u8 = @splat(0),
};

/// Resolve `lvalue` to a write destination + type-directed encode `value` (§B). PURE / peek-only
/// — the WORKER commits the returned plan. Honest typed errors, never a partial or neighbor-
/// clobbering write: `NotLvalue` (non-lvalue / constant target), `TypeError` (null/unreadable/
/// outer-register lvalue, out-of-range value, aggregate target, register-too-wide, bad bitfield
/// container), `Unresolved` (unknown enumerator/name), `Unsupported` (float target). NEVER a
/// silent wrap/truncation.
pub fn resolveWrite(sd: *SourceDebugger, frame: Frame, lvalue: []const u8, value: []const u8) EvalError!WritePlan {
    const lv = try evalExpr(sd, frame, lvalue);
    // S2/S5: a null/unreadable/outer-frame-register terminal is NOT a navigable write target —
    // refuse BEFORE any encode/commit. A null NEAR pointer decodes to in-slab DS:0000, so the
    // worker slab guard would NOT catch `*p = …` on null `p`; this terminal refusal is the guard.
    if (lv.terminal != null) return error.TypeError;
    const cur = switch (lv.store) {
        .lvalue => |c| c,
        .rvalue => return error.NotLvalue, // a literal / arithmetic result / `&x` is not assignable
    };
    // A constant/absolute (place `.imm`) has no writable storage.
    if (cur.place == .imm) return error.NotLvalue;

    // BITFIELD (S1): read-modify-write EXACTLY `csize` bytes (never a full u64), AND-clear then
    // OR-insert, signed-aware.
    if (cur.bit) |bf| return encodeBitfield(sd, frame, cur, bf.width, bf.start, value);

    const ti = vars.typeInfoOf(sd, cur.type_ref) orelse return error.TypeError;
    switch (ti) {
        .primitive => |pr| {
            if (isFloat(pr.id)) return error.Unsupported; // no x87 — cannot encode a float
            const size: u16 = @min(vars.typeSize(sd, cur.type_ref), 8);
            if (size == 0) return error.TypeError;
            const raw = try fitScalar(try scalarValue(sd, frame, value), @intCast(size * 8));
            return makePlan(cur, @intCast(size), raw);
        },
        .enumeration => {
            const size: u16 = @min(vars.typeSize(sd, cur.type_ref), 8);
            if (size == 0) return error.TypeError;
            const raw = try fitScalar(try enumValue(sd, cur.type_ref, value), @intCast(size * 8));
            return makePlan(cur, @intCast(size), raw);
        },
        .pointer => |p| {
            const far = (p.kind == .far or p.kind == .huge);
            const size: u8 = if (far) 4 else 2;
            const raw = try pointerValue(sd, frame, value, far);
            return makePlan(cur, size, raw);
        },
        .array, .aggregate => return error.TypeError, // no scalar→aggregate assignment
        else => return error.TypeError,
    }
}

/// Build the plan for a plain scalar/pointer target at `cur`, `size` LE bytes = `raw`.
fn makePlan(cur: Cursor, size: u8, raw: u64) EvalError!WritePlan {
    var bytes: [8]u8 = @splat(0);
    std.mem.writeInt(u64, &bytes, raw, .little); // low `size` bytes are the LE value
    switch (cur.place) {
        .mem => |lin| return .{ .dest = .{ .mem = .{ .linear = lin, .len = size } }, .bytes = bytes },
        .reg => |r| {
            // S3: reject a register lvalue whose type is wider than the register's natural width
            // (else the 16-bit register poke would silently truncate a `long`). format.Reg 0-7 =
            // 16-bit eXX halves; 8-15 = 8-bit halves.
            const natural: u8 = if (r < 8) 2 else 1;
            if (size > natural) return error.TypeError;
            return .{ .dest = .{ .reg = .{ .num = r, .size = size } }, .bytes = bytes };
        },
        .imm => return error.NotLvalue,
    }
}

/// Bitfield RMW (S1). `csize = @min(typeSize, 8)` container bytes are read, the `width`-bit field
/// at `start` is AND-cleared then OR-inserted, and EXACTLY `csize` bytes are written back (never
/// a full u64 — that would clobber members past the storage unit). Borland `int b:5` is SIGNED,
/// so `-1` is accepted and stored as `0x1F` (masked to `width` bits), not range-rejected.
fn encodeBitfield(sd: *SourceDebugger, frame: Frame, cur: Cursor, width: u8, start: u32, value: []const u8) EvalError!WritePlan {
    const lin = switch (cur.place) {
        .mem => |l| l,
        else => return error.TypeError, // a bitfield always lives in a memory container
    };
    const csize: u16 = @min(vars.typeSize(sd, cur.type_ref), 8);
    if (csize == 0 or width == 0 or width > 64 or start + width > csize * 8) return error.TypeError;
    // Range: v ∈ [-2^(w-1), 2^w-1] (w = width) — accept under EITHER signedness.
    const v = try scalarValue(sd, frame, value);
    const lo: i128 = -(@as(i128, 1) << @intCast(width - 1));
    const hi: i128 = (@as(i128, 1) << @intCast(width)) - 1;
    if (v < lo or v > hi) return error.TypeError;
    const mask: u64 = if (width >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(width)) - 1;
    const vbits: u64 = @as(u64, @bitCast(@as(i64, @truncate(v)))) & mask; // -1 → 0x1F for width 5
    // Read the CURRENT container (peek, bounds-checked) — never stale.
    var b: [8]u8 = @splat(0);
    if (!vars.readMem(sd, lin, b[0..csize])) return error.TypeError;
    var container = vars.leBytes(b[0..csize]);
    // AND-clear THEN OR-insert (a naive |= cannot write a 0 bit).
    const sh: u6 = @intCast(start);
    container = (container & ~(mask << sh)) | (vbits << sh);
    var bytes: [8]u8 = @splat(0);
    std.mem.writeInt(u64, &bytes, container, .little);
    return .{ .dest = .{ .mem = .{ .linear = lin, .len = @intCast(csize) } }, .bytes = bytes };
}

/// Parse `value` as a literal, else evaluate it (pure) and require a scalar/pointer rvalue.
/// Returns the raw i128 value (NO fit-check; the caller range-checks against the target width).
fn scalarValue(sd: *SourceDebugger, frame: Frame, s: []const u8) EvalError!i128 {
    if (tryLiteral(s)) |iv| return iv;
    const k = try evalScalarExpr(sd, frame, s); // a non-literal RHS (`lo + 1`) — pure evaluate
    return switch (k) {
        .num => |x| @as(i128, numSigned(x)),
        .ptr => |x| @as(i128, @intCast(x.bits)),
    };
}

/// Parse `value` against an ENUM target: an enumerator NAME (matched via `enumerators`), or an
/// integer. An unknown identifier → `Unresolved`.
fn enumValue(sd: *SourceDebugger, type_ref: u16, s0: []const u8) EvalError!i128 {
    const s = std.mem.trim(u8, s0, " \t");
    if (s.len == 0) return error.TypeError;
    if (isIdentStart(s[0])) {
        if (sd.syms) |*sy| if (sy.typegraph) |*tg| {
            for (tg.enumerators(type_ref)) |en| {
                if (std.mem.eql(u8, vars.tdsName(sd, en.name_index), s)) return @as(i128, en.value);
            }
        };
        return error.Unresolved; // an identifier that is not an enumerator of this enum
    }
    return tryLiteral(s) orelse error.TypeError; // an in-range integer enumerator
}

/// Parse `value` against a POINTER target: `NULL`/`null` → 0, a far `seg:off` hex pair, or an
/// integer offset (near ≤ 0xFFFF, far ≤ 0xFFFFFFFF). Out of range → `TypeError`.
fn pointerValue(sd: *SourceDebugger, frame: Frame, s0: []const u8, far: bool) EvalError!u64 {
    const s = std.mem.trim(u8, s0, " \t");
    if (s.len == 0) return error.TypeError;
    if (std.mem.eql(u8, s, "NULL") or std.mem.eql(u8, s, "null")) return 0;
    if (far) {
        if (std.mem.indexOfScalar(u8, s, ':')) |ci| {
            const seg = std.fmt.parseInt(u16, s[0..ci], 16) catch return error.TypeError;
            const off = std.fmt.parseInt(u16, s[ci + 1 ..], 16) catch return error.TypeError;
            return (@as(u64, seg) << 16) | off;
        }
    }
    const iv = try scalarValue(sd, frame, s);
    const hi: i128 = if (far) 0xFFFFFFFF else 0xFFFF;
    if (iv < 0 or iv > hi) return error.TypeError;
    return @intCast(iv);
}

/// Parse `s` as a standalone integer/char literal (`42`, `-1`, `0x1F`, `010`, `'A'`, `NULL`),
/// returning its i128 value, or null if it is not a pure literal (the caller then tries the
/// expression path). No fit-check here.
fn tryLiteral(s0: []const u8) ?i128 {
    const s = std.mem.trim(u8, s0, " \t");
    if (s.len == 0) return null;
    if (std.mem.eql(u8, s, "NULL") or std.mem.eql(u8, s, "null")) return 0;
    if (s[0] == '\'') {
        var i: usize = 0;
        const tok = lexChar(s, &i) catch return null;
        if (i != s.len) return null; // trailing junk → not a pure literal
        return @as(i128, @intCast(tok.ival));
    }
    var t = s;
    var neg = false;
    if (t[0] == '-') {
        neg = true;
        t = t[1..];
    } else if (t[0] == '+') {
        t = t[1..];
    }
    if (t.len == 0) return null;
    var base: u8 = 10;
    var digits = t;
    if (t.len >= 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X')) {
        base = 16;
        digits = t[2..];
    } else if (t.len >= 2 and t[0] == '0') {
        base = 8;
        digits = t[1..];
    }
    if (digits.len == 0) return null;
    const mag = std.fmt.parseInt(u128, digits, base) catch return null;
    if (mag > @as(u128, std.math.maxInt(i128))) return null;
    const iv: i128 = @intCast(mag);
    return if (neg) -iv else iv;
}

/// Fit a value into a `w`-bit integer under EITHER signedness (S4): accept
/// `v ∈ [-2^(w-1), 2^w-1]`, then return the low `w` bits (2's complement) — so `-1 → 0xFFFF`
/// and `0xFFFF → -1` both encode, while `300 → char` is a `TypeError` (never a silent wrap).
fn fitScalar(v: i128, w: u8) EvalError!u64 {
    const lo: i128 = if (w >= 64) std.math.minInt(i64) else -(@as(i128, 1) << @intCast(w - 1));
    const hi: i128 = if (w >= 64) std.math.maxInt(u64) else (@as(i128, 1) << @intCast(w)) - 1;
    if (v < lo or v > hi) return error.TypeError;
    const bits: u64 = @bitCast(@as(i64, @truncate(v)));
    return maskTo(bits, w);
}

test {
    std.testing.refAllDecls(@This());
}
