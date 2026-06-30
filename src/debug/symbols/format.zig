//! Byte-exact Borland C++ 3.1 / TLINK 5.1 16-bit TDS (v3.10, `0x52FB`) record
//! layouts and enums. **Copied verbatim from the authoritative format spec**
//! (`docs/research/borland-tds-format-complete.md` §16): every offset/width/enum
//! here was decoded by correlating raw EXE bytes against the TDUMP 3.1 oracle on
//! the 12 checked-in BC++3.1 fixtures, with a full block-walk reconciling to zero
//! residual at the EOF name pool. Each record is a `packed struct` so the on-disk
//! little-endian layout is byte-exact (note the u16 fields at odd offsets
//! 0x29/0x2B of `Header` — only a packed struct represents these). Read any record
//! with `@bitCast` from its fixed-size byte array; every type carries a `comptime`
//! size assert that locks its byte width.
//!
//! This file is a *pure* layout description — no host I/O, clock, RNG, or allocation
//! (it is part of the host-side, load-time symbol overlay; see `tds.zig`).

const std = @import("std");

pub const MAGIC: u16 = 0x52FB;

/// Base header — 48 bytes at the trailer offset. `packed struct` so byte-exact LE layout
/// (note the u16 fields at odd offsets 0x29/0x2B — only a packed struct represents these).
/// Read any record with `@bitCast` from its fixed-size byte array.
pub const Header = packed struct {
    magic: u16, // 0x52FB
    minor_version: u8, // 0x10
    major_version: u8, // 0x03
    names_pool_size: u32,
    names_count: u16,
    types_count: u16,
    members_count: u16,
    symbols_count: u16,
    globals_count: u16,
    modules_count: u16,
    locals_count: u16, // always 0 in BCC3.1
    scopes_count: u16,
    lines_count: u16,
    srcfiles_count: u16, // == "Number of Include Files"
    segments_count: u16,
    correlations_count: u16,
    image_size: u32,
    debugger_hook: u32,
    program_flags: u8, // bit0 case-sensitive, bit1 pascal-overlays
    string_seg_offset: u16, // deprecated
    data_count: u16,
    filler: u8,
    extension_size: u16, // 0x20 for BCC3.1
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 0x30);
    }
};

/// Extended header — at trailer+0x30, length == Header.extension_size (0x20).
pub const ExtHeader = packed struct {
    class_entries: u16, // 0x30
    parent_entries: u16, // 0x32
    global_classes: u16, // 0x34
    overload_entries: u16, // 0x36
    scope_class_entries: u16, // 0x38
    module_class_entries: u16, // 0x3A
    coverage_count: u16, // 0x3C
    name_pool_offset: u32, // 0x3E  (relative to end of header = trailer+0x30+extension_size)
    browser_entries: u16, // 0x42
    opt_sym_entries: u16, // 0x44
    debug_flags: u16, // 0x46
    ref_info_size: u32, // 0x48
    filler: u32, // 0x4C
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 0x20);
    }
};

pub const SymbolClass = enum(u3) {
    static = 0, // global/static: segment:offset is an image address
    absolute = 1,
    auto = 2, // offset = signed BP-relative; segment = 0
    pascal_var = 3,
    register = 4, // offset = x86 register number; segment = 0
    constant = 5, // offset = the constant value
    typedef = 6, // type = aliased type
    tag = 7, // struct/union/enum tag symbol
};

/// x86 register numbers used when SymbolClass.register (in the `offset` field).
pub const Reg = enum(u16) { ax = 0, cx = 1, dx = 2, bx = 3, sp = 4, bp = 5, si = 6, di = 7, al = 8, cl = 9, dl = 10, bl = 11, ah = 12, ch = 13, dh = 14, bh = 15, _ };

pub const Symbol = packed struct { // 9 bytes
    name: u16,
    type: u16,
    offset: u16, // signed when class==auto
    segment: u16,
    flags: u8, // bits0..2 class, bit3 param/BP+, bits4.. ret-frame words
    pub fn class(s: Symbol) SymbolClass {
        return @enumFromInt(@as(u3, @truncate(s.flags)));
    }
    pub fn isParam(s: Symbol) bool {
        return (s.flags & 0x08) != 0;
    }
    /// A code symbol (function): BCC3.1 emits flags bits 3+4 (0x18) for functions,
    /// distinguishing them from plain data globals (which carry flags 0). [spec §4]
    pub fn isFunction(s: Symbol) bool {
        return s.class() == .static and (s.flags & 0x18) == 0x18;
    }
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 9);
    }
};

pub const Language = enum(u8) { unknown = 0, c = 0x01, pascal = 0x02, basic = 0x03, @"asm" = 0x04, cpp = 0x05, _ };

/// Low 3 bits of the module `memory_model` byte (bit 3 is `underbars_on`).
pub const MemoryModel = enum(u3) { tiny = 0, small = 1, medium = 2, compact = 3, large = 4, huge = 5, _ };

