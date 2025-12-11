const std = @import("std");
const builtin = @import("builtin");

/// Roc target definitions matching src/cli/target.zig
const RocTarget = enum {
    // x64 (x86_64) targets
    x64mac,
    x64win,
    x64musl,

    // arm64 (aarch64) targets
    arm64mac,
    arm64win,
    arm64musl,

    fn toZigTarget(self: RocTarget) std.Target.Query {
        return switch (self) {
            .x64mac => .{ .cpu_arch = .x86_64, .os_tag = .macos },
            .x64win => .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
            .x64musl => .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
            .arm64mac => .{ .cpu_arch = .aarch64, .os_tag = .macos },
            .arm64win => .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu },
            .arm64musl => .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        };
    }

    fn targetDir(self: RocTarget) []const u8 {
        return switch (self) {
            .x64mac => "x64mac",
            .x64win => "x64win",
            .x64musl => "x64musl",
            .arm64mac => "arm64mac",
            .arm64win => "arm64win",
            .arm64musl => "arm64musl",
        };
    }

    fn libFilename(self: RocTarget) []const u8 {
        return switch (self) {
            .x64win, .arm64win => "host.lib",
            else => "libhost.a",
        };
    }
};

/// All cross-compilation targets for `zig build`
const all_targets = [_]RocTarget{
    .x64mac,
    .x64win,
    .x64musl,
    .arm64mac,
    .arm64win,
    .arm64musl,
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Get the roc dependency and its builtins module
    const roc_dep = b.dependency("roc", .{});
    const builtins_module = roc_dep.module("builtins");

    // Cleanup step: remove only generated host library files (preserve libc.a, crt1.o, etc.)
    const cleanup_step = b.step("clean", "Remove all built library files");
    for (all_targets) |roc_target| {
        cleanup_step.dependOn(&CleanupStep.create(b, b.path(
            b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), roc_target.libFilename() }),
        )).step);
    }
    cleanup_step.dependOn(&CleanupStep.create(b, b.path("platform/libhost.a")).step);
    cleanup_step.dependOn(&CleanupStep.create(b, b.path("platform/host.lib")).step);

    // Default step: build for all targets (with cleanup first)
    const all_step = b.getInstallStep();
    all_step.dependOn(cleanup_step);

    // Create copy step for all targets
    const copy_all = b.addUpdateSourceFiles();
    all_step.dependOn(&copy_all.step);

    // Build for each Roc target
    for (all_targets) |roc_target| {
        const target = b.resolveTargetQuery(roc_target.toZigTarget());
        const host_lib = buildHostLib(b, target, optimize, builtins_module);

        // Copy to platform/targets/{target}/libhost.a (or host.lib for Windows)
        copy_all.addCopyFileToSource(
            host_lib.getEmittedBin(),
            b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), roc_target.libFilename() }),
        );
    }

    // Native step: build only for the current platform (with full cleanup first)
    const native_step = b.step("native", "Build host library for native platform only");
    native_step.dependOn(cleanup_step);

    const native_target = b.standardTargetOptions(.{});

    // Detect native RocTarget and copy to proper targets folder
    const native_roc_target = detectNativeRocTarget(native_target.result) orelse {
        std.debug.print("Unsupported native platform\n", .{});
        return;
    };

    const native_lib = buildHostLib(b, native_target, optimize, builtins_module);
    b.installArtifact(native_lib);

    const copy_native = b.addUpdateSourceFiles();
    copy_native.addCopyFileToSource(
        native_lib.getEmittedBin(),
        b.pathJoin(&.{ "platform", "targets", native_roc_target.targetDir(), native_roc_target.libFilename() }),
    );
    native_step.dependOn(&copy_native.step);
    native_step.dependOn(&native_lib.step);

    // Test step: run unit tests and integration tests
    const test_step = b.step("test", "Run all tests (unit tests and integration tests)");

    // Unit tests for platform code
    const host_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("platform/host.zig"),
            .target = native_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "builtins", .module = builtins_module },
            },
        }),
    });

    const run_host_tests = b.addRunArtifact(host_tests);

    // Integration test runner
    const test_runner = b.addExecutable(.{
        .name = "test_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ci/test_runner.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });

    const run_integration = b.addRunArtifact(test_runner);
    // Integration tests need the native platform library to be built first
    run_integration.step.dependOn(&copy_native.step);
    // Run integration after unit tests
    run_integration.step.dependOn(&run_host_tests.step);
    // Pass through args (e.g. --verbose)
    if (b.args) |args| {
        run_integration.addArgs(args);
    }

    test_step.dependOn(&run_integration.step);
}

/// Detect which RocTarget matches the native platform
fn detectNativeRocTarget(target: std.Target) ?RocTarget {
    return switch (target.os.tag) {
        .macos => switch (target.cpu.arch) {
            .x86_64 => .x64mac,
            .aarch64 => .arm64mac,
            else => null,
        },
        .linux => switch (target.cpu.arch) {
            .x86_64 => .x64musl,
            .aarch64 => .arm64musl,
            else => null,
        },
        .windows => switch (target.cpu.arch) {
            .x86_64 => .x64win,
            .aarch64 => .arm64win,
            else => null,
        },
        else => null,
    };
}

/// Custom step to remove a single file if it exists
const CleanupStep = struct {
    step: std.Build.Step,
    path: std.Build.LazyPath,

    fn create(b: *std.Build, path: std.Build.LazyPath) *CleanupStep {
        const self = b.allocator.create(CleanupStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "cleanup",
                .owner = b,
                .makeFn = make,
            }),
            .path = path,
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const self: *CleanupStep = @fieldParentPtr("step", step);
        const path = self.path.getPath2(step.owner, null);
        std.fs.cwd().deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => {}, // Already gone, that's fine
            else => return err,
        };
    }
};

fn buildHostLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    builtins_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const host_lib = b.addLibrary(.{
        .name = "host",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("platform/host.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .pic = true,
            .imports = &.{
                .{ .name = "builtins", .module = builtins_module },
            },
        }),
    });
    // Force bundle compiler-rt to resolve runtime symbols like __main
    host_lib.bundle_compiler_rt = true;

    return host_lib;
}
