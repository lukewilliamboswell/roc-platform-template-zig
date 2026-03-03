///! Platform host that implements effectful functions for stdout, stderr, and stdin.
const std = @import("std");
const abi = @import("roc_platform_abi.zig");

/// Host environment
const HostEnv = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    stdin_reader: std.fs.File.Reader,

    pub fn allocator(self: *HostEnv) std.mem.Allocator {
        return self.gpa.allocator();
    }
};

// External symbols provided by the Roc runtime object file
// Follows RocCall ABI: ops, ret_ptr, then argument pointers
extern fn roc__main_for_host(ops: *abi.RocOps, ret_ptr: *anyopaque, arg_ptr: ?*anyopaque) callconv(.c) void;

// OS-specific entry point handling (not exported during tests)
comptime {
    if (!@import("builtin").is_test) {
        // Export main for all platforms
        @export(&main, .{ .name = "main" });

        // Windows MinGW/MSVCRT compatibility: export __main stub
        if (@import("builtin").os.tag == .windows) {
            @export(&__main, .{ .name = "__main" });
        }
    }
}

// Windows MinGW/MSVCRT compatibility stub
// The C runtime on Windows calls __main from main for constructor initialization
fn __main() callconv(.c) void {}

// C compatible main for runtime
fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    return platform_main(@intCast(argc), argv);
}

/// Hosted function: Stderr.line! (index 0 - sorted alphabetically)
fn hostedStderrLine(ops: *abi.RocOps, ret_ptr: *anyopaque, args_ptr: *const abi.StderrLineArgs) callconv(.c) void {
    _ = ops;
    _ = ret_ptr; // Return value is {} which is zero-sized

    const message = args_ptr.arg0.asSlice();
    const stderr: std.fs.File = .stderr();
    stderr.writeAll(message) catch {};
    stderr.writeAll("\n") catch {};
}

/// Hosted function: Stdin.line! (index 1 - sorted alphabetically)
fn hostedStdinLine(ops: *abi.RocOps, ret_ptr: *abi.RocStr, args_ptr: *anyopaque) callconv(.c) void {
    _ = args_ptr; // Argument is {} which is zero-sized

    const host: *HostEnv = @ptrCast(@alignCast(ops.env));
    var reader = &host.stdin_reader.interface;

    var line = while (true) {
        const maybe_line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => break &.{}, // Return empty string on error
            error.StreamTooLong => {
                // Skip the overlong line so the next call starts fresh.
                _ = reader.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                    error.ReadFailed, error.EndOfStream => break &.{},
                };
                continue;
            },
        } orelse break &.{};

        break maybe_line;
    };

    // Trim trailing \r for Windows line endings
    if (line.len > 0 and line[line.len - 1] == '\r') {
        line = line[0 .. line.len - 1];
    }

    if (line.len == 0) {
        ret_ptr.* = abi.RocStr.empty();
        return;
    }

    ret_ptr.* = abi.RocStr.fromSlice(line[0..line.len], ops);
}

/// Hosted function: Stdout.line! (index 2 - sorted alphabetically)
fn hostedStdoutLine(ops: *abi.RocOps, ret_ptr: *anyopaque, args_ptr: *const abi.StdoutLineArgs) callconv(.c) void {
    _ = ops;
    _ = ret_ptr; // Return value is {} which is zero-sized

    const message = args_ptr.arg0.asSlice();
    const stdout: std.fs.File = .stdout();
    stdout.writeAll(message) catch {};
    stdout.writeAll("\n") catch {};
}

/// Platform host entrypoint
fn platform_main(argc: usize, argv: [*][*:0]u8) c_int {
    var stdin_buffer: [4096]u8 = undefined;

    var host_env = HostEnv{
        .gpa = std.heap.GeneralPurposeAllocator(.{}){},
        .stdin_reader = std.fs.File.stdin().reader(&stdin_buffer),
    };

    var roc_ops = abi.makeRocOps(HostEnv, &host_env, abi.hostedFunctions(.{
        .stderr_line = &hostedStderrLine,
        .stdin_line = &hostedStdinLine,
        .stdout_line = &hostedStdoutLine,
    }));
    // Build List(Str) from argc/argv
    std.log.debug("[HOST] Building args...", .{});
    const args_list = buildStrArgsList(argc, argv, &roc_ops);
    std.log.debug("[HOST] args_list ptr=0x{x} len={d}", .{ @intFromPtr(args_list.elements_ptr), args_list.length });

    // Call the app's main! entrypoint - returns I32 exit code
    std.log.debug("[HOST] Calling roc__main_for_host...", .{});

    var exit_code: i32 = -99;
    roc__main_for_host(&roc_ops, @as(*anyopaque, @ptrCast(&exit_code)), @as(*anyopaque, @ptrCast(@constCast(&args_list))));

    std.log.debug("[HOST] Returned from roc, exit_code={d}", .{exit_code});

    // Check for memory leaks before returning
    const leak_status = host_env.gpa.deinit();
    if (leak_status == .leak) {
        std.log.err("\x1b[33mMemory leak detected!\x1b[0m", .{});
        std.process.exit(1);
    }

    return exit_code;
}

/// Build a RocList of RocStr from argc/argv
fn buildStrArgsList(argc: usize, argv: [*][*:0]u8, roc_ops: *abi.RocOps) abi.RocList(abi.RocStr) {
    if (argc == 0) {
        return abi.RocList(abi.RocStr).empty();
    }

    const args_list = abi.RocList(abi.RocStr).allocate(argc, roc_ops);
    const args_ptr: [*]abi.RocStr = args_list.elements_ptr.?;

    // Build each argument string
    for (0..argc) |i| {
        const arg_cstr = argv[i];
        const arg_len = std.mem.len(arg_cstr);
        args_ptr[i] = abi.RocStr.fromSlice(arg_cstr[0..arg_len], roc_ops);
    }

    return args_list;
}