pub const Module = packed struct { // 16 bytes
    name: u16,
    language: u8, // Language enum (plain), NOT a bitfield
    memory_model: u8, // bits0..2 = MemoryModel, bit3 = underbars_on
    symbols_index: u16, // 1-based first tag/typedef symbol of the module
    symbols_count: u16,
    first_source_file: u16,
    source_file_count: u16,
    correlation_index: u16, // 1-based first correlation record (NOT a segment index)
    correlation_count: u16,
    pub fn model(m: Module) MemoryModel {
        return @enumFromInt(@as(u3, @truncate(m.memory_model)));
    }
    pub fn underbars(m: Module) bool {
        return (m.memory_model & 0x08) != 0;
    }
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 16);
    }
};

pub const SourceFile = packed struct { // 6 bytes
    name: u16,
    timestamp: u32, // DOS packed date/time
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 6);
    }
};

pub const Line = packed struct { // 4 bytes
    line: u16,
    code_offset: u16, // within the correlation's segment code base
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 4);
    }
};

pub const Scope = packed struct { // 12 bytes
    symbol_index: u16, // first local symbol (1-based)
    symbol_count: u16,
    parent: u16,
    function: u16, // owning fn symbol (C++); 0 for C
    offset: u16, // within code-base segment
    length: u16,
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 12);
    }
};

pub const Segment = packed struct { // 16 bytes
    module: u16,
    code_segment: u16, // image-relative paragraph
    code_offset: u16,
    code_length: u16,
    scope_index: u16,
    scope_count: u16,
    correlation_index: u16,
    correlation_count: u16,
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 16);
    }
};

pub const Correlation = packed struct { // 8 bytes
    segment_index: u16,
    source_index: u16,
    line_first: u16, // 1-based into line table
    line_count: u16,
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 8);
    }
};

pub const TypeId = enum(u8) {
    void = 0x00,
    schar = 0x04,
    sint = 0x05,
    slong = 0x06,
    squad = 0x07,
    uchar = 0x08,
    uint = 0x09,
    ulong = 0x0A,
    uquad = 0x0B,
    pchar = 0x0C,
    float = 0x0D,
    tpreal = 0x0E,
    double = 0x0F,
    ldouble = 0x10,
    nearp = 0x15,
    farp = 0x16,
    seg = 0x17, // TID_SEG
    near386 = 0x18,
    far386 = 0x19,
    array = 0x1A, // TID_CARRAY
    vlarray = 0x1B,
    parray = 0x1C,
    @"struct" = 0x1E,
    @"union" = 0x1F,
    vlstruct = 0x20,
    vlunion = 0x21,
    @"enum" = 0x22,
    func = 0x23,
    label = 0x24,
    set = 0x25,
    bool = 0x28,
    pword = 0x2A,
    tbyte = 0x2B, // 10-byte predefined slot
    specialfunc = 0x2D, // C++ member / overloaded / duplicate function
    class = 0x2E, // C++ class (named, sized; cross-indexed by the Class table)
    memberptr = 0x33,
    nref = 0x34,
    fref = 0x35,
    _,
};

/// Near/far pointer modifier byte (Type.class when id == nearp/farp).
pub const PointerClass = enum(u8) {
    near_unspec = 0x00, // for nearp: unspecified segment    / for farp: plain far
    es_or_far = 0x01, // nearp: _ES-relative                / farp: huge
    cs = 0x02, // _CS-relative (near only)
    ss = 0x03, // _SS-relative (near only)
    ds = 0x04, // _DS-relative (near only)
    fs = 0x05,
    gs = 0x06,
    _,
};

/// Function modifier byte (Type.class when id == func). bit2 (0x04) = far modifier.
pub const FuncClass = enum(u8) {
    near_c = 0x00, // near cdecl/C
    near_pascal = 0x01,
    far_c = 0x04,
    far_pascal = 0x05, // inferred
    interrupt = 0x07,
    _,
};

pub const Type = packed struct { // 8 bytes
    id: u8, // TypeId
    name: u16, // tag name (struct/union/enum); else 0
    size: u16,
    class: u8, // modifier: ptr 0x04=near _DS, 0x01=huge, 0x00=far; func 0x00=near 0x04=far
    member_type: u16, // first member (struct/union) | pointee (ptr) | element (array) | return (func)
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 8);
    }
};

pub const Member = packed struct { // 5 bytes
    flags: u8, // 0 normal | 1..63 bitfield width | 0x80 last enum | 0xC0 list terminator
    name: u16,
    type: u16, // struct/union: type index | enum: enumerator value
    pub fn isTerminator(m: Member) bool {
        return (m.flags & 0xC0) == 0xC0;
    }
    pub fn bitWidth(m: Member) ?u6 {
        const w: u8 = m.flags & 0x3F;
        return if (m.flags & 0xC0 == 0 and w != 0) @intCast(w) else null;
    }
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 5);
    }
};

