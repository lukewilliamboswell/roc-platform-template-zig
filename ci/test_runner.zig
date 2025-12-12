const std = @import("std");

const Allocator = std.mem.Allocator;

var verbose: bool = false;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout_file: std.fs.File = .stdout();
    const stderr_file: std.fs.File = .stderr();
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writer(&stdout_buf);
    var stderr = stderr_file.writer(&stderr_buf);

    // Parse args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        }
    }

    // Get roc version
    const version_result = runCommand(allocator, &.{ "roc", "version" }, null) catch |err| {
        try stderr.interface.print("Failed to run 'roc version': {}\n", .{err});
        try stderr.interface.flush();
        std.process.exit(1);
    };
    defer allocator.free(version_result.stderr);
    defer allocator.free(version_result.stdout);

    const roc_version = if (version_result.exit_code == 0)
        std.mem.trim(u8, version_result.stdout, " \t\n\r")
    else
        "unknown";

    if (verbose) {
        try stdout.interface.print("Running integration tests:\n\n{s}\n\n", .{roc_version});
        try stdout.interface.flush();
    }

    // Category counters
    var check_passed: usize = 0;
    var check_failed: usize = 0;
    var run_passed: usize = 0;
    var run_failed: usize = 0;
    var build_passed: usize = 0;
    var build_failed: usize = 0;
    var test_passed: usize = 0;
    var test_failed: usize = 0;

    var failed_tests = std.ArrayListUnmanaged(FailedTest){};
    defer failed_tests.deinit(allocator);

    // Run all test cases
    for (test_cases) |tc| {
        const result = runTestRuntime(allocator, tc);
        const category = tc.category();

        if (result.err) |err| {
            if (verbose) {
                try stderr.interface.print("FAIL: {s} (error: {})\n", .{ tc.name, err });
                try stderr.interface.flush();
            }
            try failed_tests.append(allocator, .{ .name = tc.name, .message = "internal error", .category = category });
            incrementFailed(category, &check_failed, &run_failed, &build_failed, &test_failed);
            continue;
        }

        if (result.success) {
            if (verbose) {
                try stdout.interface.print("PASS: {s}\n", .{tc.name});
                try stdout.interface.flush();
            }
            incrementPassed(category, &check_passed, &run_passed, &build_passed, &test_passed);
        } else {
            if (verbose) {
                try stderr.interface.print("FAIL: {s}", .{tc.name});
                if (result.message) |msg| {
                    try stderr.interface.print(" ({s})", .{msg});
                }
                try stderr.interface.print("\n", .{});
                try stderr.interface.flush();
            }
            try failed_tests.append(allocator, .{ .name = tc.name, .message = result.message, .category = category });
            incrementFailed(category, &check_failed, &run_failed, &build_failed, &test_failed);
        }
    }

    // Calculate totals
    const total_passed = check_passed + run_passed + build_passed + test_passed;
    const total_failed = check_failed + run_failed + build_failed + test_failed;
    const total = total_passed + total_failed;

    // Print summary
    if (verbose) {
        try stdout.interface.print("\n", .{});
    }

    try stdout.interface.print("roc {s}\n", .{roc_version});
    try stdout.interface.print("\n", .{});

    // Category breakdown
    try printCategoryResult(&stdout, "check", check_passed, check_failed);
    try printCategoryResult(&stdout, "run (interpreter)", run_passed, run_failed);
    try printCategoryResult(&stdout, "build+run (compiled)", build_passed, build_failed);
    try printCategoryResult(&stdout, "roc test", test_passed, test_failed);

    try stdout.interface.print("\n", .{});
    try stdout.interface.flush();

    // Failed tests detail
    if (failed_tests.items.len > 0) {
        try stdout.interface.print("Failed:\n", .{});
        for (failed_tests.items) |ft| {
            try stdout.interface.print("  {s}", .{ft.name});
            if (ft.message) |msg| {
                try stdout.interface.print(" - {s}", .{msg});
            }
            try stdout.interface.print("\n", .{});
        }
        try stdout.interface.print("\n", .{});
        try stdout.interface.flush();
    }

    // Final result
    if (total_failed > 0) {
        try stdout.interface.print("{d}/{d} tests passed, {d} failed\n", .{ total_passed, total, total_failed });
        try stdout.interface.flush();
        std.process.exit(1);
    } else {
        try stdout.interface.print("All {d} tests passed\n", .{total});
        try stdout.interface.flush();
    }
}

