const std = @import("std");
const builtin = @import("builtin");

/// Roc target definitions matching src/cli/target.zig
const RocTarget = enum {
    // x64 (x86_64) targets
    x64mac,
    x64win,
    x64glibc,

    // arm64 (aarch64) targets
    arm64mac,
    arm64win,
    arm64glibc,

    fn toZigTarget(self: RocTarget) std.Target.Query {
        return switch (self) {
            .x64mac => .{ .cpu_arch = .x86_64, .os_tag = .macos },
            .x64win => .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
            .x64glibc => .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
            .arm64mac => .{ .cpu_arch = .aarch64, .os_tag = .macos },
            .arm64win => .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu },
            .arm64glibc => .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        };
    }

    fn targetDir(self: RocTarget) []const u8 {
        return switch (self) {
            .x64mac => "x64mac",
            .x64win => "x64win",
            .x64glibc => "x64glibc",
            .arm64mac => "arm64mac",
            .arm64win => "arm64win",
            .arm64glibc => "arm64glibc",
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
    .arm64mac,
    .x64glibc,
    .arm64glibc,
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

    // Generate X11 stubs step (needed for Linux cross-compilation)
    const x11_stubs_step = b.step("generate-x11-stubs", "Generate X11 stub libraries for Linux cross-compilation");
    const x11_stub_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu });
    const gen_stubs = generateX11Stubs(b, x11_stub_target);
    x11_stubs_step.dependOn(gen_stubs);

    // Create copy step for all targets
    const copy_all = b.addUpdateSourceFiles();
    all_step.dependOn(&copy_all.step);

    // Build for each Roc target
    for (all_targets) |roc_target| {
        const target = b.resolveTargetQuery(roc_target.toZigTarget());
        const build_result = buildHostLib(b, target, optimize, builtins_module);

        // For Linux targets, ensure X11 stubs are generated first
        if (target.result.os.tag == .linux) {
            build_result.raylib_artifact.step.dependOn(gen_stubs);
        }

        // Copy libhost.a to platform/targets/{target}/
        copy_all.addCopyFileToSource(
            build_result.host_lib.getEmittedBin(),
            b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), roc_target.libFilename() }),
        );

        // Copy libraylib.a to platform/targets/{target}/
        // For Linux, this uses the cleaned archive without .so references
        copy_all.addCopyFileToSource(
            build_result.raylib_archive,
            b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), "libraylib.a" }),
        );

        // Copy libc.so stub for Linux targets
        if (build_result.libc_stub) |libc_stub| {
            copy_all.addCopyFileToSource(
                libc_stub,
                b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), "libc.so" }),
            );
        }
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

    const native_result = buildHostLib(b, native_target, optimize, builtins_module);

    // For native Linux, ensure X11 stubs are generated first
    if (native_target.result.os.tag == .linux) {
        native_result.raylib_artifact.step.dependOn(gen_stubs);
    }

    b.installArtifact(native_result.host_lib);

    const copy_native = b.addUpdateSourceFiles();
    copy_native.addCopyFileToSource(
        native_result.host_lib.getEmittedBin(),
        b.pathJoin(&.{ "platform", "targets", native_roc_target.targetDir(), native_roc_target.libFilename() }),
    );

    // Copy raylib archive (cleaned for Linux)
    copy_native.addCopyFileToSource(
        native_result.raylib_archive,
        b.pathJoin(&.{ "platform", "targets", native_roc_target.targetDir(), "libraylib.a" }),
    );

    // Copy libc.so stub for native Linux
    if (native_result.libc_stub) |libc_stub| {
        copy_native.addCopyFileToSource(
            libc_stub,
            b.pathJoin(&.{ "platform", "targets", native_roc_target.targetDir(), "libc.so" }),
        );
    }

    native_step.dependOn(&copy_native.step);
    native_step.dependOn(&native_result.host_lib.step);

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
            .x86_64 => .x64glibc,
            .aarch64 => .arm64glibc,
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

const BuildResult = struct {
    host_lib: *std.Build.Step.Compile,
    raylib_artifact: *std.Build.Step.Compile,
    /// For Linux: cleaned raylib archive without .so references
    /// For other platforms: same as raylib_artifact.getEmittedBin()
    raylib_archive: std.Build.LazyPath,
    /// For Linux: libc stub with SONAME libc.so.6
    /// For other platforms: null
    libc_stub: ?std.Build.LazyPath,
};

