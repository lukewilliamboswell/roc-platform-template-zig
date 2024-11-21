const std = @import("std");
const builtin = @import("builtin");

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
    const host_target = b.standardTargetOptions(.{
        .default_target = std.zig.CrossTarget{
            .cpu_model = .baseline,
            .os_tag = builtin.os.tag,
        },
    });

    const exe = b.addExecutable(.{
        .name = "dynhost",
        .root_source_file = .{ .path = "host/main.zig" },
        .target = host_target,
        .optimize = optimize,
        .link_libc = true,
    });

    exe.addLibraryPath(.{ .path = "." });
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
        .root_source_file = .{ .path = "host/main.zig" },
        .target = host_target,
        .optimize = optimize,
        .link_libc = true,
    });

    lib.force_pic = true;

    b.installArtifact(lib);
}
