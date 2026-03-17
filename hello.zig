const std = @import("std");
const quakec = @import("qcvm.zig");

pub fn main() !void {
    var arena_inst: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var args = std.process.args();
    std.debug.assert(args.skip());

    const file_path = args.next() orelse return error.MissingArgument;
    const verbose = if (args.next()) |arg| std.mem.eql(u8, arg, "-v") else false;
    const prog_data = try std.fs.cwd().readFileAlloc(arena, file_path, 64 * 1024 * 1024);

    var qcvm: quakec.Vm = .blank;
    try quakec.loadProgram(&qcvm, prog_data, false);

    qcvm.num_entities = 32;
    qcvm.entity_memory = try arena.alloc(u32, qcvm.num_entities * qcvm.num_entity_fields);
    qcvm.temporary_strings_buffer = try arena.allocSentinel(u8, 1024, 0);
    qcvm.builtins = &.{
        vmSpawn,
        vmPrintf,
        vmSprintf,
    };
    quakec.exec(&qcvm, "main", verbose);
}

// entity spawn() = #1 : spawn;
fn vmSpawn(vm: *quakec.Vm) void {
    const S = struct {
        var active_entities: u32 = 0;
    };
    if (S.active_entities == vm.num_entities) @panic("exceeded entity limit");
    S.active_entities += 1;
    vm.globals[@intFromEnum(quakec.Offset.@"return")] = S.active_entities;
}

// void printf(string s, ...) = #2 : printf;
fn vmPrintf(vm: *quakec.Vm) void {
    if (vm.argc == 0) @panic("too few arguments");
    const fmt = vm.getArgString(0);

    var buf: [256]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);

    vmPrintInner(vm, fmt, &stdout.interface) catch @panic("write error");
    stdout.end() catch @panic("write error");
}

// string sprintf(string s, ...) = #3 : sprintf;
fn vmSprintf(vm: *quakec.Vm) void {
    if (vm.argc == 0) @panic("too few arguments");
    const fmt = vm.getArgString(0);

    var w: std.Io.Writer = .fixed(vm.temporary_strings_buffer[1..]);

    vmPrintInner(vm, fmt, &w) catch @panic("write error");
    w.flush() catch unreachable;

    vm.temporary_strings_buffer[0] = 0;
    vm.globals[@intFromEnum(quakec.Offset.@"return")] = @bitCast(@as(i32, -1));
}

fn vmPrintInner(
    vm: *quakec.Vm,
    fmt: [*:0]const u8,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
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