/// Custom step to clean a thin archive by removing .so file references.
/// On Linux, raylib's thin archive contains paths to system .so files which break
/// Roc's linker. This step creates a clean archive with only the .o files.
const CleanArchiveStep = struct {
    step: std.Build.Step,
    input_archive: std.Build.LazyPath,
    output: std.Build.GeneratedFile,
    /// Unique name suffix to avoid conflicts when building multiple architectures
    name_suffix: []const u8,

    fn create(b: *std.Build, input_archive: std.Build.LazyPath, name_suffix: []const u8) *CleanArchiveStep {
        const self = b.allocator.create(CleanArchiveStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "clean-archive",
                .owner = b,
                .makeFn = make,
            }),
            .input_archive = input_archive,
            .output = .{ .step = &self.step },
            .name_suffix = name_suffix,
        };
        input_archive.addStepDependencies(&self.step);
        return self;
    }

    fn getOutput(self: *CleanArchiveStep) std.Build.LazyPath {
        return .{ .generated = .{ .file = &self.output } };
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const b = step.owner;
        const self: *CleanArchiveStep = @fieldParentPtr("step", step);

        const input_path = self.input_archive.getPath2(b, step);

        // Read the thin archive to get member list
        const ar_result = std.process.Child.run(.{
            .allocator = b.allocator,
            .argv = &.{ "ar", "-t", input_path },
        }) catch |err| {
            std.debug.print("Failed to run ar -t: {}\n", .{err});
            return err;
        };

        if (ar_result.term.Exited != 0) {
            std.debug.print("ar -t failed with code {}\n", .{ar_result.term.Exited});
            return error.ArFailed;
        }

        // Filter to only .o files (skip .so files)
        var o_files = std.ArrayListUnmanaged([]const u8){};
        var lines = std.mem.splitScalar(u8, ar_result.stdout, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.endsWith(u8, line, ".o")) {
                o_files.append(b.allocator, b.allocator.dupe(u8, line) catch @panic("OOM")) catch @panic("OOM");
            }
        }

        // Create output directory
        const cache_dir = b.cache_root.path orelse ".";
        const output_dir = std.fs.path.join(b.allocator, &.{ cache_dir, "clean-archives" }) catch @panic("OOM");
        std.fs.cwd().makePath(output_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Use unique filename per architecture to avoid conflicts
        const output_filename = std.fmt.allocPrint(b.allocator, "libraylib-clean-{s}.a", .{self.name_suffix}) catch @panic("OOM");
        const output_path = std.fs.path.join(b.allocator, &.{ output_dir, output_filename }) catch @panic("OOM");

        // Create a temp directory and extract .o files there (unique per arch)
        const tmp_dirname = std.fmt.allocPrint(b.allocator, "ar-extract-tmp-{s}", .{self.name_suffix}) catch @panic("OOM");
        const tmp_dir = std.fs.path.join(b.allocator, &.{ cache_dir, tmp_dirname }) catch @panic("OOM");

        // Clean up and recreate tmp dir
        std.fs.cwd().deleteTree(tmp_dir) catch {};
        std.fs.cwd().makePath(tmp_dir) catch |err| return err;
        defer std.fs.cwd().deleteTree(tmp_dir) catch {};

        // Extract .o files from original archive
        for (o_files.items) |o_file| {
            // For thin archives, the path might be absolute or relative to .zig-cache
            // We need to copy the actual .o file
            const o_basename = std.fs.path.basename(o_file);
            const dest_path = std.fs.path.join(b.allocator, &.{ tmp_dir, o_basename }) catch @panic("OOM");

            // Try to copy from the path in the archive (which might be relative or absolute)
            std.fs.cwd().copyFile(o_file, std.fs.cwd(), dest_path, .{}) catch |err| {
                // If the path is relative to build root, try that
                const from_build_root = std.fs.path.join(b.allocator, &.{ b.build_root.path orelse ".", o_file }) catch @panic("OOM");
                std.fs.cwd().copyFile(from_build_root, std.fs.cwd(), dest_path, .{}) catch {
                    std.debug.print("Warning: Could not copy {s}: {}\n", .{ o_file, err });
                    continue;
                };
            };
        }

        // Create new archive from extracted .o files
        // First, delete old output if exists
        std.fs.cwd().deleteFile(output_path) catch {};

        // Build ar command
        var ar_args = std.ArrayListUnmanaged([]const u8){};
        ar_args.append(b.allocator, "ar") catch @panic("OOM");
        ar_args.append(b.allocator, "rcs") catch @panic("OOM");
        ar_args.append(b.allocator, output_path) catch @panic("OOM");

        // Add all .o files from tmp dir
        var dir = std.fs.cwd().openDir(tmp_dir, .{ .iterate = true }) catch |err| return err;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch |err| return err) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".o")) {
                const full_path = std.fs.path.join(b.allocator, &.{ tmp_dir, entry.name }) catch @panic("OOM");
                ar_args.append(b.allocator, full_path) catch @panic("OOM");
            }
        }

        const create_result = std.process.Child.run(.{
            .allocator = b.allocator,
            .argv = ar_args.items,
        }) catch |err| {
            std.debug.print("Failed to create archive: {}\n", .{err});
            return err;
        };

        if (create_result.term.Exited != 0) {
            std.debug.print("ar rcs failed: {s}\n", .{create_result.stderr});
            return error.ArCreateFailed;
        }

        self.output.path = output_path;
    }
};

/// X11 libraries that raylib depends on (need stubs for cross-compilation)
const x11_libs = [_][]const u8{
    "GLX",
    "X11",
    "Xcursor",
    "Xext",
    "Xfixes",
    "Xi",
    "Xinerama",
    "Xrandr",
    "Xrender",
};

