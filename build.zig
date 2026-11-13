const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vm_mod = b.addModule("qcvm", .{ .root_source_file = b.path("qcvm.zig") });

    const hello_exe = b.addExecutable(.{
        .name = "hello_qc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("hello.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "qcvm", .module = vm_mod }},
        }),
    });
    b.installArtifact(hello_exe);

    const fteqcc_out = addCompileFTEQuakeC(b, b.path("hello_world.qc"));

    const run_hello = b.addRunArtifact(hello_exe);
    run_hello.step.dependOn(b.getInstallStep()); // run from prefix dir
    run_hello.step.dependOn(&b.addInstallBinFile(fteqcc_out, "hello.dat").step);
    run_hello.addFileArg(fteqcc_out);
    run_hello.addPassthruArgs();
    b.step("run", "Compile and run hello.qc").dependOn(&run_hello.step);
}

fn addCompileFTEQuakeC(b: *std.Build, qc_src: std.Build.LazyPath) std.Build.LazyPath {
    const qcc = b.addSystemCommand(&.{"fteqcc64"});
    qcc.addArg("-srcfile");
    qcc.addFileArg(qc_src);
    qcc.addArg("-o");
    const output = qcc.addOutputFileArg("progs.dat");
    // "-Fwasm",
    return output;
}