fn printCategoryResult(stdout: anytype, name: []const u8, passed: usize, failed: usize) !void {
    const total = passed + failed;
    if (total == 0) return;

    if (failed == 0) {
        try stdout.interface.print("  {s}: {d}/{d} passed\n", .{ name, passed, total });
    } else {
        try stdout.interface.print("  {s}: {d}/{d} passed, {d} failed\n", .{ name, passed, total, failed });
    }
}

fn incrementPassed(category: TestCategory, check: *usize, run: *usize, build: *usize, roc_test: *usize) void {
    switch (category) {
        .check => check.* += 1,
        .run => run.* += 1,
        .build => build.* += 1,
        .roc_test => roc_test.* += 1,
    }
}

fn incrementFailed(category: TestCategory, check: *usize, run: *usize, build: *usize, roc_test: *usize) void {
    switch (category) {
        .check => check.* += 1,
        .run => run.* += 1,
        .build => build.* += 1,
        .roc_test => roc_test.* += 1,
    }
}

const TestCategory = enum {
    check,
    run,
    build,
    roc_test,
};

const FailedTest = struct {
    name: []const u8,
    message: ?[]const u8,
    category: TestCategory,
};

const TestResult = struct {
    success: bool,
    message: ?[]const u8 = null,
    err: ?anyerror = null,
};

const TestCase = struct {
    name: []const u8,
    kind: TestKind,

    fn category(self: TestCase) TestCategory {
        return switch (self.kind) {
            .check => .check,
            .run, .run_with_stdin, .dbg_test_run => .run,
            .build_run, .build_run_exit, .build_run_stdin, .dbg_test_build => .build,
            .roc_test => .roc_test,
        };
    }
};

const TestKind = union(enum) {
    /// Run `roc check` on an example
    check: []const u8,
    /// Run `roc <example>` and expect success (exit 0)
    run: []const u8,
    /// Run `roc <example>` with stdin and expect success
    run_with_stdin: struct {
        example: []const u8,
        stdin: []const u8,
    },
    /// Run `roc test <example>`
    roc_test: []const u8,
    /// Build and run, expecting specific exit code
    build_run_exit: struct {
        example: []const u8,
        expected_exit: u8,
    },
    /// Build and run with stdin
    build_run_stdin: struct {
        example: []const u8,
        stdin: []const u8,
    },
    /// Build and run, just check it succeeds
    build_run: []const u8,
    /// Test dbg behavior - should output "dbg:" and exit non-zero
    dbg_test_run: []const u8,
    dbg_test_build: []const u8,
};