// ————— Trailing tables (present on every fixture) —————

pub const CoverageMapEntry = packed struct { // 2 bytes, one per segment
    start_index: u16, // 1-based start into the coverage-offset table (0 = none)
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 2);
    }
};
pub const CoverageOffset = u16; // basic-block code offset within the owning segment
pub const ModuleOptFlags = u32; // MO_* bits, one per module (0 = unoptimized)

// ————— C++ extension tables (empty for plain C; spec §15) —————

pub const ClassRecord = packed struct { // 11 bytes
    parent_index: u16, // 1-based into Parent table
    parent_count: u16, // number of parents (0 = base/root)
    member_index: u16, // 1-based into Member table (class's first member)
    name_index: u16, // class tag name-pool index
    virtual_ptr: u16, // vtable-pointer offset within the object
    // `info`: NOT a base/member access specifier. Empirically (ACC fixture: a public,
    // a private AND a protected derivation of the SAME base) it reads a constant `0x0C`
    // for EVERY class — base, public-derived, private-derived, protected-derived alike —
    // so no bit here encodes `public`/`private`/`protected`. (The earlier "bit1 = public"
    // reading was wrong; bit1 is 0 even on a public-base class.) bit0 = virtual-base;
    // the rest is the `far 'this' ptr / near vbase` object descriptor TDUMP prints.
    // Access is unrecoverable from BCC 3.1's TDS — see `BaseInfo` / spec §15.1 / §17.
    info: u8,
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 11);
    }
};

pub const ParentRecord = packed struct { // 2 bytes
    class_index: u16, // 1-based Class-table index; bit15 (0x8000) = virtual base
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 2);
    }
};

/// Scope-Class and Module-Class share this 4-byte shape.
pub const ClassRange = packed struct { // 4 bytes
    class_index: u16,
    class_count: u16,
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 4);
    }
};
pub const ScopeClassRecord = ClassRange; // one per scope, when local classes exist
pub const ModuleClassRecord = ClassRange; // one per module that defines classes

// ————— Tables BC++ 3.1 never populates (count always 0); BOA-documented 16-bit forms —————

pub const BrowserRecord = packed struct { // 6 bytes
    symbol_index: u16,
    file_index: u16,
    line_number: u16,
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 6);
    }
};

pub const OptSymRecord = packed struct { // 9 bytes
    next: u16, // index of next record for this symbol (0 = end of list)
    offset: u16, // register-enum, as in Symbol
    sym_class: u8, // combined class/has_valid_BP/ret-words, as in Symbol.flags
    code_offset_start: u16,
    code_offset_end: u16,
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 9);
    }
};

/// On-disk byte stride of a fixed record `T` — `@bitSizeOf` is the byte-exact width
/// for these packed structs, whereas `@sizeOf` rounds the backing integer up to its
/// ABI alignment (e.g. a 72-bit Symbol reports `@sizeOf == 16`). Always use this for
/// the record-table walk, never `@sizeOf`.
pub fn stride(comptime T: type) usize {
    return @divExact(@bitSizeOf(T), 8);
}

comptime {
    // Lock the on-disk strides used by the block walk (regression guard against any
    // future field-width slip): these are the byte widths the parser advances by.
    std.debug.assert(stride(Symbol) == 9);
    std.debug.assert(stride(Module) == 16);
    std.debug.assert(stride(SourceFile) == 6);
    std.debug.assert(stride(Line) == 4);
    std.debug.assert(stride(Scope) == 12);
    std.debug.assert(stride(Segment) == 16);
    std.debug.assert(stride(Correlation) == 8);
    std.debug.assert(stride(Type) == 8);
    std.debug.assert(stride(Member) == 5);
    std.debug.assert(stride(ClassRecord) == 11);
    std.debug.assert(stride(ParentRecord) == 2);
    std.debug.assert(stride(ClassRange) == 4);
    std.debug.assert(stride(BrowserRecord) == 6);
    std.debug.assert(stride(OptSymRecord) == 9);
}

test "header / record sizes match the spec" {
    try std.testing.expectEqual(@as(usize, 0x30), stride(Header));
    try std.testing.expectEqual(@as(usize, 0x20), stride(ExtHeader));
    try std.testing.expectEqual(@as(usize, 9), stride(Symbol));
    try std.testing.expectEqual(@as(usize, 16), stride(Module));
    try std.testing.expectEqual(@as(usize, 6), stride(SourceFile));
    try std.testing.expectEqual(@as(usize, 4), stride(Line));
    try std.testing.expectEqual(@as(usize, 12), stride(Scope));
    try std.testing.expectEqual(@as(usize, 16), stride(Segment));
    try std.testing.expectEqual(@as(usize, 8), stride(Correlation));
    try std.testing.expectEqual(@as(usize, 8), stride(Type));
    try std.testing.expectEqual(@as(usize, 5), stride(Member));
}
