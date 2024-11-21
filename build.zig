const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const host_target = b.standardTargetOptions(.{});

    // BUILD THE LEGACY PREBUILT HOST e.g. `platform/libhost.a`, `platform/macos-aarch64.a`

    const lib = b.addStaticLibrary(.{
        .name = "host",
        .root_source_file = .{ .path = "host/main.zig" },
        .target = host_target,
        .optimize = optimize,
        .link_libc = true,
    });

    lib.force_pic = true;

    b.installArtifact(lib);

    // BUILD THE SURGICAL PREBUILT HOST e.g. `platform/host.rh`, `platform/linux-x64.rh`

    // We need to build a stub roc app to dynamically link against,
    // so we can build a surgical host
    // const build_roc = b.addExecutable(.{
    //     .name = "build_roc",
    //     .root_source_file = .{ .path = "build_roc.zig" },
    //     .target = .{}, // Empty means native.
    //     .optimize = .Debug,
    // });
    // const run_build_roc = b.addRunArtifact(build_roc);

    // // By setting this to true, we ensure zig always rebuilds the roc app since it can't tell if any transitive dependencies have changed.
    // run_build_roc.stdio = .inherit;
    // run_build_roc.has_side_effects = true;

    // const exe = b.addExecutable(.{
    //     .name = "dynhost",
    //     .root_source_file = .{ .path = "host/main.zig" },
    //     .target = host_target,
    //     .optimize = optimize,
    //     .link_libc = true,
    // });

    // exe.step.dependOn(&run_build_roc.step);
    // exe.addLibraryPath(.{ .path = "platform/" });
    // exe.linkSystemLibrary("app");

    // b.installArtifact(exe);
}
