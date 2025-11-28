///! Platform host that tests effectful functions writing to stdout and stderr.
const std = @import("std");
const builtins = @import("builtins");

/// Host environment
const HostEnv = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
};

/// Roc allocation function with size-tracking metadata
fn rocAllocFn(roc_alloc: *builtins.host_abi.RocAlloc, env: *anyopaque) callconv(.c) void {
    const host: *HostEnv = @ptrCast(@alignCast(env));
    const allocator = host.gpa.allocator();

    const align_enum = std.mem.Alignment.fromByteUnits(@as(usize, @intCast(roc_alloc.alignment)));

    // Calculate additional bytes needed to store the size
    const size_storage_bytes = @max(roc_alloc.alignment, @alignOf(usize));
    const total_size = roc_alloc.length + size_storage_bytes;

    // Allocate memory including space for size metadata
    const result = allocator.rawAlloc(total_size, align_enum, @returnAddress());

    const base_ptr = result orelse {
        @panic("Host allocation failed");
    };

    // Store the total size (including metadata) right before the user data
    const size_ptr: *usize = @ptrFromInt(@intFromPtr(base_ptr) + size_storage_bytes - @sizeOf(usize));
    size_ptr.* = total_size;

    // Return pointer to the user data (after the size metadata)
    roc_alloc.answer = @ptrFromInt(@intFromPtr(base_ptr) + size_storage_bytes);
}

/// Roc deallocation function with size-tracking metadata
fn rocDeallocFn(roc_dealloc: *builtins.host_abi.RocDealloc, env: *anyopaque) callconv(.c) void {
    const host: *HostEnv = @ptrCast(@alignCast(env));
    const allocator = host.gpa.allocator();

    // Calculate where the size metadata is stored
    const size_storage_bytes = @max(roc_dealloc.alignment, @alignOf(usize));
    const size_ptr: *const usize = @ptrFromInt(@intFromPtr(roc_dealloc.ptr) - @sizeOf(usize));

    // Read the total size from metadata
    const total_size = size_ptr.*;

    // Calculate the base pointer (start of actual allocation)
    const base_ptr: [*]u8 = @ptrFromInt(@intFromPtr(roc_dealloc.ptr) - size_storage_bytes);

    // Calculate alignment
    const log2_align = std.math.log2_int(u32, @intCast(roc_dealloc.alignment));
    const align_enum: std.mem.Alignment = @enumFromInt(log2_align);

    // Free the memory (including the size metadata)
    const slice = @as([*]u8, @ptrCast(base_ptr))[0..total_size];
    allocator.rawFree(slice, align_enum, @returnAddress());
}

/// Roc reallocation function with size-tracking metadata
fn rocReallocFn(roc_realloc: *builtins.host_abi.RocRealloc, env: *anyopaque) callconv(.c) void {
    const host: *HostEnv = @ptrCast(@alignCast(env));
    const allocator = host.gpa.allocator();

    // Calculate where the size metadata is stored for the old allocation
    const size_storage_bytes = @max(roc_realloc.alignment, @alignOf(usize));
    const old_size_ptr: *const usize = @ptrFromInt(@intFromPtr(roc_realloc.answer) - @sizeOf(usize));

    // Read the old total size from metadata
    const old_total_size = old_size_ptr.*;

    // Calculate the old base pointer (start of actual allocation)
    const old_base_ptr: [*]u8 = @ptrFromInt(@intFromPtr(roc_realloc.answer) - size_storage_bytes);

    // Calculate new total size needed
    const new_total_size = roc_realloc.new_length + size_storage_bytes;

    // Perform reallocation
    const old_slice = @as([*]u8, @ptrCast(old_base_ptr))[0..old_total_size];
    const new_slice = allocator.realloc(old_slice, new_total_size) catch {
        @panic("Host reallocation failed");
    };

    // Store the new total size in the metadata
    const new_size_ptr: *usize = @ptrFromInt(@intFromPtr(new_slice.ptr) + size_storage_bytes - @sizeOf(usize));
    new_size_ptr.* = new_total_size;

    // Return pointer to the user data (after the size metadata)
    roc_realloc.answer = @ptrFromInt(@intFromPtr(new_slice.ptr) + size_storage_bytes);
}

/// Roc debug function
fn rocDbgFn(roc_dbg: *const builtins.host_abi.RocDbg, env: *anyopaque) callconv(.c) void {
    _ = env;
    const message = roc_dbg.utf8_bytes[0..roc_dbg.len];
    std.debug.print("ROC DBG: {s}\n", .{message});
}

/// Roc expect failed function
fn rocExpectFailedFn(roc_expect: *const builtins.host_abi.RocExpectFailed, env: *anyopaque) callconv(.c) void {
    _ = env;
    const source_bytes = roc_expect.utf8_bytes[0..roc_expect.len];
    const trimmed = std.mem.trim(u8, source_bytes, " \t\n\r");
    std.debug.print("Expect failed: {s}\n", .{trimmed});
}

/// Roc crashed function
fn rocCrashedFn(roc_crashed: *const builtins.host_abi.RocCrashed, env: *anyopaque) callconv(.c) noreturn {
    _ = env;
    const message = roc_crashed.utf8_bytes[0..roc_crashed.len];
    std.fs.File.stderr().deprecatedWriter().print("\n\x1b[31mRoc crashed:\x1b[0m {s}\n", .{message}) catch {};
    std.process.exit(1);
}

