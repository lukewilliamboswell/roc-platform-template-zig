const std = @import("std");
const builtin = @import("builtin");
const zemscripten = @import("zemscripten");

/// Roc target definitions matching src/cli/target.zig
/// Maps to vendored raylib library directories
const RocTarget = enum {
    // x64 (x86_64) targets
    x64mac,
    x64win,
    x64glibc,

    // arm64 (aarch64) targets
    arm64mac,
    arm64win,
    arm64glibc,

    // wasm32 target (for web/emscripten)
    wasm32,

    fn toZigTarget(self: RocTarget) std.Target.Query {
        return switch (self) {
            .x64mac => .{ .cpu_arch = .x86_64, .os_tag = .macos },
            .x64win => .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
            .x64glibc => .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
            .arm64mac => .{ .cpu_arch = .aarch64, .os_tag = .macos },
            .arm64win => .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu },
            .arm64glibc => .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
            // WASM uses freestanding for Zig compilation (avoids std library issues)
            // emcc is used later for linking and JS runtime generation
            .wasm32 => .{ .cpu_arch = .wasm32, .os_tag = .freestanding },
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
            .wasm32 => "wasm32",
        };
    }

    fn libFilename(self: RocTarget) []const u8 {
        return switch (self) {
            .x64win, .arm64win => "host.lib",
            else => "libhost.a",
        };
    }

    /// Get the vendored raylib library directory for this target
    fn vendoredRaylibDir(self: RocTarget) []const u8 {
        return switch (self) {
            .x64mac, .arm64mac => "macos",
            .x64glibc => "linux-x64",
            .arm64glibc => "linux-arm64",
            .x64win, .arm64win => "windows-x64",
            .wasm32 => "wasm32",
        };
    }
};

