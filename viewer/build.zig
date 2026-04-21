const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addIncludePath(.{ .cwd_relative = "/usr/include/SDL3" });
    exe_mod.addIncludePath(.{ .cwd_relative = "/usr/include/luajit-2.1" });
    exe_mod.linkSystemLibrary("SDL3", .{});
    exe_mod.linkSystemLibrary("luajit-5.1", .{});
    exe_mod.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "ast-viewer",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the viewer");
    run_step.dependOn(&run.step);
}
