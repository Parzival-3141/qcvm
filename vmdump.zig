const std = @import("std");
const quakec = @import("qcvm.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(arena);
    std.debug.assert(args.skip());

    const file_path = args.next() orelse return error.MissingArgument;
    const prog_data = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        file_path,
        arena,
        .limited(64 * 1024 * 1024),
        .of(quakec.Header),
        null,
    );

    var qcvm: quakec.Vm = .blank;
    try quakec.loadProgram(&qcvm, prog_data, false);

    const buf = try arena.alloc(u8, 256);
    var stdout = std.Io.File.stdout().writer(io, buf);
    try quakec.dumpVm(qcvm, &stdout.interface);

    // @Todo better string escaping
    try stdout.interface.writeAll("strings:\n");
    for (qcvm.strings) |char| {
        if (char == 0) try stdout.interface.writeByte('\n');
        if (!std.ascii.isPrint(char)) continue;
        try stdout.interface.writeByte(char);
    }
    try stdout.interface.writeByte('\n');

    try stdout.end();
}