/// All cross-compilation targets for `zig build`
/// Note: wasm32 requires emscripten SDK setup, use `zig build wasm` separately
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
        const build_result = buildHostLib(b, target, optimize, builtins_module, roc_target);

        // For Linux targets, ensure X11 stubs are generated first
        if (target.result.os.tag == .linux) {
            build_result.host_lib.step.dependOn(gen_stubs);
        }

        // Copy libhost.a to platform/targets/{target}/
        copy_all.addCopyFileToSource(
            build_result.host_lib.getEmittedBin(),
            b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), roc_target.libFilename() }),
        );

        // Copy vendored libraylib.a to platform/targets/{target}/
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

        // Copy libm.so stub for Linux targets
        if (build_result.libm_stub) |libm_stub| {
            copy_all.addCopyFileToSource(
                libm_stub,
                b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), "libm.so" }),
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

    const native_result = buildHostLib(b, native_target, optimize, builtins_module, native_roc_target);

    // For native Linux, ensure X11 stubs are generated first
    if (native_target.result.os.tag == .linux) {
        native_result.host_lib.step.dependOn(gen_stubs);
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

    // Copy libm.so stub for native Linux
    if (native_result.libm_stub) |libm_stub| {
        copy_native.addCopyFileToSource(
            libm_stub,
            b.pathJoin(&.{ "platform", "targets", native_roc_target.targetDir(), "libm.so" }),
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
    // Add raylib include path for @cImport("raylib.h")
    host_tests.root_module.addIncludePath(b.path("platform/vendor/raylib/include"));

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

    // WASM step: build for WebAssembly/Emscripten
    // This uses zemscripten for emsdk management and emcc for linking
    const wasm_step = b.step("wasm", "Build host library for WebAssembly with JS runtime");

    // First, activate the Emscripten SDK (downloads and sets up emcc)
    const activate_emsdk = zemscripten.activateEmsdkStep(b);

    // Build host library for wasm32-freestanding target
    // (freestanding avoids Zig std library issues with emscripten)
    const wasm_target = b.resolveTargetQuery(RocTarget.wasm32.toZigTarget());
    const wasm_result = buildHostLib(b, wasm_target, optimize, builtins_module, .wasm32);

    // Create emcc command to link libraries and generate JS runtime
    // emcc links: libhost.a (Zig-compiled) + libraylib.a (vendored) -> HTML/JS/WASM
    const emcc = b.addSystemCommand(&.{zemscripten.emccPath(b)});

    // Optimization flags
    switch (optimize) {
        .Debug => {
            emcc.addArgs(&.{ "-O0", "-g" });
        },
        .ReleaseSafe => {
            emcc.addArgs(&.{"-O2"});
        },
        .ReleaseFast => {
            emcc.addArgs(&.{"-O3"});
        },
        .ReleaseSmall => {
            emcc.addArgs(&.{"-Oz"});
        },
    }

    // Raylib-specific emcc settings
    emcc.addArgs(&.{
        "-sUSE_GLFW=3", // GLFW for window/input
        "-sASYNCIFY", // Async main loop support
        "-sALLOW_MEMORY_GROWTH=1", // Dynamic memory
        "-sFULL_ES3=1", // Full OpenGL ES3
        "-sMAX_WEBGL_VERSION=2", // WebGL 2.0
    });

    // Export functions for runtime
    emcc.addArgs(&.{
        "-sEXPORTED_FUNCTIONS=['_main','_malloc','_free','___force_gl_exports']",
        "-sEXPORTED_RUNTIME_METHODS=['UTF8ToString','stringToUTF8','getValue','setValue']",
    });

    // Allow only Roc-specific symbols to be undefined (provided by Roc app at final link)
    // This lets emscripten resolve libc symbols while keeping Roc symbols as imports
    emcc.addArgs(&.{
        "-sERROR_ON_UNDEFINED_SYMBOLS=0",
        "-sWARN_ON_UNDEFINED_SYMBOLS=1",
    });

    // Include paths
    emcc.addArgs(&.{"-Iplatform/vendor/raylib/include"});

    // JavaScript library for console functions
    emcc.addArg("--js-library");
    emcc.addFileArg(b.path("platform/web/library.js"));

    // Input files: libhost.a and libraylib.a
    emcc.addFileArg(wasm_result.host_lib.getEmittedBin());
    emcc.addFileArg(wasm_result.raylib_archive);

    // Output HTML file (also generates .js and .wasm in same directory)
    emcc.addArg("-o");
    const html_output = emcc.addOutputFileArg("host.html");

    // Dependencies
    emcc.step.dependOn(activate_emsdk);
    emcc.step.dependOn(&wasm_result.host_lib.step);

    // Install all generated files to zig-out/web/
    // emcc generates host.html, host.js, and host.wasm
    const install_html = b.addInstallFile(html_output, "web/host.html");
    install_html.step.dependOn(&emcc.step);

    // Install the .wasm file (sibling file in same output directory)
    const output_dir = html_output.dirname();
    const install_wasm = b.addInstallFile(output_dir.path(b, "host.wasm"), "web/host.wasm");
    install_wasm.step.dependOn(&emcc.step);

    // Patch host.js for Roc/Zig WASM compatibility
    // This adds emscripten stubs, dynCall wrappers, GL aliases, and Roc platform functions
    const patch_js = b.addSystemCommand(&.{"node"});
    patch_js.addFileArg(b.path("platform/web/patch-host-js.js"));
    patch_js.addFileArg(output_dir.path(b, "host.js")); // input
    const patched_js = patch_js.addOutputFileArg("host.js"); // output
    patch_js.step.dependOn(&emcc.step);

    // Install the patched JS file
    const install_js = b.addInstallFile(patched_js, "web/host.js");
    install_js.step.dependOn(&patch_js.step);

    // Build wasm libc (provides malloc, string functions, etc. for Roc linking)
    const wasm_libc = b.addLibrary(.{
        .name = "wasm_libc",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("platform/wasm_libc.zig"),
            .target = wasm_target,
            .optimize = optimize,
        }),
    });

    // Copy libraries to platform/targets/wasm32/ for Roc bundling
    const copy_wasm = b.addUpdateSourceFiles();
    copy_wasm.addCopyFileToSource(
        wasm_result.host_lib.getEmittedBin(),
        b.pathJoin(&.{ "platform", "targets", "wasm32", "libhost.a" }),
    );
    copy_wasm.addCopyFileToSource(
        wasm_result.raylib_archive,
        b.pathJoin(&.{ "platform", "targets", "wasm32", "libraylib.a" }),
    );
    copy_wasm.addCopyFileToSource(
        wasm_libc.getEmittedBin(),
        b.pathJoin(&.{ "platform", "targets", "wasm32", "libwasm_libc.a" }),
    );

    // Copy patched JS runtime to platform/web/ for Roc apps
    copy_wasm.addCopyFileToSource(patched_js, "platform/web/runtime.js");
    copy_wasm.step.dependOn(&patch_js.step);

    wasm_step.dependOn(&install_html.step);
    wasm_step.dependOn(&install_js.step);
    wasm_step.dependOn(&install_wasm.step);
    wasm_step.dependOn(&copy_wasm.step);

    // Emrun step: serve locally and open in browser
    const emrun_step = b.step("emrun", "Build WASM and open in browser");
    const emrun = b.addSystemCommand(&.{
        zemscripten.emrunPath(b),
        b.getInstallPath(.prefix, "web/host.html"),
    });
    emrun.step.dependOn(&install_html.step);
    emrun_step.dependOn(&emrun.step);
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
    /// Path to the vendored raylib library for bundling
    raylib_archive: std.Build.LazyPath,
    /// For Linux: libc stub with SONAME libc.so.6
    /// For other platforms: null
    libc_stub: ?std.Build.LazyPath,
    /// For Linux: libm stub with SONAME libm.so.6
    /// For other platforms: null
    libm_stub: ?std.Build.LazyPath,
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

/// Generate libm stub shared library with SONAME libm.so.6.
/// At link time, Roc uses this stub to satisfy math function references.
/// At runtime, the dynamic linker finds the real system libm.so.6.
fn generateLibmStub(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const stub_lib = b.addLibrary(.{
        .name = "m",
        .linkage = .dynamic,
        .version = .{ .major = 6, .minor = 0, .patch = 0 }, // SONAME: libm.so.6
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseSmall,
        }),
    });

    // Select architecture-specific stub file
    const stub_path = switch (target.result.cpu.arch) {
        .x86_64 => "platform/targets/x64glibc/libm_stub.s",
        .aarch64 => "platform/targets/arm64glibc/libm_stub.s",
        else => @panic("Unsupported architecture for libm stub"),
    };
    stub_lib.addAssemblyFile(b.path(stub_path));
    return stub_lib;
}

