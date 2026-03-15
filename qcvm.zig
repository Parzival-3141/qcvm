// Copyright (C) 1996-1997 Id Software, Inc.
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//
// See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

const func_t = enum(u32) { _ };
const string_t = enum(u32) { _ };

const ValueType = enum(u15) {
    void,
    string,
    float,
    vector,
    entity,
    field,
    function,
    pointer,
    _,
};

const Offset = enum(u16) {
    null = 0,
    @"return" = 1,
    parm0 = 4, // leave 3 ofs for each parm to hold vectors
    parm1 = 7,
    parm2 = 10,
    parm3 = 13,
    parm4 = 16,
    parm5 = 19,
    parm6 = 22,
    parm7 = 25,
    reserved_ofs = 28,
};

const Opcode = enum(u16) {
    done,
    mul_f,
    mul_v,
    mul_fv,
    mul_vf,
    div_f,
    add_f,
    add_v,
    sub_f,
    sub_v,

    eq_f,
    eq_v,
    eq_s,
    eq_e,
    eq_fnc,

    ne_f,
    ne_v,
    ne_s,
    ne_e,
    ne_fnc,

    le,
    ge,
    lt,
    gt,

    load_f,
    load_v,
    load_s,
    load_ent,
    load_fld,
    load_fnc,

    address,

    store_f,
    store_v,
    store_s,
    store_ent,
    store_fld,
    store_fnc,

    storep_f,
    storep_v,
    storep_s,
    storep_ent,
    storep_fld,
    storep_fnc,

    @"return",
    not_f,
    not_v,
    not_s,
    not_ent,
    not_fnc,
    @"if",
    ifnot,
    call0,
    call1,
    call2,
    call3,
    call4,
    call5,
    call6,
    call7,
    call8,
    state,
    goto,
    @"and",
    @"or",

    bitand,
    bitor,

    _,
};

// dstatement_t
const Statement = extern struct {
    op: Opcode,
    args: [3]i16,
};

// ddef_t
const Def = extern struct {
    type: packed struct(u16) {
        tag: ValueType,
        /// if DEF_SAVEGLOBGAL bit is set the variable needs
        /// to be saved in savegames.
        save_global: bool,
    },
    offset: u16,
    s_name: u32,
};

// dfunction_t
const Function = extern struct {
    /// negative numbers are builtins
    first_statement: i32,
    parm_start: u32,
    /// total ints of parms + locals
    locals: u32,

    /// runtime
    profile: u32,

    s_name: u32,
    /// source file defined in
    s_file: u32,

    numparms: u32,
    parm_sizes: [MAX_PARMS]u8,

    const MAX_PARMS = 8;
};

const PROG_VERSION = 6;

// dprograms_t
const Header = extern struct {
    version: u32,
    /// check of progsdefs header file
    crc: u32,

    ofs_statements: u32,
    /// statement 0 is an error
    num_statements: u32,

    ofs_globaldefs: u32,
    num_globaldefs: u32,

    ofs_fielddefs: u32,
    num_fielddefs: u32,

    ofs_functions: u32,
    /// function 0 is an empty
    num_functions: u32,

    ofs_strings: u32,
    /// first string is a null string
    size_strings: u32,

    ofs_globals: u32,
    num_globals: u32,

    entityfields: u32,
};

// ============================================================================

const std = @import("std");
const crc = @import("crc.zig");

const assert = std.debug.assert;
const native_endian = @import("builtin").cpu.arch.endian();

pub fn main() !void {
    var arena_inst: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var args = std.process.args();
    std.debug.assert(args.skip());

    const file_path = args.next() orelse return error.MissingArgument;
    const verbose = if (args.next()) |arg| std.mem.eql(u8, arg, "-v") else false;
    const prog_data = try std.fs.cwd().readFileAlloc(arena, file_path, 64 * 1024 * 1024);

    var qcvm = try loadProgram(prog_data, false);

    const max_entities = 32;
    qcvm.temporary_strings_buffer = try arena.allocSentinel(u8, 1024, 0);
    qcvm.entity_memory = try arena.alloc(u32, max_entities * qcvm.num_entity_fields);
    qcvm.num_entities = max_entities;
    qcvm.builtins = &.{
        vmSpawn,
        vmPrintf,
        vmSprintf,
    };
    exec(&qcvm, "main", verbose);
}

