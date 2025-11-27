const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get the roc dependency and its builtins module
    const roc_dep = b.dependency("roc", .{});
    const builtins_module = roc_dep.module("builtins");

    // Build the platform host as a static library
    // This will be linked with the Roc-compiled app object file
    const host_lib = b.addLibrary(.{
        .name = "host",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("platform/host.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .pic = true, // Enable Position Independent Code for PIE compatibility
            .imports = &.{
                .{ .name = "builtins", .module = builtins_module },
            },
        }),
    });
    // Force bundle compiler-rt to resolve runtime symbols like __main
    host_lib.bundle_compiler_rt = true;

    b.installArtifact(host_lib);

    // Copy the library to the platform directory for roc to find
    const copy_lib = b.addUpdateSourceFiles();
    const lib_filename = if (target.result.os.tag == .windows) "host.lib" else "libhost.a";
    copy_lib.addCopyFileToSource(host_lib.getEmittedBin(), b.pathJoin(&.{ "platform", lib_filename }));
    b.getInstallStep().dependOn(&copy_lib.step);

    // Test step
    const host_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("platform/host.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "builtins", .module = builtins_module },
            },
        }),
    });

    const run_host_tests = b.addRunArtifact(host_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_host_tests.step);
}
