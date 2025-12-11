const std = @import("std");

const Allocator = std.mem.Allocator;

var verbose: bool = false;

const SERVER_PORT = 8089;

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

    // Find the bundle file
    const bundle_filename = findBundleFile(allocator) catch |err| {
        switch (err) {
            error.BundleNotFound => {
                try stderr.interface.print("Failed to find bundle .tar.zst file\n", .{});
                try stderr.interface.print("Make sure to run ./bundle.sh first\n", .{});
            },
            error.MultipleBundlesFound => {
                try stderr.interface.print("Multiple .tar.zst bundle files found\n", .{});
                try stderr.interface.print("Please remove old bundles and keep only the current one\n", .{});
                try stderr.interface.print("You can clean up with: rm *.tar.zst && ./bundle.sh\n", .{});
            },
            else => {
                try stderr.interface.print("Failed to find bundle: {}\n", .{err});
            },
        }
        try stderr.interface.flush();
        std.process.exit(1);
    };
    defer allocator.free(bundle_filename);

    const bundle_url = try std.fmt.allocPrint(allocator, "http://localhost:{d}/{s}", .{ SERVER_PORT, bundle_filename });
    defer allocator.free(bundle_url);

    if (verbose) {
        try stdout.interface.print("Running integration tests:\n\n{s}\n", .{roc_version});
        try stdout.interface.print("Bundle: {s}\n", .{bundle_filename});
        try stdout.interface.print("URL: {s}\n\n", .{bundle_url});
        try stdout.interface.flush();
    }

    // Start HTTP server in background thread
    var server_ctx = ServerContext{
        .allocator = allocator,
        .bundle_filename = bundle_filename,
    };
    const server_thread = try std.Thread.spawn(.{}, runHttpServer, .{&server_ctx});
    defer {
        server_ctx.should_stop.store(true, .release);
        server_thread.join();
    }

    // Give server time to start
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Create temp directory for modified example files
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Get the temp directory path
    const temp_path = tmp_dir.dir.realpathAlloc(allocator, ".") catch |err| {
        try stderr.interface.print("Failed to get temp path: {}\n", .{err});
        try stderr.interface.flush();
        std.process.exit(1);
    };
    defer allocator.free(temp_path);

    // Copy and modify example files to use bundle URL
    prepareTestFiles(allocator, temp_path, bundle_url) catch |err| {
        try stderr.interface.print("Failed to prepare test files: {}\n", .{err});
        try stderr.interface.flush();
        std.process.exit(1);
    };

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
        // Build the temp file path for this test
        const example_basename = tc.getExample();
        const temp_example = try std.fs.path.join(allocator, &.{ temp_path, std.fs.path.basename(example_basename) });
        defer allocator.free(temp_example);

        const result = runTestRuntime(allocator, tc, temp_example);
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
    try stdout.interface.print("bundle {s}\n", .{bundle_filename});
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

    fn getExample(self: TestCase) []const u8 {
        return switch (self.kind) {
            .check => |e| e,
            .run => |e| e,
            .run_with_stdin => |cfg| cfg.example,
            .roc_test => |e| e,
            .build_run => |e| e,
            .build_run_exit => |cfg| cfg.example,
            .build_run_stdin => |cfg| cfg.example,
            .dbg_test_run => |e| e,
            .dbg_test_build => |e| e,
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
    .{ .name = "check hello.roc", .kind = .{ .check = "examples/hello.roc" } },
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

    // roc run examples (interpreter mode)
    .{ .name = "run hello.roc", .kind = .{ .run = "examples/hello.roc" } },
    .{ .name = "run hello_world.roc", .kind = .{ .run = "examples/hello_world.roc" } },
    .{ .name = "run fizzbuzz.roc", .kind = .{ .run = "examples/fizzbuzz.roc" } },
    .{ .name = "run match.roc", .kind = .{ .run = "examples/match.roc" } },
    .{ .name = "run stderr.roc", .kind = .{ .run = "examples/stderr.roc" } },
    .{ .name = "run sum_fold.roc", .kind = .{ .run = "examples/sum_fold.roc" } },
    .{ .name = "run echo.roc", .kind = .{ .run_with_stdin = .{ .example = "examples/echo.roc", .stdin = "yoo\n" } } },
    .{ .name = "run echo_multiline.roc", .kind = .{ .run_with_stdin = .{ .example = "examples/echo_multiline.roc", .stdin = "line one\nline two\nline three\n" } } },
    .{ .name = "run dbg_test.roc", .kind = .{ .dbg_test_run = "examples/dbg_test.roc" } },

    // roc test
    .{ .name = "roc test tests.roc", .kind = .{ .roc_test = "examples/tests.roc" } },

    // Build and run examples
    .{ .name = "build+run hello.roc", .kind = .{ .build_run = "examples/hello.roc" } },
    .{ .name = "build+run hello_world.roc", .kind = .{ .build_run = "examples/hello_world.roc" } },
    .{ .name = "build+run fizzbuzz.roc", .kind = .{ .build_run = "examples/fizzbuzz.roc" } },
    .{ .name = "build+run match.roc", .kind = .{ .build_run = "examples/match.roc" } },
    .{ .name = "build+run sum_fold.roc", .kind = .{ .build_run = "examples/sum_fold.roc" } },
    .{ .name = "build+run stderr.roc", .kind = .{ .build_run = "examples/stderr.roc" } },
    .{ .name = "build+run exit.roc (expect 23)", .kind = .{ .build_run_exit = .{ .example = "examples/exit.roc", .expected_exit = 23 } } },
    .{ .name = "build+run echo.roc", .kind = .{ .build_run_stdin = .{ .example = "examples/echo.roc", .stdin = "test input\n" } } },
    .{ .name = "build+run dbg_test.roc", .kind = .{ .dbg_test_build = "examples/dbg_test.roc" } },
};

/// Runtime version that catches errors and returns them in the result
fn runTestRuntime(allocator: Allocator, tc: TestCase, example_path: []const u8) TestResult {
    return runTest(allocator, tc, example_path) catch |err| {
        return .{ .success = false, .err = err };
    };
}

fn runTest(allocator: Allocator, tc: TestCase, example_path: []const u8) !TestResult {
    return switch (tc.kind) {
        .check => try runRocCheck(allocator, example_path),
        .run => try runRocRun(allocator, example_path, null),
        .run_with_stdin => |cfg| try runRocRun(allocator, example_path, cfg.stdin),
        .roc_test => try runRocTest(allocator, example_path),
        .build_run => try runBuildAndRun(allocator, example_path, null, null),
        .build_run_exit => |cfg| try runBuildAndRun(allocator, example_path, null, cfg.expected_exit),
        .build_run_stdin => |cfg| try runBuildAndRun(allocator, example_path, cfg.stdin, null),
        .dbg_test_run => try runDbgTestRun(allocator, example_path),
        .dbg_test_build => try runDbgTestBuild(allocator, example_path),
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
    // On error, allocate an empty slice so callers can safely free it
    const stdout_data: []u8 = if (child.stdout) |*pipe|
        pipe.readToEndAlloc(allocator, 10 * 1024 * 1024) catch try allocator.alloc(u8, 0)
    else
        try allocator.alloc(u8, 0);
    errdefer allocator.free(stdout_data);

    // Read stderr using readToEndAlloc
    // On error, allocate an empty slice so callers can safely free it
    const stderr_data: []u8 = if (child.stderr) |*pipe|
        pipe.readToEndAlloc(allocator, 10 * 1024 * 1024) catch try allocator.alloc(u8, 0)
    else
        try allocator.alloc(u8, 0);
    errdefer allocator.free(stderr_data);

    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |code| code,
        else => 255,
    };

    return .{
        .exit_code = exit_code,
        .stdout = stdout_data,
        .stderr = stderr_data,
    };
}

// HTTP Server for serving the bundle file
const ServerContext = struct {
    allocator: Allocator,
    bundle_filename: []const u8,
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn runHttpServer(ctx: *ServerContext) void {
    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, SERVER_PORT);
    var server = address.listen(.{ .reuse_address = true }) catch |err| {
        std.debug.print("HTTP server failed to listen: {}\n", .{err});
        return;
    };
    defer server.deinit();

    // Set up poll to wait for connections with timeout
    var poll_fds = [_]std.posix.pollfd{
        .{
            .fd = server.stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };

    const poll_timeout_ms = 100; // Check should_stop every 100ms

    while (!ctx.should_stop.load(.acquire)) {
        // Poll with timeout - allows periodic should_stop checks
        const poll_result = std.posix.poll(&poll_fds, poll_timeout_ms) catch |err| {
            std.debug.print("HTTP server poll error: {}\n", .{err});
            continue;
        };

        // Timeout expired - no connections, loop back to check should_stop
        if (poll_result == 0) {
            continue;
        }

        // Connection ready - accept it
        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            const conn = server.accept() catch |err| {
                std.debug.print("HTTP server accept error: {}\n", .{err});
                poll_fds[0].revents = 0;
                continue;
            };
            defer conn.stream.close();

            handleHttpRequest(ctx, conn.stream) catch |err| {
                std.debug.print("HTTP request error: {}\n", .{err});
            };
        }

        // Reset revents for next poll iteration
        poll_fds[0].revents = 0;
    }
}

fn handleHttpRequest(ctx: *ServerContext, stream: std.net.Stream) !void {
    var buf: [4096]u8 = undefined;
    const n = try stream.read(&buf);
    if (n == 0) return;

    const request = buf[0..n];

    // Parse the requested path from "GET /path HTTP/1.1"
    if (!std.mem.startsWith(u8, request, "GET /")) return;

    const path_start = 5; // After "GET /"
    const path_end = std.mem.indexOfPos(u8, request, path_start, " ") orelse return;
    const requested_path = request[path_start..path_end];

    // Only serve our bundle file
    if (!std.mem.eql(u8, requested_path, ctx.bundle_filename)) {
        const not_found = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
        _ = try stream.write(not_found);
        return;
    }

    // Open and serve the bundle file
    const file = std.fs.cwd().openFile(ctx.bundle_filename, .{}) catch {
        const not_found = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
        _ = try stream.write(not_found);
        return;
    };
    defer file.close();

    const file_size = try file.getEndPos();

    // Send HTTP response header
    var header_buf: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Type: application/octet-stream\r\n\r\n", .{file_size});
    _ = try stream.write(header);

    // Send file content
    var file_buf: [65536]u8 = undefined;
    while (true) {
        const bytes_read = try file.read(&file_buf);
        if (bytes_read == 0) break;
        _ = try stream.write(file_buf[0..bytes_read]);
    }
}

fn findBundleFile(allocator: Allocator) ![]const u8 {
    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();

    var found_bundle: ?[]const u8 = null;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".tar.zst")) {
            if (found_bundle != null) {
                // Already found one bundle, so we have multiple - error out
                allocator.free(found_bundle.?);
                return error.MultipleBundlesFound;
            }
            found_bundle = try allocator.dupe(u8, entry.name);
        }
    }

    return found_bundle orelse error.BundleNotFound;
}

fn prepareTestFiles(allocator: Allocator, temp_path: []const u8, bundle_url: []const u8) !void {
    var examples_dir = try std.fs.cwd().openDir("examples", .{ .iterate = true });
    defer examples_dir.close();

    var iter = examples_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".roc")) {
            // Read original file
            const src_path = try std.fs.path.join(allocator, &.{ "examples", entry.name });
            defer allocator.free(src_path);

            const content = try std.fs.cwd().readFileAlloc(allocator, src_path, 1024 * 1024);
            defer allocator.free(content);

            // Replace platform path with bundle URL
            const new_platform = try std.fmt.allocPrint(allocator, "\"{s}\"", .{bundle_url});
            defer allocator.free(new_platform);

            const new_content = try std.mem.replaceOwned(u8, allocator, content, "\"../platform/main.roc\"", new_platform);
            defer allocator.free(new_content);

            // Write to temp directory
            const dest_path = try std.fs.path.join(allocator, &.{ temp_path, entry.name });
            defer allocator.free(dest_path);

            const dest_file = try std.fs.createFileAbsolute(dest_path, .{});
            defer dest_file.close();
            try dest_file.writeAll(new_content);
        }
    }
}