/// Generate X11 stub libraries for Linux cross-compilation.
/// These stubs satisfy the linker at build time; real X11 libs are used at runtime.
fn generateX11Stubs(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    const copy_stubs = b.addUpdateSourceFiles();

    for (x11_libs) |lib_name| {
        // Create a minimal stub with a weak symbol to avoid duplicates
        // (raylib links X11 twice, so we need to allow duplicates)
        const stub_content = std.fmt.allocPrint(b.allocator,
            \\__attribute__((weak)) void __stub_{s}(void) {{}}
            \\
        , .{lib_name}) catch @panic("OOM");

        // Write stub source file with unique name
        const write_files = b.addWriteFiles();
        const stub_filename = std.fmt.allocPrint(b.allocator, "stub_{s}.c", .{lib_name}) catch @panic("OOM");
        const stub_file = write_files.add(stub_filename, stub_content);

        // Compile stub to static library
        const stub_lib = b.addLibrary(.{
            .name = lib_name,
            .linkage = .static,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = .ReleaseSmall,
            }),
        });
        stub_lib.addCSourceFile(.{ .file = stub_file });

        // Copy to platform/targets/linux-x11-stubs/
        copy_stubs.addCopyFileToSource(
            stub_lib.getEmittedBin(),
            std.fmt.allocPrint(b.allocator, "platform/targets/linux-x11-stubs/lib{s}.a", .{lib_name}) catch @panic("OOM"),
        );
    }

    return &copy_stubs.step;
}

/// Generate libc stub shared library with SONAME libc.so.6.
/// At link time, Roc uses this stub to satisfy libc symbol references.
/// At runtime, the dynamic linker finds the real system libc.so.6.
fn generateLibcStub(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const stub_lib = b.addLibrary(.{
        .name = "c",
        .linkage = .dynamic,
        .version = .{ .major = 6, .minor = 0, .patch = 0 }, // SONAME: libc.so.6
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseSmall,
        }),
    });

    // Select architecture-specific stub file
    const stub_path = switch (target.result.cpu.arch) {
        .x86_64 => "platform/targets/x64glibc/libc_stub.s",
        .aarch64 => "platform/targets/arm64glibc/libc_stub.s",
        else => @panic("Unsupported architecture for libc stub"),
    };
    stub_lib.addAssemblyFile(b.path(stub_path));
    return stub_lib;
}

fn buildHostLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    builtins_module: *std.Build.Module,
) BuildResult {
    // Get raylib dependency for this target
    // Always use ReleaseFast for raylib to avoid sanitizer symbols (ubsan, etc.)
    // that would require linking against sanitizer runtime libraries
    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    const raylib_module = raylib_dep.module("raylib");
    const raylib_artifact = raylib_dep.artifact("raylib");

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
                .{ .name = "raylib", .module = raylib_module },
            },
        }),
    });

    // For macOS cross-compilation, add framework paths from our bundled sysroot
    if (target.result.os.tag == .macos) {
        const sysroot_frameworks = b.path("platform/targets/macos-sysroot/System/Library/Frameworks");
        const sysroot_lib = b.path("platform/targets/macos-sysroot/usr/lib");
        host_lib.root_module.addSystemFrameworkPath(sysroot_frameworks);
        host_lib.root_module.addLibraryPath(sysroot_lib);
        // Also add to raylib artifact
        raylib_artifact.root_module.addSystemFrameworkPath(sysroot_frameworks);
        raylib_artifact.root_module.addLibraryPath(sysroot_lib);
    }

    // For Linux cross-compilation, use X11 stub libraries and system headers
    if (target.result.os.tag == .linux) {
        const stubs_path = b.path("platform/targets/linux-x11-stubs");
        raylib_artifact.root_module.addLibraryPath(stubs_path);
        host_lib.root_module.addLibraryPath(stubs_path);

        // Add system include paths for X11 and GL headers (architecture-independent)
        raylib_artifact.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    }

    // Link raylib into the host library
    host_lib.linkLibrary(raylib_artifact);

    // Force bundle compiler-rt to resolve runtime symbols like __main
    host_lib.bundle_compiler_rt = true;

    // For Linux, create a clean archive without .so file references
    // The thin archive from raylib-zig contains system .so paths that break Roc's linker
    const raylib_archive: std.Build.LazyPath = if (target.result.os.tag == .linux) blk: {
        const arch_name = @tagName(target.result.cpu.arch);
        const clean_step = CleanArchiveStep.create(b, raylib_artifact.getEmittedBin(), arch_name);
        break :blk clean_step.getOutput();
    } else raylib_artifact.getEmittedBin();

    // For Linux, generate libc stub with SONAME libc.so.6
    const libc_stub: ?std.Build.LazyPath = if (target.result.os.tag == .linux) blk: {
        const stub = generateLibcStub(b, target);
        break :blk stub.getEmittedBin();
    } else null;

    return .{
        .host_lib = host_lib,
        .raylib_artifact = raylib_artifact,
        .raylib_archive = raylib_archive,
        .libc_stub = libc_stub,
    };
}