fn buildHostLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    builtins_module: *std.Build.Module,
    roc_target: RocTarget,
) BuildResult {
    // Use vendored raylib instead of building from source
    // This uses official pre-built raylib libraries for each platform
    const raylib_include_path = b.path("platform/vendor/raylib/include");
    const raylib_lib_dir = b.pathJoin(&.{ "platform", "vendor", "raylib", roc_target.vendoredRaylibDir() });
    const raylib_lib_path = b.path(raylib_lib_dir);

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

    // Add raylib include path for @cImport("raylib.h")
    host_lib.root_module.addIncludePath(raylib_include_path);

    // Add vendored raylib library path
    host_lib.root_module.addLibraryPath(raylib_lib_path);

    // For macOS cross-compilation, add framework paths from our bundled sysroot
    if (target.result.os.tag == .macos) {
        const sysroot_frameworks = b.path("platform/targets/macos-sysroot/System/Library/Frameworks");
        const sysroot_lib = b.path("platform/targets/macos-sysroot/usr/lib");
        host_lib.root_module.addSystemFrameworkPath(sysroot_frameworks);
        host_lib.root_module.addLibraryPath(sysroot_lib);
    }

    // For Linux cross-compilation, use X11 stub libraries and system headers
    if (target.result.os.tag == .linux) {
        const stubs_path = b.path("platform/targets/linux-x11-stubs");
        host_lib.root_module.addLibraryPath(stubs_path);

        // Add system include paths for X11 and GL headers (architecture-independent)
        host_lib.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    }

    // Force bundle compiler-rt to resolve runtime symbols like __main
    // (not needed for WASM targets which use emscripten runtime)
    if (target.result.os.tag != .emscripten and target.result.cpu.arch != .wasm32) {
        host_lib.bundle_compiler_rt = true;
    }

    // For WASM, skip desktop-specific setup (emcc will link raylib later)
    if (target.result.cpu.arch == .wasm32) {
        return .{
            .host_lib = host_lib,
            .raylib_archive = b.path(b.pathJoin(&.{ raylib_lib_dir, "libraylib.a" })),
            .libc_stub = null,
            .libm_stub = null,
        };
    }

    // Get vendored raylib library path
    const raylib_archive = b.path(b.pathJoin(&.{ raylib_lib_dir, "libraylib.a" }));

    // For Linux, generate libc stub with SONAME libc.so.6
    const libc_stub: ?std.Build.LazyPath = if (target.result.os.tag == .linux) blk: {
        const stub = generateLibcStub(b, target);
        break :blk stub.getEmittedBin();
    } else null;

    // For Linux, generate libm stub with SONAME libm.so.6
    const libm_stub: ?std.Build.LazyPath = if (target.result.os.tag == .linux) blk: {
        const stub = generateLibmStub(b, target);
        break :blk stub.getEmittedBin();
    } else null;

    return .{
        .host_lib = host_lib,
        .raylib_archive = raylib_archive,
        .libc_stub = libc_stub,
        .libm_stub = libm_stub,
    };
}