const Vm = struct {
    version: u32,
    /// checksum of progsdefs header file
    progdefs_crc: u16,
    program_crc: u16,

    /// Entire QuakeC program dat file loaded in memory.
    program: []const u8,

    // These fields are pointers into program memory.
    statements: []const Statement,
    funcs: []const Function,
    globaldefs: []const Def,
    fielddefs: []const Def,
    strings: [:0]const u8,
    globals: []u32,

    num_entity_fields: u32,

    /// User supplied builtin functions
    builtins: []const BuiltinFn,

    /// User supplied entities
    entity_memory: []u32,
    num_entities: u32,

    /// User supplied string buffer
    temporary_strings_buffer: [:0]u8,

    // runtime fields
    argc: u4,

    call_stack: [MAX_STACK_DEPTH]struct {
        stmt: u32,
        func: *const Function, // @Cleanup store function index instead
    },
    call_stack_depth: u32, // std.math.IntFittingRange(0, MAX_STACK_DEPTH) ?

    local_stack: [LOCALSTACK_SIZE]u32,
    local_stack_used: u32, // std.math.IntFittingRange(0, LOCALSTACK_SIZE) ?

    trace: bool,
    current_function: *const Function,
    program_counter: u32,

    const BuiltinFn = *const fn (*Vm) void;

    fn getArgVector(vm: *const Vm, arg: u4) *[3]f32 {
        const offset = @intFromEnum(Offset.parm0) + arg * 3;
        return @ptrCast(vm.globals[offset..][0..3]);
    }
    fn getArgInt(vm: *const Vm, arg: u4) i32 {
        const offset = @intFromEnum(Offset.parm0) + arg * 3;
        return @bitCast(vm.globals[offset]);
    }
    fn getArgFloat(vm: *const Vm, arg: u4) f32 {
        const offset = @intFromEnum(Offset.parm0) + arg * 3;
        return @bitCast(vm.globals[offset]);
    }
    fn getArgString(vm: *const Vm, arg: u4) [*:0]const u8 {
        const offset = @intFromEnum(Offset.parm0) + arg * 3;
        return getString(vm, @bitCast(vm.globals[offset]));
    }

    /// Returns a string from either the global or temporary strings buffer
    /// depending on whether offset is positive or negative respectively.
    /// Returns the null string if offset is out of bounds.
    fn getString(vm: *const Vm, offset: i32) [:0]const u8 {
        if (offset < 0) {
            // temp string
            var idx: u32 = @intCast(-offset);
            if (idx >= vm.temporary_strings_buffer.len) idx = 0;
            return subCString(vm.temporary_strings_buffer, idx);
        } else {
            // global string
            var idx: u32 = @intCast(offset);
            if (idx >= vm.strings.len) idx = 0;
            return subCString(vm.strings, idx);
        }
    }
};

fn loadProgram(bytes: []u8, check_progdefs_crc: bool) !Vm {
    var progs_crc = crc.init;
    for (bytes) |b| crc.processByte(&progs_crc, b);

    const hdr: *Header = @ptrCast(@alignCast(bytes.ptr));
    if (native_endian == .big) std.mem.byteSwapAllFields(Header, hdr);

    if (hdr.version != PROG_VERSION) {
        std.log.err(
            "progs.dat has wrong version number ({d} should be {d})",
            .{ hdr.version, PROG_VERSION },
        );
        return error.WrongVersion;
    }

    if (hdr.crc > std.math.maxInt(u16)) {
        return error.InvalidChecksum;
    }
    if (check_progdefs_crc and hdr.crc != PROGDEFS_CRC) {
        std.log.err(
            "crc doesn't match, progs.dat system vars have been modified (expected {d}, found {d})",
            .{ PROGDEFS_CRC, hdr.crc },
        );
        return error.InvalidChecksum;
    }

    // std.log.debug("header = {f}", .{prettyFmtStruct(hdr)});

    // zig fmt: off
    const strings:    [:0]u8      =                     bytes[hdr.ofs_strings   ..][0..hdr.size_strings                       :0];
    const funcs:      []Function  = @ptrCast(@alignCast(bytes[hdr.ofs_functions ..][0..hdr.num_functions  * @sizeOf(Function) ]));
    const globaldefs: []Def       = @ptrCast(@alignCast(bytes[hdr.ofs_globaldefs..][0..hdr.num_globaldefs * @sizeOf(Def)      ]));
    const fielddefs:  []Def       = @ptrCast(@alignCast(bytes[hdr.ofs_fielddefs ..][0..hdr.num_fielddefs  * @sizeOf(Def)      ]));
    const statements: []Statement = @ptrCast(@alignCast(bytes[hdr.ofs_statements..][0..hdr.num_statements * @sizeOf(Statement)]));
    const globals:    []u32       = @ptrCast(@alignCast(bytes[hdr.ofs_globals   ..][0..hdr.num_globals    * @sizeOf(u32)      ]));
    // zig fmt: on

    if (native_endian == .big) {
        std.mem.byteSwapAllElements(Statement, statements);
        std.mem.byteSwapAllElements(Function, funcs);
        std.mem.byteSwapAllElements(Def, globaldefs);
        std.mem.byteSwapAllElements(Def, fielddefs);
        std.mem.byteSwapAllElements(u32, globals);
    }

    return .{
        .version = hdr.version,
        .progdefs_crc = @intCast(hdr.crc),
        .program_crc = progs_crc,

        .program = bytes,
        .strings = strings,
        .funcs = funcs,
        .globaldefs = globaldefs,
        .fielddefs = fielddefs,
        .statements = statements,
        .globals = globals,

        .argc = 0,
        .builtins = &.{},

        .entity_memory = &.{},
        .num_entities = 0,
        .num_entity_fields = hdr.entityfields,
        .temporary_strings_buffer = @constCast(&.{}),

        .trace = false,
        .call_stack = undefined,
        .call_stack_depth = 0,
        .local_stack = undefined,
        .local_stack_used = 0,
        .current_function = undefined,
        .program_counter = 0,
    };
}

