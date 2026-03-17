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

// @Todo create handle types for strings/functions/entities?

pub const ValueType = enum(u15) {
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

pub const Offset = enum(u16) {
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

pub const Opcode = enum(u16) {
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
pub const Statement = extern struct {
    op: Opcode,
    args: [3]i16,
};

// ddef_t
pub const Def = extern struct {
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
pub const Function = extern struct {
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

    pub const MAX_PARMS = 8;
};

pub const PROG_VERSION = 6;

// dprograms_t
pub const Header = extern struct {
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

/// Quake's progdefs.h crc value
pub const PROGDEFS_CRC = 5927;

// ============================================================================

const std = @import("std");
const crc = @import("crc.zig");

const assert = std.debug.assert;
const native_endian = @import("builtin").cpu.arch.endian();

pub const Vm = struct {
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

    ///////////////////////////////////////////////////////////////////
    // The following fields should be set by the user before execution.

    /// User supplied builtin functions
    builtins: []const BuiltinFn,

    // Entities are stored in a seperate memory region that the user supplies.
    // The size of this memory region must be at least
    // num_entities * num_entity_fields * @sizeOf(u32) bytes.
    // Currently we store all entities contiguously as an array of fields (u32s),
    // but this may change in the future if we allow users to define their own
    // data layout for entities.

    // @Todo at least 1 entity must be allocated so accessing the null entity will always work
    /// User supplied entities
    entity_memory: []u32,
    num_entities: u32,

    /// User supplied string buffer
    temporary_strings_buffer: [:0]u8,

    ///////////////////////////////////////////////////
    // The following fields are managed by the runtime.

    /// The number of arguments passed to a builtin function
    argc: u4,

    call_stack: [MAX_STACK_DEPTH]struct {
        stmt: u32, // index into statements
        func: u32, // index into functions
    },
    call_stack_depth: u32, // std.math.IntFittingRange(0, MAX_STACK_DEPTH) ?

    local_stack: [LOCALSTACK_SIZE]u32,
    local_stack_used: u32, // std.math.IntFittingRange(0, LOCALSTACK_SIZE) ?

    trace: bool,
    current_function: u32,
    program_counter: u32,

    const MAX_STACK_DEPTH = 32;
    const LOCALSTACK_SIZE = 2048;

    pub const BuiltinFn = *const fn (*Vm) void;

    pub const blank: Vm = .{
        .version = 0,
        .progdefs_crc = 0,
        .program_crc = 0,

        .program = &.{},
        .strings = &.{},
        .funcs = &.{},
        .globaldefs = &.{},
        .fielddefs = &.{},
        .statements = &.{},
        .globals = &.{},

        .argc = 0,
        .builtins = &.{},

        .entity_memory = &.{},
        .num_entities = 0,
        .num_entity_fields = 0,
        .temporary_strings_buffer = @constCast(&.{}),

        .trace = false,
        .call_stack = @splat(.{ .stmt = 0, .func = 0 }),
        .call_stack_depth = 0,
        .local_stack = @splat(0),
        .local_stack_used = 0,
        .current_function = 0,
        .program_counter = 0,
    };

    pub fn getArgVector(vm: *const Vm, arg: u4) *const [3]f32 {
        const offset = @intFromEnum(Offset.parm0) + arg * 3;
        return @ptrCast(vm.globals[offset..][0..3]);
    }
    pub fn getArgInt(vm: *const Vm, arg: u4) i32 {
        const offset = @intFromEnum(Offset.parm0) + arg * 3;
        return @bitCast(vm.globals[offset]);
    }
    pub fn getArgFloat(vm: *const Vm, arg: u4) f32 {
        const offset = @intFromEnum(Offset.parm0) + arg * 3;
        return @bitCast(vm.globals[offset]);
    }
    pub fn getArgString(vm: *const Vm, arg: u4) [*:0]const u8 {
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

pub fn loadProgram(vm: *Vm, bytes: []u8, check_progdefs_crc: bool) !void {
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

    vm.version = hdr.version;
    vm.progdefs_crc = @intCast(hdr.crc);
    vm.program_crc = progs_crc;

    vm.program = bytes;
    vm.strings = strings;
    vm.funcs = funcs;
    vm.globaldefs = globaldefs;
    vm.fielddefs = fielddefs;
    vm.statements = statements;
    vm.globals = globals;

    vm.num_entity_fields = hdr.entityfields;
}

pub fn exec(vm: *Vm, func_name: []const u8, verbose_statements: bool) void {
    // @Todo add some sort of configure phase to the API where the user can
    // supply values to fulfill this contract.
    assert(vm.entity_memory.len == vm.num_entities * vm.num_entity_fields);
    assert(vm.temporary_strings_buffer.len > 0);

    // find function by name
    const func_idx: u32 = for (vm.funcs, 0..) |func, i| {
        const name = subCString(vm.strings, func.s_name);
        if (std.mem.eql(u8, name, func_name)) break @intCast(i);
    } else {
        std.log.err("could not find function '{s}'", .{func_name});
        std.process.exit(1);
    };

    const exit_depth = vm.call_stack_depth;
    var runaway: u32 = 100_000;

    enterVmFunction(vm, func_idx);
    run_loop: while (true) {
        const stmt = vm.statements[vm.program_counter];

        runaway -= 1;
        if (runaway == 0) @panic("runaway loop");

        if (verbose_statements)
            std.log.debug("{f}", .{printStatement(vm, stmt)});

        const GlobalValue = extern union {
            float: f32,
            uint: u32,
            vector: [3]f32,
            string: i32, // negative values are temporary strings
            function: u32,
            entity_index: u32,
            entity_field_offset: u32,
            entity_field_address: u32,
        };

        // Global registers accessed by statement arguments
        // @Todo bounds checking for vectors
        const a: *GlobalValue = @ptrCast(&vm.globals[@intCast(stmt.args[0])]);
        const b: *GlobalValue = @ptrCast(&vm.globals[@intCast(stmt.args[1])]);
        const c: *GlobalValue = @ptrCast(&vm.globals[@intCast(stmt.args[2])]);

        switch (stmt.op) {
            .add_f => c.float = a.float + b.float,
            .sub_f => c.float = a.float - b.float,
            .mul_f => c.float = a.float * b.float,
            .div_f => c.float = a.float / b.float,

            .add_v => for (0..3) |i| {
                c.vector[i] = a.vector[i] + b.vector[i];
            },
            .sub_v => for (0..3) |i| {
                c.vector[i] = a.vector[i] - b.vector[i];
            },
            .mul_fv => for (0..3) |i| {
                c.vector[i] = a.float * b.vector[i];
            },
            .mul_vf => for (0..3) |i| {
                c.vector[i] = a.vector[i] * b.float;
            },
            .mul_v => c.float =
                a.vector[0] * b.vector[0] +
                a.vector[1] * b.vector[1] +
                a.vector[2] * b.vector[2],

            .bitand, .bitor => |op| {
                // this casting is weird but matches Quake behavior
                const ai: i32 = @intFromFloat(a.float);
                const bi: i32 = @intFromFloat(b.float);
                c.float = @floatFromInt(if (op == .bitand) ai & bi else ai | bi);
            },
            // the following "floatFromBool" casts are weird but match Quake behavior
            .@"and" => c.float = floatFromBool(a.float != 0 and b.float != 0),
            .@"or" => c.float = floatFromBool(a.float != 0 or b.float != 0),

            .not_f => c.float = floatFromBool(a.float == 0),
            .not_v => c.float = floatFromBool(a.vector[0] == 0 and a.vector[1] == 0 and a.vector[1] == 0),
            .not_s => c.float = floatFromBool(a.string == 0 or vm.getString(a.string)[0] == 0), // check if string is null or empty
            .not_ent => c.float = floatFromBool(a.entity_index == 0), // the 0th entity should be considered null and therefore false-y
            .not_fnc => c.float = floatFromBool(a.function == 0), // same with functions

            .eq_f => c.float = floatFromBool(a.float == b.float),
            .eq_v => c.float = floatFromBool(std.mem.eql(f32, &a.vector, &b.vector)),
            .eq_s => c.float = floatFromBool(std.mem.eql(u8, vm.getString(a.string), vm.getString(b.string))),
            .eq_e => c.float = floatFromBool(a.entity_index == b.entity_index),
            .eq_fnc => c.float = floatFromBool(a.function == b.function),

            .ne_f => c.float = floatFromBool(a.float != b.float),
            .ne_v => c.float = floatFromBool(!std.mem.eql(f32, &a.vector, &b.vector)),
            .ne_s => c.float = floatFromBool(!std.mem.eql(u8, vm.getString(a.string), vm.getString(b.string))),
            .ne_e => c.float = floatFromBool(a.entity_index != b.entity_index),
            .ne_fnc => c.float = floatFromBool(a.function != b.function),

            .ge => c.float = floatFromBool(a.float >= b.float),
            .le => c.float = floatFromBool(a.float <= b.float),
            .gt => c.float = floatFromBool(a.float > b.float),
            .lt => c.float = floatFromBool(a.float < b.float),

            // store value in global register
            .store_f,
            .store_ent,
            .store_fld,
            .store_s,
            .store_fnc,
            => b.uint = a.uint,
            .store_v => @memcpy(&b.vector, &a.vector),

            // store value in entity field via its address
            .storep_f,
            .storep_ent,
            .storep_fld,
            .storep_s,
            .storep_fnc,
            => vm.entity_memory[b.entity_field_address] = a.uint,
            .storep_v => {
                const field_ptr: []f32 = @ptrCast(vm.entity_memory[b.entity_field_address..][0..3]);
                @memcpy(field_ptr, &a.vector);
            },

            // load value from entity field
            .load_f,
            .load_fld,
            .load_ent,
            .load_s,
            .load_fnc,
            => {
                const field_address = a.entity_index * vm.num_entity_fields + b.entity_field_offset;
                const field: u32 = vm.entity_memory[field_address];
                c.uint = field;
            },
            .load_v => {
                const field_address = a.entity_index * vm.num_entity_fields + b.entity_field_offset;
                const field: []f32 = @ptrCast(vm.entity_memory[field_address..][0..3]);
                @memcpy(&c.vector, field);
            },

            // store entity field address in global register
            .address => {
                // The address instruction returns a host defined entity field id, which is used in
                // storep_* instructions. The reason it's done this way is so the host entity data structure
                // does not have to directly match the QuakeC representation. In other words, all QC entity fields do not have
                // to be stored contiguously in memory. Quake utilizes this feature to store entities in the Edict (Entity Dictionary)
                // data structure, which is why it returns an offset in bytes instead of ints.
                //
                // Here we have no such limitation, so just return the offset in ints. In the future,
                // we could let the user define this mapping via a callback so they can use their own data layout.
                c.entity_field_address = a.entity_index * vm.num_entity_fields + b.entity_field_offset;
            },

            .@"if", .ifnot, .goto => |op| {
                const jump: bool, const offset: i16 = switch (op) {
                    .@"if" => .{ a.uint != 0, stmt.args[1] },
                    .ifnot => .{ a.uint == 0, stmt.args[1] },
                    .goto => .{ true, stmt.args[0] },
                    else => unreachable,
                };
                if (jump) {
                    // note this is equivalent to program_counter +%= @as(i16, offset)
                    vm.program_counter +%= @as(u16, @bitCast(offset));
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

                if (a.function == 0) @panic("null function");
                const next_func = &vm.funcs[a.function];

                if (next_func.first_statement < 0) {
                    const builtin_id: u32 = @intCast(-next_func.first_statement - 1);
                    if (builtin_id >= vm.builtins.len) {
                        std.debug.panic("unimplemented builtin: {d}", .{builtin_id + 1});
                    }
                    vm.argc = num_args;
                    vm.builtins[builtin_id](vm);
                } else {
                    enterVmFunction(vm, a.function);
                    continue; // don't increment counter
                }
            },

            .done, .@"return" => |op| {
                if (op == .@"return") @memcpy(
                    vm.globals[@intFromEnum(Offset.@"return")..][0..3],
                    vm.globals[@intCast(stmt.args[0])..][0..3],
                );
                leaveVmFunction(vm);
                if (op == .done or exit_depth == vm.call_stack_depth)
                    break :run_loop; // all done
            },

            .state => {
                @panic("unimplemented opcode: state");
            },

            _ => |op| std.debug.panic("invalid opcode: {d}", .{@intFromEnum(op)}),
        }

        vm.program_counter +%= 1;
    }
}

/// Sets up the program counter and local/call stacks
fn enterVmFunction(vm: *Vm, func_idx: u32) void {
    const func = vm.funcs[func_idx];
    assert(func.first_statement < vm.statements.len);
    assert(func.first_statement > 0);

    if (vm.call_stack_depth == 0) {
        assert(vm.program_counter == 0);
        assert(vm.current_function == 0);
    }
    vm.call_stack[vm.call_stack_depth] = .{
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
    var reg = func.parm_start;
    for (0..func.numparms) |i| {
        for (0..func.parm_sizes[i]) |j| {
            vm.globals[reg] = vm.globals[@intFromEnum(Offset.parm0) + i * 3 + j];
            reg += 1;
        }
    }

    vm.current_function = func_idx;
    vm.program_counter = @intCast(func.first_statement);
}

fn leaveVmFunction(vm: *Vm) void {
    if (vm.call_stack_depth == 0)
        @panic("call stack underflow");

    const current_func = vm.funcs[vm.current_function];

    // restore locals from the local stack
    const num_locals = current_func.locals;
    if (num_locals > vm.local_stack_used) @panic("local stack underflow");
    vm.local_stack_used -= num_locals;

    @memcpy(
        vm.globals[current_func.parm_start..][0..num_locals],
        vm.local_stack[vm.local_stack_used..][0..num_locals],
    );

    // pop call stack
    vm.call_stack_depth -= 1;
    vm.current_function = vm.call_stack[vm.call_stack_depth].func;
    vm.program_counter = vm.call_stack[vm.call_stack_depth].stmt;
}

inline fn floatFromBool(b: bool) f32 {
    return @floatFromInt(@intFromBool(b));
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

fn printStatement(vm: *const Vm, stmt: Statement) struct {
    vm: *const Vm,
    stmt: Statement,
    pub fn format(self: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
        // @Todo better printing format, this is butt ugly
        switch (self.stmt.op) {
            else => |op| try w.print("{t: <10} ", .{op}),
            _ => |op| {
                return w.print("invalid opcode: {d}", .{@intFromEnum(op)});
            },
        }

        switch (self.stmt.op) {
            .@"if", .ifnot => {
                try printGlobal(w, self.vm, @intCast(self.stmt.args[0]), true);
                try w.print("branch {d}", .{self.stmt.args[1]});
            },
            .goto => {
                try w.print("branch {d}", .{self.stmt.args[1]});
            },
            .store_f,
            .store_v,
            .store_s,
            .store_ent,
            .store_fld,
            .store_fnc,
            => {
                try printGlobal(w, self.vm, @intCast(self.stmt.args[0]), true);
                try printGlobal(w, self.vm, @intCast(self.stmt.args[1]), false);
            },
            else => {
                if (self.stmt.args[0] != 0)
                    try printGlobal(w, self.vm, @intCast(self.stmt.args[0]), true);
                if (self.stmt.args[1] != 0)
                    try printGlobal(w, self.vm, @intCast(self.stmt.args[1]), true);
                if (self.stmt.args[2] != 0)
                    try printGlobal(w, self.vm, @intCast(self.stmt.args[2]), false);
            },
            _ => unreachable,
        }
    }
} {
    return .{ .vm = vm, .stmt = stmt };
}

fn printGlobal(writer: *std.Io.Writer, vm: *const Vm, offset: u32, print_contents: bool) !void {
    assert(@as(i32, @bitCast(offset)) > 0);
    var alignment_buf: [128]u8 = undefined;
    var sw: std.Io.Writer = .fixed(&alignment_buf); // sub writer

    if (getDefAtOffset(vm.globaldefs, offset)) |global_def| print_def: {
        try sw.print("{d}({s})", .{ offset, vm.strings[global_def.s_name.. :0].ptr });
        if (!print_contents) break :print_def;

        // PR_ValueString
        const value = vm.globals[offset];
        switch (global_def.type.tag) {
            .void => try sw.writeAll("void"),
            .string => {
                const str = vm.getString(@bitCast(value));
                var str_buf: [9]u8 = undefined;
                var str_writer: std.Io.Writer = .fixed(&str_buf);
                str_writer.print("{f}", .{std.ascii.hexEscape(str, .lower)}) catch {
                    str_buf[str_buf.len - 3 ..].* = @splat('.'); // truncate string
                };
                try sw.print("\"{s}\"", .{str_writer.buffered()});
            },
            .float => try sw.printFloat(@as(f32, @bitCast(value)), .{}),
            .vector => try sw.print("{d}, {d}, {d}", .{
                @as(f32, @bitCast(vm.globals[offset + 0])),
                @as(f32, @bitCast(vm.globals[offset + 1])),
                @as(f32, @bitCast(vm.globals[offset + 2])),
            }),
            .entity => try sw.print("entity {d}", .{value}),
            .field => {
                const field_def = getDefAtOffset(vm.fielddefs, value);
                const field_str_offset = if (field_def) |d| d.s_name else 0;
                try sw.print(".{s}", .{vm.getString(@bitCast(field_str_offset))});
            },
            .function => {
                const func = vm.funcs[value];
                try sw.print("{s}()", .{vm.getString(@bitCast(func.s_name))});
            },
            .pointer => try sw.writeAll("pointer"),
            _ => |t| try sw.print("bad type {d}", .{@intFromEnum(t)}),
        }
    } else {
        try sw.print("{d}(???)", .{offset});
    }

    try writer.alignBuffer(sw.buffered(), 25, .left, ' ');
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