const test_cases = [_]TestCase{
    // roc check examples
    .{ .name = "check cli_args.roc", .kind = .{ .check = "examples/cli_args.roc" } },
    .{ .name = "check hello_world.roc", .kind = .{ .check = "examples/hello_world.roc" } },
    .{ .name = "check fizzbuzz.roc", .kind = .{ .check = "examples/fizzbuzz.roc" } },
    .{ .name = "check match.roc", .kind = .{ .check = "examples/match.roc" } },
    .{ .name = "check stderr.roc", .kind = .{ .check = "examples/stderr.roc" } },
    .{ .name = "check sum_fold.roc", .kind = .{ .check = "examples/sum_fold.roc" } },
    .{ .name = "check exit.roc", .kind = .{ .check = "examples/exit.roc" } },
    .{ .name = "check echo.roc", .kind = .{ .check = "examples/echo.roc" } },
    .{ .name = "check echo_multiline.roc", .kind = .{ .check = "examples/echo_multiline.roc" } },
    .{ .name = "check tests.roc", .kind = .{ .check = "examples/tests.roc" } },
    .{ .name = "check dbg_test.roc", .kind = .{ .check = "examples/dbg_test.roc" } },
    .{ .name = "check all_roc_syntax.roc", .kind = .{ .check = "examples/all_roc_syntax.roc" } },

    // roc run examples (interpreter mode)
    .{ .name = "run cli_args.roc", .kind = .{ .run = "examples/cli_args.roc" } },
    .{ .name = "run hello_world.roc", .kind = .{ .run = "examples/hello_world.roc" } },
    .{ .name = "run fizzbuzz.roc", .kind = .{ .run = "examples/fizzbuzz.roc" } },
    .{ .name = "run match.roc", .kind = .{ .run = "examples/match.roc" } },
    .{ .name = "run stderr.roc", .kind = .{ .run = "examples/stderr.roc" } },
    .{ .name = "run sum_fold.roc", .kind = .{ .run = "examples/sum_fold.roc" } },
    .{ .name = "run echo.roc", .kind = .{ .run_with_stdin = .{ .example = "examples/echo.roc", .stdin = "yoo\n" } } },
    .{ .name = "run echo_multiline.roc", .kind = .{ .run_with_stdin = .{ .example = "examples/echo_multiline.roc", .stdin = "line one\nline two\nline three\n" } } },
    .{ .name = "run dbg_test.roc", .kind = .{ .dbg_test_run = "examples/dbg_test.roc" } },
    .{ .name = "run all_roc_syntax.roc", .kind = .{ .run = "examples/all_roc_syntax.roc" } },

    // roc test
    .{ .name = "roc test tests.roc", .kind = .{ .roc_test = "examples/tests.roc" } },
    .{ .name = "roc test all_roc_syntax.roc", .kind = .{ .roc_test = "examples/all_roc_syntax.roc" } },

    // Build and run examples
    .{ .name = "build+run cli_args.roc", .kind = .{ .build_run = "examples/cli_args.roc" } },
    .{ .name = "build+run hello_world.roc", .kind = .{ .build_run = "examples/hello_world.roc" } },
    .{ .name = "build+run fizzbuzz.roc", .kind = .{ .build_run = "examples/fizzbuzz.roc" } },
    .{ .name = "build+run match.roc", .kind = .{ .build_run = "examples/match.roc" } },
    .{ .name = "build+run sum_fold.roc", .kind = .{ .build_run = "examples/sum_fold.roc" } },
    .{ .name = "build+run stderr.roc", .kind = .{ .build_run = "examples/stderr.roc" } },
    .{ .name = "build+run exit.roc (expect 23)", .kind = .{ .build_run_exit = .{ .example = "examples/exit.roc", .expected_exit = 23 } } },
    .{ .name = "build+run echo.roc", .kind = .{ .build_run_stdin = .{ .example = "examples/echo.roc", .stdin = "test input\n" } } },
    .{ .name = "build+run dbg_test.roc", .kind = .{ .dbg_test_build = "examples/dbg_test.roc" } },
    .{ .name = "build+run all_roc_syntax.roc", .kind = .{ .build_run = "examples/all_roc_syntax.roc" } },
};

/// Runtime version that catches errors and returns them in the result
fn runTestRuntime(allocator: Allocator, tc: TestCase) TestResult {
    return runTest(allocator, tc) catch |err| {
        return .{ .success = false, .err = err };
    };
}

fn runTest(allocator: Allocator, tc: TestCase) !TestResult {
    return switch (tc.kind) {
        .check => |example| try runRocCheck(allocator, example),
        .run => |example| try runRocRun(allocator, example, null),
        .run_with_stdin => |cfg| try runRocRun(allocator, cfg.example, cfg.stdin),
        .roc_test => |example| try runRocTest(allocator, example),
        .build_run => |example| try runBuildAndRun(allocator, example, null, null),
        .build_run_exit => |cfg| try runBuildAndRun(allocator, cfg.example, null, cfg.expected_exit),
        .build_run_stdin => |cfg| try runBuildAndRun(allocator, cfg.example, cfg.stdin, null),
        .dbg_test_run => |example| try runDbgTestRun(allocator, example),
        .dbg_test_build => |example| try runDbgTestBuild(allocator, example),
    };
}

fn runRocCheck(allocator: Allocator, example: []const u8) !TestResult {
    const result = try runCommand(allocator, &.{ "roc", "check", example, "--no-cache" }, null);
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    if (result.exit_code == 0) {
        return .{ .success = true };
    }
    return .{ .success = false, .message = "roc check failed" };
}

fn runRocRun(allocator: Allocator, example: []const u8, stdin: ?[]const u8) !TestResult {
    const result = try runCommand(allocator, &.{ "roc", example, "--no-cache" }, stdin);
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    if (result.exit_code == 0) {
        return .{ .success = true };
    }
    return .{ .success = false, .message = "roc run failed" };
}

fn runRocTest(allocator: Allocator, example: []const u8) !TestResult {
    const result = try runCommand(allocator, &.{ "roc", "test", example }, null);
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    if (result.exit_code == 0) {
        return .{ .success = true };
    }
    return .{ .success = false, .message = "roc test failed" };
}