// External symbols provided by the Roc runtime object file
// Follows RocCall ABI: ops, ret_ptr, then argument pointers
extern fn roc__main_for_host(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, arg_ptr: ?*anyopaque) callconv(.c) void;

// OS-specific entry point handling
comptime {
    // Export main for all platforms
    @export(&main, .{ .name = "main" });

    // Windows MinGW/MSVCRT compatibility: export __main stub
    if (@import("builtin").os.tag == .windows) {
        @export(&__main, .{ .name = "__main" });
    }
}

// Windows MinGW/MSVCRT compatibility stub
// The C runtime on Windows calls __main from main for constructor initialization
fn __main() callconv(.c) void {}

// C compatible main for runtime
fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    _ = argc;
    _ = argv;
    platform_main() catch |err| {
        std.fs.File.stderr().deprecatedWriter().print("HOST ERROR: {s}\n", .{@errorName(err)}) catch unreachable;
        return 1;
    };
    return 0;
}

// Use the actual RocStr from builtins instead of defining our own
const RocStr = builtins.str.RocStr;

/// Hosted function: Stderr.line! (index 0 - sorted alphabetically)
/// Follows RocCall ABI: (ops, ret_ptr, args_ptr)
/// Returns {} and takes Str as argument
fn hostedStderrLine(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr; // Return value is {} which is zero-sized

    // Arguments struct for single Str parameter
    const Args = extern struct { str: RocStr };
    const args: *Args = @ptrCast(@alignCast(args_ptr));

    const message = args.str.asSlice();
    std.fs.File.stderr().deprecatedWriter().print("{s}\n", .{message}) catch unreachable;
}

/// Hosted function: Stdin.line! (index 1 - sorted alphabetically)
/// Follows RocCall ABI: (ops, ret_ptr, args_ptr)
/// Returns Str and takes {} as argument
fn hostedStdinLine(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = args_ptr; // Argument is {} which is zero-sized

    // Get allocator from environment
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));
    const allocator = host.gpa.allocator();

    // Read a line from stdin
    var buffer: [4096]u8 = undefined;
    const stdin_file = std.fs.File.stdin();
    const bytes_read = stdin_file.read(&buffer) catch {
        // Return empty string on error
        const result: *RocStr = @ptrCast(@alignCast(ret_ptr));
        result.* = RocStr.empty();
        return;
    };

    // Find newline and trim it
    const line_with_newline = buffer[0..bytes_read];
    const line = if (std.mem.indexOfScalar(u8, line_with_newline, '\n')) |newline_idx|
        line_with_newline[0..newline_idx]
    else
        line_with_newline;

    // Allocate and copy the line
    const line_copy = allocator.dupe(u8, line) catch {
        const result: *RocStr = @ptrCast(@alignCast(ret_ptr));
        result.* = RocStr.empty();
        return;
    };

    // Create RocStr from the read line and return it
    const result: *RocStr = @ptrCast(@alignCast(ret_ptr));
    result.* = RocStr.init(line_copy.ptr, line_copy.len, ops);
}

/// Hosted function: Stdout.line! (index 2 - sorted alphabetically)
/// Follows RocCall ABI: (ops, ret_ptr, args_ptr)
/// Returns {} and takes Str as argument
fn hostedStdoutLine(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr; // Return value is {} which is zero-sized

    // Arguments struct for single Str parameter
    const Args = extern struct { str: RocStr };
    const args: *Args = @ptrCast(@alignCast(args_ptr));

    const message = args.str.asSlice();
    std.fs.File.stdout().deprecatedWriter().print("{s}\n", .{message}) catch unreachable;
}

/// Array of hosted function pointers, sorted alphabetically by fully-qualified name
/// These correspond to the hosted functions defined in Stderr, Stdin, and Stdout Type Modules
const hosted_function_ptrs = [_]builtins.host_abi.HostedFn{
    hostedStderrLine, // Stderr.line! (index 0)
    hostedStdinLine, // Stdin.line! (index 1)
    hostedStdoutLine, // Stdout.line! (index 2)
};

/// Platform host entrypoint
fn platform_main() !void {
    var host_env = HostEnv{
        .gpa = std.heap.GeneralPurposeAllocator(.{}){},
    };
    defer {
        const leaked = host_env.gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Memory leak detected!\n", .{});
        }
    }

    // Create the RocOps struct
    var roc_ops = builtins.host_abi.RocOps{
        .env = @as(*anyopaque, @ptrCast(&host_env)),
        .roc_alloc = rocAllocFn,
        .roc_dealloc = rocDeallocFn,
        .roc_realloc = rocReallocFn,
        .roc_dbg = rocDbgFn,
        .roc_expect_failed = rocExpectFailedFn,
        .roc_crashed = rocCrashedFn,
        .hosted_fns = .{
            .count = hosted_function_ptrs.len,
            .fns = @constCast(&hosted_function_ptrs),
        },
    };

    // Call the app's main! entrypoint
    var ret: [0]u8 = undefined; // Result is {} which is zero-sized
    var args: [0]u8 = undefined;
    // Note: although this is a function with no args and a zero-sized return value,
    // we can't currently pass null pointers for either of these because Roc will
    // currently dereference both of these eagerly even though it won't use either,
    // causing a segfault if you pass null. This should be changed! Dereferencing
    // garbage memory is obviously pointless, and there's no reason we should do it.
    roc__main_for_host(&roc_ops, @as(*anyopaque, @ptrCast(&ret)), @as(*anyopaque, @ptrCast(&args)));
}