fn exec(vm: *Vm, func_name: []const u8, verbose_statements: bool) void {
    // @Todo add some sort of configure phase to the API where the user can
    // supply values to fulfill this contract.
    assert(vm.entity_memory.len == vm.num_entities * vm.num_entity_fields);
    assert(vm.temporary_strings_buffer.len > 0);

    // find function by name
    const func: *const Function = for (vm.funcs) |*func| {
        const name = subCString(vm.strings, func.s_name);
        if (std.mem.eql(u8, name, func_name)) break func;
    } else {
        std.log.err("could not find function '{s}'", .{func_name});
        std.process.exit(1);
    };

    var buf: [1024]u8 = undefined;

    const exit_depth = vm.call_stack_depth;
    var runaway: u32 = 100_000;

    enterVmFunction(vm, func);
    run_loop: while (true) {
        const stmt = vm.statements[vm.program_counter];

        runaway -= 1;
        if (runaway == 0) @panic("runaway loop");

        if (verbose_statements)
            std.log.debug("{s}", .{printStatement(&buf, vm.*, stmt) catch @panic("OOM")});

        // @Cleanup cut down on ptr/bitCasting by using an extern union for values?
        // @Cleanup compress similar codepaths
        switch (stmt.op) {
            .add_f => {
                const a: f32 = @bitCast(vm.globals[@intCast(stmt.args[0])]);
                const b: f32 = @bitCast(vm.globals[@intCast(stmt.args[1])]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = a + b;
            },
            .sub_f => {
                const a: f32 = @bitCast(vm.globals[@intCast(stmt.args[0])]);
                const b: f32 = @bitCast(vm.globals[@intCast(stmt.args[1])]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = a - b;
            },
            .mul_f => {
                const a: f32 = @bitCast(vm.globals[@intCast(stmt.args[0])]);
                const b: f32 = @bitCast(vm.globals[@intCast(stmt.args[1])]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = a * b;
            },
            .div_f => {
                const a: f32 = @bitCast(vm.globals[@intCast(stmt.args[0])]);
                const b: f32 = @bitCast(vm.globals[@intCast(stmt.args[1])]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = a / b;
            },

            .add_v => {
                const a: []const f32 = @ptrCast(vm.globals[@intCast(stmt.args[0])..][0..3]);
                const b: []const f32 = @ptrCast(vm.globals[@intCast(stmt.args[1])..][0..3]);
                const c: []f32 = @ptrCast(vm.globals[@intCast(stmt.args[1])..][0..3]);
                for (0..3) |i| c[i] = a[i] + b[i];
            },
            .sub_v => {
                const a: []const f32 = @ptrCast(vm.globals[@intCast(stmt.args[0])..][0..3]);
                const b: []const f32 = @ptrCast(vm.globals[@intCast(stmt.args[1])..][0..3]);
                const c: []f32 = @ptrCast(vm.globals[@intCast(stmt.args[1])..][0..3]);
                for (0..3) |i| c[i] = a[i] - b[i];
            },
            .mul_v => {
                const a: []const f32 = @ptrCast(vm.globals[@intCast(stmt.args[0])..][0..3]);
                const b: []const f32 = @ptrCast(vm.globals[@intCast(stmt.args[1])..][0..3]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
            },
            .mul_fv => {
                const a: f32 = @bitCast(vm.globals[@intCast(stmt.args[0])]);
                const b: []const f32 = @ptrCast(vm.globals[@intCast(stmt.args[1])..][0..3]);
                const c: []f32 = @ptrCast(vm.globals[@intCast(stmt.args[2])..][0..3]);
                for (0..3) |i| c[i] = a * b[i];
            },
            .mul_vf => {
                const a: []const f32 = @ptrCast(vm.globals[@intCast(stmt.args[0])..][0..3]);
                const b: f32 = @bitCast(vm.globals[@intCast(stmt.args[1])]);
                const c: []f32 = @ptrCast(vm.globals[@intCast(stmt.args[2])..][0..3]);
                for (0..3) |i| c[i] = a[i] * b;
            },

            .bitand => {
                const fa: f32 = @bitCast(vm.globals[@intCast(stmt.args[0])]);
                const fb: f32 = @bitCast(vm.globals[@intCast(stmt.args[1])]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                // this casting is weird but matches Quake behavior
                const a: i32 = @intFromFloat(fa);
                const b: i32 = @intFromFloat(fb);
                c.* = @floatFromInt(a & b);
            },
            .bitor => {
                const fa: f32 = @bitCast(vm.globals[@intCast(stmt.args[0])]);
                const fb: f32 = @bitCast(vm.globals[@intCast(stmt.args[1])]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                // this casting is weird but matches Quake behavior
                const a: i32 = @intFromFloat(fa);
                const b: i32 = @intFromFloat(fb);
                c.* = @floatFromInt(a | b);
            },

            .@"and" => {
                const a: f32 = @bitCast(vm.globals[@intCast(stmt.args[0])]);
                const b: f32 = @bitCast(vm.globals[@intCast(stmt.args[1])]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = @floatFromInt(@intFromBool(a != 0 and b != 0)); // this casting is weird but matches Quake behavior
            },
            .@"or" => {
                const a: f32 = @bitCast(vm.globals[@intCast(stmt.args[0])]);
                const b: f32 = @bitCast(vm.globals[@intCast(stmt.args[1])]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = @floatFromInt(@intFromBool(a != 0 or b != 0)); // this casting is weird but matches Quake behavior
            },

            .not_f => {
                const a: f32 = @bitCast(vm.globals[@intCast(stmt.args[0])]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = @floatFromInt(@intFromBool(a == 0)); // this casting is weird but matches Quake behavior
            },
            .not_v => {
                const a: []const f32 = @ptrCast(vm.globals[@intCast(stmt.args[0])..][0..3]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = @floatFromInt(@intFromBool(a[0] == 0 and a[1] == 0 and a[1] == 0)); // this casting is weird but matches Quake behavior
            },
            .not_s => {
                const a: u32 = vm.globals[@intCast(stmt.args[0])];
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                // check if string is null or empty
                c.* = @floatFromInt(@intFromBool(a == 0 or vm.getString(@bitCast(a))[0] == 0)); // this casting is weird but matches Quake behavior
            },
            .not_fnc => {
                const a: u32 = vm.globals[@intCast(stmt.args[0])];
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = @floatFromInt(@intFromBool(a == 0)); // this casting is weird but matches Quake behavior
            },
            .not_ent => {
                const a: u32 = vm.globals[@intCast(stmt.args[0])];
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                // the 0th entity should be considered null and therefore false-y
                c.* = @floatFromInt(@intFromBool(a == 0)); // this casting is weird but matches Quake behavior
            },

            .eq_f => {
                const a: f32 = @bitCast(vm.globals[@intCast(stmt.args[0])]);
                const b: f32 = @bitCast(vm.globals[@intCast(stmt.args[1])]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = @floatFromInt(@intFromBool(a == b)); // this casting is weird but matches Quake behavior
            },
            .eq_v => {
                const a: []const f32 = @ptrCast(vm.globals[@intCast(stmt.args[0])..][0..3]);
                const b: []const f32 = @ptrCast(vm.globals[@intCast(stmt.args[1])..][0..3]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = @floatFromInt(@intFromBool( // this casting is weird but matches Quake behavior
                    a[0] == b[0] and a[1] == b[1] and a[2] == b[2],
                ));
            },
            .eq_s => {
                const a: i32 = @bitCast(vm.globals[@intCast(stmt.args[0])]);
                const b: i32 = @bitCast(vm.globals[@intCast(stmt.args[1])]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = @floatFromInt(@intFromBool( // this casting is weird but matches Quake behavior
                    std.mem.eql(u8, vm.getString(a), vm.getString(b)),
                ));
            },
            .eq_e, .eq_fnc => {
                const a: u32 = vm.globals[@intCast(stmt.args[0])];
                const b: u32 = vm.globals[@intCast(stmt.args[1])];
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = @floatFromInt(@intFromBool(a == b)); // this casting is weird but matches Quake behavior
            },

            .ne_f => {
                const a: f32 = @bitCast(vm.globals[@intCast(stmt.args[0])]);
                const b: f32 = @bitCast(vm.globals[@intCast(stmt.args[1])]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = @floatFromInt(@intFromBool(a == b)); // this casting is weird but matches Quake behavior
            },
            .ne_v => {
                const a: []const f32 = @ptrCast(vm.globals[@intCast(stmt.args[0])..][0..3]);
                const b: []const f32 = @ptrCast(vm.globals[@intCast(stmt.args[1])..][0..3]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = @floatFromInt(@intFromBool( // this casting is weird but matches Quake behavior
                    a[0] != b[0] or a[1] != b[1] or a[2] != b[2],
                ));
            },
            .ne_s => {
                const a: i32 = @bitCast(vm.globals[@intCast(stmt.args[0])]);
                const b: i32 = @bitCast(vm.globals[@intCast(stmt.args[1])]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = @floatFromInt(@intFromBool( // this casting is weird but matches Quake behavior
                    !std.mem.eql(u8, vm.getString(a), vm.getString(b)),
                ));
            },
            .ne_e, .ne_fnc => {
                const a: u32 = vm.globals[@intCast(stmt.args[0])];
                const b: u32 = vm.globals[@intCast(stmt.args[1])];
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = @floatFromInt(@intFromBool(a != b)); // this casting is weird but matches Quake behavior
            },

            .ge => {
                const a: f32 = @bitCast(vm.globals[@intCast(stmt.args[0])]);
                const b: f32 = @bitCast(vm.globals[@intCast(stmt.args[1])]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = @floatFromInt(@intFromBool(a >= b)); // this casting is weird but matches Quake behavior
            },
            .le => {
                const a: f32 = @bitCast(vm.globals[@intCast(stmt.args[0])]);
                const b: f32 = @bitCast(vm.globals[@intCast(stmt.args[1])]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = @floatFromInt(@intFromBool(a <= b)); // this casting is weird but matches Quake behavior
            },
            .gt => {
                const a: f32 = @bitCast(vm.globals[@intCast(stmt.args[0])]);
                const b: f32 = @bitCast(vm.globals[@intCast(stmt.args[1])]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = @floatFromInt(@intFromBool(a > b)); // this casting is weird but matches Quake behavior
            },
            .lt => {
                const a: f32 = @bitCast(vm.globals[@intCast(stmt.args[0])]);
                const b: f32 = @bitCast(vm.globals[@intCast(stmt.args[1])]);
                const c: *f32 = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);
                c.* = @floatFromInt(@intFromBool(a < b)); // this casting is weird but matches Quake behavior
            },

            // store value in global register
            .store_f,
            .store_ent,
            .store_fld, // integers
            .store_s,
            .store_fnc, // pointers
            => {
                const rvalue: u32 = vm.globals[@intCast(stmt.args[0])];
                const lvalue: *u32 = &vm.globals[@intCast(stmt.args[1])];
                lvalue.* = rvalue;
            },
            .store_v => {
                const rvalue: []f32 = @ptrCast(vm.globals[@intCast(stmt.args[0])..][0..3]);
                const lvalue: []f32 = @ptrCast(vm.globals[@intCast(stmt.args[1])..][0..3]);
                @memcpy(lvalue, rvalue);
            },

            // store value in entity field via its address
            .storep_f,
            .storep_ent,
            .storep_fld, // integers
            .storep_s,
            .storep_fnc, // pointers
            => {
                const rvalue: u32 = vm.globals[@intCast(stmt.args[0])];
                const entity_field_address: u32 = vm.globals[@intCast(stmt.args[1])];

                // old byte address version
                // const entities_bytes: []u8 = @ptrCast(vm.entity_memory);
                // const field_ptr: *align(1) u32 = @ptrCast(&entities_bytes[entity_field_address]);

                const field_ptr: *u32 = &vm.entity_memory[entity_field_address];
                field_ptr.* = rvalue;
            },
            .storep_v => {
                const rvalue: []f32 = @ptrCast(vm.globals[@intCast(stmt.args[0])..][0..3]);
                const entity_field_address: u32 = vm.globals[@intCast(stmt.args[1])];

                const field_ptr: []f32 = @ptrCast(vm.entity_memory[entity_field_address..][0..3]);
                @memcpy(field_ptr, rvalue);
            },

            // load value from entity field
            .load_f,
            .load_fld,
            .load_ent,
            .load_s,
            .load_fnc,
            => {
                const entity_idx: u32 = vm.globals[@intCast(stmt.args[0])];
                const field_offset: u32 = vm.globals[@intCast(stmt.args[1])];
                const lvalue: *u32 = &vm.globals[@intCast(stmt.args[2])];

                const field: u32 = vm.entity_memory[entity_idx * vm.num_entity_fields + field_offset];
                lvalue.* = field;
            },
            .load_v => {
                const entity_idx: u32 = vm.globals[@intCast(stmt.args[0])];
                const field_offset: u32 = vm.globals[@intCast(stmt.args[1])];
                const lvalue: []f32 = @ptrCast(vm.globals[@intCast(stmt.args[2])..][0..3]);

                const field_address = entity_idx * vm.num_entity_fields + field_offset;
                const field: []f32 = @ptrCast(vm.entity_memory[field_address..][0..3]);
                @memcpy(lvalue, field);
            },

            // store entity field address in global register
            .address => {
                const entity_idx: u32 = vm.globals[@intCast(stmt.args[0])];
                const field_offset: u32 = vm.globals[@intCast(stmt.args[1])];
                const lvalue: *u32 = &vm.globals[@intCast(stmt.args[2])];

                // old byte address version
                // // get entity field pointer
                // const field_ptr: *u32 = &(vm.entity_memory[entity_idx * vm.num_entity_fields ..][field_offset]);
                // // store offset from start of entities buffer
                // lvalue.* = @intCast(@intFromPtr(field_ptr) - @intFromPtr(vm.entity_memory.ptr));

                // hypothesis: the address instruction returns a host defined entity field id, which is used in
                // storep_* instructions. The reason it's done this way is so the host entity data structure
                // does not have to directly match the QuakeC representation. In other words, all QC entity fields do not have
                // to be stored contiguously in memory. Quake utilizes this feature to store entities in the Edict (Entity Dictionary)
                // data structure.

                const field_address = entity_idx * vm.num_entity_fields + field_offset;
                lvalue.* = field_address;
            },

            .@"if", .ifnot, .goto => |op| {
                const a: u32 = vm.globals[@intCast(stmt.args[0])];
                const predicate, const jump_offset = switch (op) {
                    .@"if" => .{ a != 0, stmt.args[1] },
                    .ifnot => .{ a == 0, stmt.args[1] },
                    .goto => .{ true, stmt.args[0] },
                    else => unreachable,
                };
                if (predicate) {
                    // note this is equivalent to program_counter +%= @as(i16, stmt.args[1])
                    vm.program_counter +%= @as(u16, @bitCast(jump_offset));
                    continue; // don't increment counter
                }
            },

            .call0,
            .call1,
            .call2,
            .call3,
            .call4,
            .call5,
            .call6,
            .call7,
            .call8,
            => |call| {
                const num_args: u4 = @intCast(@intFromEnum(call) - @intFromEnum(Opcode.call0));
                const func_id = vm.globals[@as(u16, @bitCast(stmt.args[0]))];
                if (func_id == 0) {
                    @panic("NULL function");
                }

                const next_func = &vm.funcs[func_id];
                if (next_func.first_statement < 0) {
                    const builtin_id: u32 = @bitCast(-next_func.first_statement - 1);
                    if (builtin_id >= vm.builtins.len) {
                        std.debug.panic("unimplemented builtin: {d}", .{builtin_id + 1});
                    }
                    vm.argc = num_args;
                    vm.builtins[builtin_id](vm);
                } else {
                    enterVmFunction(vm, next_func);
                    continue; // don't increment counter
                }
            },

            .done => {
                break :run_loop;
            },
            .@"return" => {
                @memcpy(
                    vm.globals[@intFromEnum(Offset.@"return")..][0..3],
                    vm.globals[@intCast(stmt.args[0])..][0..3],
                );
                leaveVmFunction(vm);
                if (exit_depth == vm.call_stack_depth)
                    break :run_loop; // all done
            },

            .state => {
                std.debug.panic("unimplemented opcode: state", .{});
            },

            _ => |op| std.debug.panic("invalid opcode: {d}", .{@intFromEnum(op)}),
        }

        vm.program_counter +%= 1;
    }
}

/// Sets up the program counter and local/call stacks
fn enterVmFunction(vm: *Vm, func: *const Function) void {
    assert(func.first_statement < vm.statements.len);
    assert(func.first_statement > 0);

    vm.call_stack[vm.call_stack_depth] = if (vm.call_stack_depth == 0)
        // @Cleanup should the first callstack entry be a null value instead?
        .{
            .stmt = @intCast(func.first_statement),
            .func = func,
        }
    else
        .{
            .stmt = vm.program_counter,
            .func = vm.current_function,
        };

    vm.call_stack_depth += 1;
    if (vm.call_stack_depth >= vm.call_stack.len)
        @panic("call stack overflow"); // @Todo stack trace

    // Save any locals the new function would overwrite.
    // This can cause redundant copies in the pathological case,
    // but is otherwise necessary.
    if (vm.local_stack_used + func.locals > vm.local_stack.len)
        @panic("local stack overflow"); // @Todo stack trace
    @memcpy(
        vm.local_stack[vm.local_stack_used..][0..func.locals],
        vm.globals[func.parm_start..][0..func.locals],
    );
    vm.local_stack_used += func.locals;

    // copy parameters into global registers
    var o = func.parm_start;
    for (0..func.numparms) |i| {
        for (0..func.parm_sizes[i]) |j| {
            vm.globals[o] = vm.globals[@intFromEnum(Offset.parm0) + i * 3 + j];
            o += 1;
        }
    }

    vm.current_function = func;
    vm.program_counter = @intCast(func.first_statement);
}

fn leaveVmFunction(vm: *Vm) void {
    if (vm.call_stack_depth == 0)
        @panic("call stack underflow");

    // restore locals from the local stack
    const num_locals = vm.current_function.locals;
    if (num_locals > vm.local_stack_used) @panic("local stack underflow");
    vm.local_stack_used -= num_locals;

    @memcpy(
        vm.globals[vm.current_function.parm_start..][0..num_locals],
        vm.local_stack[vm.local_stack_used..][0..num_locals],
    );

    // pop call stack
    vm.call_stack_depth -= 1;
    vm.current_function = vm.call_stack[vm.call_stack_depth].func;
    vm.program_counter = vm.call_stack[vm.call_stack_depth].stmt;
}

// fn entityFieldPtr(vm: Vm, entity: u32, field_offset: u32) u32{}

// entity spawn() = #1 : spawn;
fn vmSpawn(vm: *Vm) void {
    const S = struct {
        var active_entities: u32 = 0;
    };
    if (S.active_entities == vm.num_entities) @panic("exceeded entity limit");
    S.active_entities += 1;
    vm.globals[@intFromEnum(Offset.@"return")] = S.active_entities;
}

// void printf(string s, ...) = #2 : printf;
fn vmPrintf(vm: *Vm) void {
    if (vm.argc == 0) @panic("too few arguments");
    const fmt = vm.getArgString(0);

    var buf: [256]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);

    vmPrintInner(vm, fmt, &stdout.interface) catch @panic("write error");
    stdout.end() catch @panic("write error");
}

// string sprintf(string s, ...) = #3 : sprintf;
fn vmSprintf(vm: *Vm) void {
    if (vm.argc == 0) @panic("too few arguments");
    const fmt = vm.getArgString(0);

    var w: std.Io.Writer = .fixed(vm.temporary_strings_buffer[1..]);

    vmPrintInner(vm, fmt, &w) catch @panic("write error");
    w.flush() catch unreachable;

    vm.temporary_strings_buffer[0] = 0;
    vm.globals[@intFromEnum(Offset.@"return")] = @bitCast(@as(i32, -1));
}

fn vmPrintInner(vm: *Vm, fmt: [*:0]const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var arg: u4 = 1;
    var i: usize = 0;
    while (fmt[i] != 0) {
        if (fmt[i] != '%') {
            try w.writeByte(fmt[i]);
            i += 1;
            continue;
        }

        if (arg >= vm.argc and fmt[i + 1] != '%') {
            // std.debug.panic("unused format argument {d}", .{arg});
            break;
        }
        switch (fmt[i + 1]) {
            0 => std.debug.panic("missing format specifier for argument {d}", .{arg}),
            '%' => try w.writeByte('%'),
            's' => { // string
                try w.writeAll(std.mem.span(vm.getArgString(arg)));
                arg += 1;
            },
            'f' => { // float
                try w.printFloat(vm.getArgFloat(arg), .{});
                arg += 1;
            },
            'd' => { // signed int
                try w.printInt(vm.getArgInt(arg), 10, .lower, .{});
                arg += 1;
            },
            'v' => { // vec3
                const vec = vm.getArgVector(arg);
                try w.print("{d}, {d}, {d}", .{ vec[0], vec[1], vec[2] });
                arg += 1;
            },
            else => std.debug.panic("invalid format specifier '{c}' for argument {d}", .{ fmt[i + 1], arg }),
        }
        i += 2;
    }
    try w.writeByte(0);
}

fn subCString(strings: [:0]const u8, start_idx: usize) [:0]const u8 {
    const end = std.mem.indexOfScalarPos(u8, strings, start_idx, 0) orelse strings.len;
    return strings[start_idx..end :0];
}

fn getDefAtOffset(defs: []const Def, offset: u32) ?*const Def {
    return for (defs) |*d| {
        if (d.offset == offset) break d;
    } else null;
}

fn printGlobal(w: *std.Io.Writer, vm: Vm, offset: u32) !void {
    assert(@as(i32, @bitCast(offset)) > 0);
    const start = w.end;
    if (getDefAtOffset(vm.globaldefs, offset)) |global_def| {
        try w.print("{d}({s})", .{ offset, vm.strings[global_def.s_name.. :0].ptr });
        // PR_ValueString
        const value = vm.globals[offset];
        switch (global_def.type.tag) {
            .void => try w.writeAll("void"),
            .string => {
                const str = vm.getString(@bitCast(value));
                try w.print("\"{f}\" ", .{std.ascii.hexEscape(str, .lower)});
            },
            .float => try w.printFloat(@as(f32, @bitCast(value)), .{}),
            .vector => try w.print("{d}, {d}, {d}", .{
                @as(f32, @bitCast(vm.globals[offset + 0])),
                @as(f32, @bitCast(vm.globals[offset + 1])),
                @as(f32, @bitCast(vm.globals[offset + 2])),
            }),
            .entity => try w.print("entity {d}", .{value}),
            .field => {
                const field_def = getDefAtOffset(vm.fielddefs, value);
                const field_str_offset = if (field_def) |d| d.s_name else 0;
                try w.print(".{s}", .{vm.getString(@bitCast(field_str_offset))});
            },
            .function => {
                const func = vm.funcs[value];
                try w.print("{s}()", .{vm.getString(@bitCast(func.s_name))});
            },
            .pointer => try w.writeAll("pointer"),
            _ => |t| try w.print("bad type {d}", .{@intFromEnum(t)}),
        }
    } else {
        try w.print("{d}(???)", .{offset});
    }

    try w.splatByteAll(' ', 25 -| (w.end - start)); // pad with 25 spaces
}

fn printGlobalNoContents(w: *std.Io.Writer, vm: Vm, offset: u32) !void {
    assert(@as(i32, @bitCast(offset)) > 0);
    const start = w.end;

    if (getDefAtOffset(vm.globaldefs, offset)) |def| {
        try w.print("{d}({s})", .{ offset, vm.strings[def.s_name.. :0].ptr });
    } else {
        try w.print("{d}(???)", .{offset});
    }

    try w.splatByteAll(' ', 25 -| (w.end - start)); // pad with 25 spaces
}

// @Todo better printing format, this is butt ugly
fn printStatement(buf: []u8, vm: Vm, stmt: Statement) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    switch (stmt.op) {
        else => |op| try w.print("{t: <10} ", .{op}),
        _ => |op| {
            try w.print("invalid opcode: {d}", .{@intFromEnum(op)});
            return w.buffered();
        },
    }

    switch (stmt.op) {
        .@"if", .ifnot => {
            try printGlobal(&w, vm, @intCast(stmt.args[0]));
            try w.print("branch {d}", .{stmt.args[1]});
        },
        .goto => {
            try w.print("branch {d}", .{stmt.args[1]});
        },
        .store_f,
        .store_v,
        .store_s,
        .store_ent,
        .store_fld,
        .store_fnc,
        => {
            try printGlobal(&w, vm, @intCast(stmt.args[0]));
            try printGlobalNoContents(&w, vm, @intCast(stmt.args[1]));
        },
        else => {
            if (stmt.args[0] != 0)
                try printGlobal(&w, vm, @intCast(stmt.args[0]));
            if (stmt.args[1] != 0)
                try printGlobal(&w, vm, @intCast(stmt.args[1]));
            if (stmt.args[2] != 0)
                try printGlobalNoContents(&w, vm, @intCast(stmt.args[2]));
        },
        _ => unreachable,
    }
    return w.buffered();
}

fn dumpVm(vm: Vm) void {
    const PrettyFunc = struct {
        func: Function,
        strings: [:0]u8,

        pub fn format(
            self: @This(),
            w: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            if (self.func.first_statement == 0) {
                return w.writeAll("fn null");
            }

            try w.print("{s}.{s}:", .{
                @as([*:0]const u8, @ptrCast(&self.strings[self.func.s_file])),
                @as([*:0]const u8, @ptrCast(&self.strings[self.func.s_name])),
            });

            if (self.func.first_statement < 0) {
                try w.print(" builtin={d}", .{-self.func.first_statement});
            } else {
                try w.print(" entry=0x{X}", .{self.func.first_statement});
            }

            try w.print(", #params={d}, #locals={d}", .{
                self.func.numparms,
                self.func.locals,
            });
        }
    };

    for (vm.funcs, 0..) |func, i| {
        std.log.debug("fn[{d}] {f}", .{ i, PrettyFunc{ .func = func, .strings = vm.strings } });
    }

    for (vm.globaldefs, 0..) |def, i| {
        if (def.offset == 0)
            std.log.debug("globaldef[{d}] null", .{i})
        else
            std.log.debug("globaldef[{d}] {s}: type={t}, offset=0x{X}, save={}", .{
                i,
                @as([*:0]const u8, @ptrCast(&vm.strings[def.s_name])),
                def.type.tag,
                def.offset,
                def.type.save_global,
            });
    }

    for (vm.fielddefs, 0..) |def, i| {
        if (def.offset == 0)
            std.log.debug("fielddef[{d}] null", .{i})
        else
            std.log.debug("fielddef[{d}] {s}: type={t}, offset=0x{X}, save={}", .{
                i,
                @as([*:0]const u8, @ptrCast(&vm.strings[def.s_name])),
                def.type.tag,
                def.offset,
                def.type.save_global,
            });
    }

    const opcode_name_len = comptime blk: {
        var len: usize = 0;
        for (@typeInfo(Opcode).@"enum".fields) |field| {
            len = @max(len, field.name.len);
        }
        break :blk std.fmt.comptimePrint("{d}", .{len});
    };

    for (vm.statements, 0..) |stmt, i| {
        std.log.debug("asm[{d}] {t: >" ++ opcode_name_len ++ "}: a=0x{X:0>2} b=0x{X:0>2} c=0x{X:0>2}", .{
            i,
            stmt.op,
            @as(u16, @bitCast(stmt.args[0])),
            @as(u16, @bitCast(stmt.args[1])),
            @as(u16, @bitCast(stmt.args[2])),
        });
    }

    std.log.debug("globals: {any}", .{vm.globals});
}

fn prettyFmtStruct(data: anytype) struct {
    data: @TypeOf(data),
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const fields = switch (@typeInfo(@TypeOf(data))) {
            .@"struct" => |info| info.fields,
            .pointer => |info| @typeInfo(info.child).@"struct".fields,
            else => unreachable,
        };

        try writer.writeAll(".{");
        if (fields.len > 0) try writer.writeByte('\n');
        inline for (fields) |field| {
            try writer.writeAll("  ." ++ field.name ++ " = ");
            try writer.printValue("any", .{}, @field(self.data, field.name), 1);
            try writer.writeAll(",\n");
        }
        try writer.writeByte('}');
    }
} {
    return .{ .data = data };
}

// ============================================================================

const eval_t = extern union {
    string: string_t,
    float: f32,
    vector: [3]f32,
    function: func_t,
    int: c_int,
    edict: c_int,
};

const builtin_t = *const fn () void;
const prstack_t = struct {
    s: c_int,
    f: *Function,
};
const MAX_STACK_DEPTH = 32;
const LOCALSTACK_SIZE = 2048;

const QCVM = struct {
    progs: *const Header,
    // all these pointers derive their lengths from the header
    functions: [*]const Function,
    strings: [*:0]const u8,
    globaldefs: [*]const Def,
    fielddefs: [*]const Def,
    statements: [*]const Statement,
    global_struct: *globalvars_t,
    globals: *[@sizeOf(globalvars_t) / @sizeOf(f32)]f32, // same as global_struct

    edict_size: c_int, // in bytes

    builtins: []const builtin_t,
    // int numbuiltins;

    argc: c_int,

    call_stack: [MAX_STACK_DEPTH]prstack_t,
    depth: c_int,

    localstack: [LOCALSTACK_SIZE]c_int,
    localstack_used: c_int,

    trace: bool,
    xfunction: *Function,
    xstatement: c_int,

    crc: u16,
};

// progdefs.q1
const globalvars_t = extern struct {
    //! QuakeC Global variables.
    //! Must be kept in sync with defs.qc
};

const entvars_t = extern struct {
    //! QuakeC Entity fields.
    //! Must be kept in sync with defs.qc
};

/// Quake's progdefs.h crc value
const PROGDEFS_CRC = 5927;