fn runBuildAndRun(allocator: Allocator, example: []const u8, stdin: ?[]const u8, expected_exit: ?u8) !TestResult {
    // Use build-output directory
    const exe_name = if (comptime @import("builtin").os.tag == .windows) "test_exe.exe" else "test_exe";
    const full_exe_path = try std.fs.path.join(allocator, &.{ "build-output", exe_name });
    defer allocator.free(full_exe_path);

    // Ensure build-output directory exists
    std.fs.cwd().makeDir("build-output") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Build (use --output=path format)
    const output_arg = try std.fmt.allocPrint(allocator, "--output={s}", .{full_exe_path});
    defer allocator.free(output_arg);

    const build_result = try runCommand(allocator, &.{ "roc", "build", example, output_arg }, null);
    defer allocator.free(build_result.stderr);
    defer allocator.free(build_result.stdout);

    if (build_result.exit_code != 0) {
        return .{ .success = false, .message = "roc build failed" };
    }

    // Run
    const run_result = try runCommand(allocator, &.{full_exe_path}, stdin);
    defer allocator.free(run_result.stderr);
    defer allocator.free(run_result.stdout);

    if (expected_exit) |expected| {
        if (run_result.exit_code == expected) {
            return .{ .success = true };
        }
        return .{ .success = false, .message = "unexpected exit code" };
    } else {
        if (run_result.exit_code == 0) {
            return .{ .success = true };
        }
        return .{ .success = false, .message = "non-zero exit code" };
    }
}

fn runDbgTestRun(allocator: Allocator, example: []const u8) !TestResult {
    const result = try runCommand(allocator, &.{ "roc", example, "--no-cache" }, null);
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    // Should exit non-zero and contain "dbg:" in output
    if (result.exit_code != 0 and std.mem.indexOf(u8, result.stderr, "dbg:") != null) {
        return .{ .success = true };
    }
    return .{ .success = false, .message = "expected non-zero exit and 'dbg:' in stderr" };
}

fn runDbgTestBuild(allocator: Allocator, example: []const u8) !TestResult {
    // Use build-output directory
    const exe_name = if (comptime @import("builtin").os.tag == .windows) "dbg_test_exe.exe" else "dbg_test_exe";
    const full_exe_path = try std.fs.path.join(allocator, &.{ "build-output", exe_name });
    defer allocator.free(full_exe_path);

    // Ensure build-output directory exists
    std.fs.cwd().makeDir("build-output") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Build (use --output=path format)
    const output_arg = try std.fmt.allocPrint(allocator, "--output={s}", .{full_exe_path});
    defer allocator.free(output_arg);

    const build_result = try runCommand(allocator, &.{ "roc", "build", example, output_arg }, null);
    defer allocator.free(build_result.stderr);
    defer allocator.free(build_result.stdout);

    if (build_result.exit_code != 0) {
        return .{ .success = false, .message = "roc build failed" };
    }

    // Run
    const run_result = try runCommand(allocator, &.{full_exe_path}, null);
    defer allocator.free(run_result.stderr);
    defer allocator.free(run_result.stdout);

    // Should exit non-zero and contain "dbg:" in output
    if (run_result.exit_code != 0 and std.mem.indexOf(u8, run_result.stderr, "dbg:") != null) {
        return .{ .success = true };
    }
    return .{ .success = false, .message = "expected non-zero exit and 'dbg:' in stderr" };
}

const CommandResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
};

fn runCommand(allocator: Allocator, argv: []const []const u8, stdin_data: ?[]const u8) !CommandResult {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = if (stdin_data != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Write stdin if provided
    if (stdin_data) |data| {
        if (child.stdin) |*stdin| {
            stdin.writeAll(data) catch {};
            stdin.close();
            child.stdin = null;
        }
    }

    // Read stdout using readToEndAlloc
    const stdout_data = if (child.stdout) |*pipe|
        pipe.readToEndAlloc(allocator, 10 * 1024 * 1024) catch &.{}
    else
        &.{};

    // Read stderr using readToEndAlloc
    const stderr_data = if (child.stderr) |*pipe|
        pipe.readToEndAlloc(allocator, 10 * 1024 * 1024) catch &.{}
    else
        &.{};

    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |code| code,
        else => 255,
    };

    return .{
        .exit_code = exit_code,
        .stdout = @constCast(stdout_data),
        .stderr = @constCast(stderr_data),
    };
}
