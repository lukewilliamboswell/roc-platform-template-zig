const std = @import("std");

const TARGETS = [_]std.zig.CrossTarget{
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .windows },
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});

    for (TARGETS) |target| {
        const name = try std.fmt.allocPrint(b.allocator, "{s}-{s}", .{
            @tagName(target.os_tag.?),
            @tagName(target.cpu_arch.?),
        });

        const lib = b.addStaticLibrary(.{
            .name = name,
            .root_source_file = .{ .path = "host/main.zig" },
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

        lib.force_pic = true;
        lib.disable_stack_probing = true;

        b.installArtifact(lib);
    }
}
