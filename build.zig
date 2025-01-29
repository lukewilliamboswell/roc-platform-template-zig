const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const host_target = b.standardTargetOptions(.{});

    // BUILD THE LEGACY PREBUILT HOST e.g. `platform/libhost.a`, `platform/macos-aarch64.a`

    const lib = b.addStaticLibrary(.{
        .name = "host",
        .root_source_file = b.path("host/main.zig"),
        .target = host_target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });

    b.installArtifact(lib);

    // BUILD THE SURGICAL PREBUILT HOST e.g. `platform/host.rh`, `platform/linux-x64.rh`

    const exe = b.addExecutable(.{
        .name = "dynhost",
        .root_source_file = b.path("host/main.zig"),
        .target = host_target,
        .optimize = optimize,
        .link_libc = true,
    });

    exe.addLibraryPath(b.path("platform/"));
    exe.linkSystemLibrary("app");

    b.installArtifact(exe);
}
