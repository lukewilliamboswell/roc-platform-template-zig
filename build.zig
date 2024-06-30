const std = @import("std");

// TODO RESTORE CROSS COMPILATION
// const TARGETS = [_]std.zig.CrossTarget{
//     .{ .cpu_arch = .aarch64, .os_tag = .linux },
//     .{ .cpu_arch = .aarch64, .os_tag = .macos },
//     .{ .cpu_arch = .aarch64, .os_tag = .windows },
//     .{ .cpu_arch = .x86_64, .os_tag = .linux },
//     .{ .cpu_arch = .x86_64, .os_tag = .macos },
//     .{ .cpu_arch = .x86_64, .os_tag = .windows },
// };

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "dynhost",
        .root_source_file = b.path("host/main.zig"),
        .target = b.host,
        .optimize = optimize,
        .link_libc = true,
    });

    exe.addLibraryPath(b.path("."));
    exe.linkSystemLibrary("app");

    b.installArtifact(exe);

    // TODO RESTORE CROSS COMPILATION
    // for (TARGETS) |target| {
    // const name = try std.fmt.allocPrint(b.allocator, "{s}-{s}", .{
    //     @tagName(target.os_tag.?),
    //     @tagName(target.cpu_arch.?),
    // });

    const lib = b.addStaticLibrary(.{
        .name = "host",
        .root_source_file = b.path("host/main.zig"),
        .target = b.host,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });

    b.installArtifact(lib);
}
