///! Platform host that tests effectful functions writing to stdout and stderr.
const std = @import("std");
const builtins = @import("builtins");

/// Global flag to track if dbg or expect_failed was called.
/// If set, program exits with non-zero code to prevent accidental commits.
var debug_or_expect_called: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Host environment
const HostEnv = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    stdin_reader: std.fs.File.Reader,
};

/// Roc allocation function with size-tracking metadata
fn rocAllocFn(roc_alloc: *builtins.host_abi.RocAlloc, env: *anyopaque) callconv(.c) void {
    const host: *HostEnv = @ptrCast(@alignCast(env));
    const allocator = host.gpa.allocator();

    const min_alignment: usize = @max(roc_alloc.alignment, @alignOf(usize));
    const align_enum = std.mem.Alignment.fromByteUnits(min_alignment);

    // Calculate additional bytes needed to store the size
    const size_storage_bytes = @max(roc_alloc.alignment, @alignOf(usize));
    const total_size = roc_alloc.length + size_storage_bytes;

    // Allocate memory including space for size metadata
    const result = allocator.rawAlloc(total_size, align_enum, @returnAddress());

    const base_ptr = result orelse {
        const stderr: std.fs.File = .stderr();
        stderr.writeAll("\x1b[31mHost error:\x1b[0m allocation failed, out of memory\n") catch {};
        std.process.exit(1);
    };

    // Store the total size (including metadata) right before the user data
    const size_ptr: *usize = @ptrFromInt(@intFromPtr(base_ptr) + size_storage_bytes - @sizeOf(usize));
    size_ptr.* = total_size;

    // Return pointer to the user data (after the size metadata)
    roc_alloc.answer = @ptrFromInt(@intFromPtr(base_ptr) + size_storage_bytes);

    std.log.debug("[ALLOC] ptr=0x{x} size={d} align={d}", .{ @intFromPtr(roc_alloc.answer), roc_alloc.length, roc_alloc.alignment });
}

/// Roc deallocation function with size-tracking metadata
fn rocDeallocFn(roc_dealloc: *builtins.host_abi.RocDealloc, env: *anyopaque) callconv(.c) void {
    std.log.debug("[DEALLOC] ptr=0x{x} align={d}", .{ @intFromPtr(roc_dealloc.ptr), roc_dealloc.alignment });

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
    const min_alignment: usize = @max(roc_dealloc.alignment, @alignOf(usize));
    const align_enum = std.mem.Alignment.fromByteUnits(min_alignment);

    // Free the memory (including the size metadata)
    const slice = @as([*]u8, @ptrCast(base_ptr))[0..total_size];
    allocator.rawFree(slice, align_enum, @returnAddress());
}

/// Roc reallocation function with size-tracking metadata
fn rocReallocFn(roc_realloc: *builtins.host_abi.RocRealloc, env: *anyopaque) callconv(.c) void {
    const host: *HostEnv = @ptrCast(@alignCast(env));
    const allocator = host.gpa.allocator();

    // Calculate alignment
    const min_alignment: usize = @max(roc_realloc.alignment, @alignOf(usize));
    const align_enum = std.mem.Alignment.fromByteUnits(min_alignment);

    // Calculate where the size metadata is stored for the old allocation
    const size_storage_bytes = min_alignment;
    const old_size_ptr: *const usize = @ptrFromInt(@intFromPtr(roc_realloc.answer) - @sizeOf(usize));

    // Read the old total size from metadata
    const old_total_size = old_size_ptr.*;

    // Calculate the old base pointer (start of actual allocation)
    const old_base_ptr: [*]u8 = @ptrFromInt(@intFromPtr(roc_realloc.answer) - size_storage_bytes);

    // Calculate new total size needed
    const new_total_size = roc_realloc.new_length + size_storage_bytes;

    // Allocate new memory with proper alignment
    const new_base_ptr = allocator.rawAlloc(new_total_size, align_enum, @returnAddress()) orelse {
        const stderr: std.fs.File = .stderr();
        stderr.writeAll("\x1b[31mHost error:\x1b[0m reallocation failed, out of memory\n") catch {};
        std.process.exit(1);
    };

    // Copy old data to new allocation (excluding metadata, just user data)
    const old_user_data_size = old_total_size - size_storage_bytes;
    const copy_size = @min(old_user_data_size, roc_realloc.new_length);
    const new_user_ptr: [*]u8 = @ptrFromInt(@intFromPtr(new_base_ptr) + size_storage_bytes);
    const old_user_ptr: [*]const u8 = @ptrCast(roc_realloc.answer);
    @memcpy(new_user_ptr, old_user_ptr[0..copy_size]);

    // Free old allocation
    const old_slice = old_base_ptr[0..old_total_size];
    allocator.rawFree(old_slice, align_enum, @returnAddress());

    // Store the new total size in the metadata
    const new_size_ptr: *usize = @ptrFromInt(@intFromPtr(new_base_ptr) + size_storage_bytes - @sizeOf(usize));
    new_size_ptr.* = new_total_size;

    // Return pointer to the user data (after the size metadata)
    roc_realloc.answer = new_user_ptr;

    std.log.debug("[REALLOC] old=0x{x} new=0x{x} new_size={d}", .{ @intFromPtr(roc_realloc.answer), @intFromPtr(new_user_ptr), roc_realloc.new_length });
}

/// Roc debug function
fn rocDbgFn(roc_dbg: *const builtins.host_abi.RocDbg, env: *anyopaque) callconv(.c) void {
    _ = env;
    debug_or_expect_called.store(true, .release);
    const message = roc_dbg.utf8_bytes[0..roc_dbg.len];
    const stderr: std.fs.File = .stderr();
    stderr.writeAll("\x1b[33mdbg:\x1b[0m ") catch {};
    stderr.writeAll(message) catch {};
    stderr.writeAll("\n") catch {};
}

/// Roc expect failed function
fn rocExpectFailedFn(roc_expect: *const builtins.host_abi.RocExpectFailed, env: *anyopaque) callconv(.c) void {
    _ = env;
    debug_or_expect_called.store(true, .release);
    const source_bytes = roc_expect.utf8_bytes[0..roc_expect.len];
    const trimmed = std.mem.trim(u8, source_bytes, " \t\n\r");
    const stderr: std.fs.File = .stderr();
    stderr.writeAll("\x1b[33mexpect failed:\x1b[0m ") catch {};
    stderr.writeAll(trimmed) catch {};
    stderr.writeAll("\n") catch {};
}

/// Roc crashed function
fn rocCrashedFn(roc_crashed: *const builtins.host_abi.RocCrashed, env: *anyopaque) callconv(.c) noreturn {
    _ = env;
    const message = roc_crashed.utf8_bytes[0..roc_crashed.len];
    const stderr: std.fs.File = .stderr();
    var buf: [256]u8 = undefined;
    var w = stderr.writer(&buf);
    w.interface.print("\n\x1b[31mRoc crashed:\x1b[0m {s}\n", .{message}) catch {};
    w.interface.flush() catch {};
    std.process.exit(1);
}

// A RocBox is an opaque pointer to a Roc heap-allocated value
const RocBox = *anyopaque;

/// Decrement the reference count of a RocBox
/// If the refcount reaches zero, the memory is freed
fn decrefRocBox(box: RocBox, roc_ops: *builtins.host_abi.RocOps) void {
    const ptr: ?[*]u8 = @ptrCast(box);
    // Box alignment is pointer-width, elements are not refcounted at this level
    builtins.utils.decrefDataPtrC(ptr, @alignOf(usize), false, roc_ops);
}

/// Runtime layout for the roc type `Try(Box(Model), I64)`
const Try_BoxModel_I64 = extern struct {
    /// Box(Model) or I64 (8 bytes)
    payload: extern union { ok: RocBox, err: i64 },
    /// 0 = Err, 1 = Ok (1 byte)
    discriminant: u8,
    /// Padding (not_used) to maintain 8-byte alignment
    _padding: [7]u8,

    pub fn isOk(self: Try_BoxModel_I64) bool {
        return self.discriminant == 1;
    }

    pub fn isErr(self: Try_BoxModel_I64) bool {
        return self.discriminant == 0;
    }

    pub fn getModel(self: Try_BoxModel_I64) RocBox {
        return self.payload.ok;
    }

    pub fn getErrCode(self: Try_BoxModel_I64) i64 {
        return self.payload.err;
    }
};

extern fn roc__init_for_host(ops: *builtins.host_abi.RocOps, ret_ptr: *Try_BoxModel_I64, arg_ptr: ?*anyopaque) callconv(.c) void;
extern fn roc__render_for_host(ops: *builtins.host_abi.RocOps, ret_ptr: *Try_BoxModel_I64, arg_ptr: *RocBox) callconv(.c) void;

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

// Use the actual types from builtins
const RocStr = builtins.str.RocStr;
const RocList = builtins.list.RocList;

/// Array of hosted function pointers, sorted alphabetically by fully-qualified name
/// These correspond to the hosted functions
const hosted_function_ptrs = [_]builtins.host_abi.HostedFn{};

/// Platform host entrypoint
fn platform_main(argc: usize, argv: [*][*:0]u8) c_int {
    var stdin_buffer: [4096]u8 = undefined;

    var host_env = HostEnv{
        .gpa = std.heap.GeneralPurposeAllocator(.{}){},
        .stdin_reader = std.fs.File.stdin().reader(&stdin_buffer),
    };

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

    // TODO: Build List(Str) from argc/argv when platform supports passing args to init
    _ = argc;
    _ = argv;

    // Call the app's init! entrypoint
    std.log.debug("[HOST] Calling roc__init_for_host...", .{});

    var init_result: Try_BoxModel_I64 = undefined;
    var unit: struct {} = .{};
    roc__init_for_host(&roc_ops, &init_result, @ptrCast(&unit));

    std.log.debug("[HOST] init returned, discriminant={d}", .{init_result.discriminant});

    // Check if init failed
    if (init_result.isErr()) {
        const err_code = init_result.getErrCode();
        std.log.debug("[HOST] init returned Err({d})", .{err_code});
        return @intCast(err_code);
    }

    // Get the boxed model from init
    var boxed_model = init_result.getModel();
    std.log.debug("[HOST] init returned Ok, model box=0x{x}", .{@intFromPtr(boxed_model)});

    // Call render with the boxed model
    // Roc's render_for_host! will call Box.unbox which consumes the box
    std.log.debug("[HOST] Calling roc__render_for_host...", .{});

    var render_result: Try_BoxModel_I64 = undefined;
    roc__render_for_host(&roc_ops, &render_result, &boxed_model);
    // Note: Roc's Box.unbox in render_for_host! consumes the init box

    std.log.debug("[HOST] render returned, discriminant={d}", .{render_result.discriminant});

    // Check render result and clean up
    var exit_code: i32 = 0;
    if (render_result.isErr()) {
        exit_code = @intCast(render_result.getErrCode());
        std.log.debug("[HOST] render returned Err({d})", .{exit_code});
    } else {
        std.log.debug("[HOST] render returned Ok", .{});
        // Print success message
        const stdout: std.fs.File = .stdout();
        stdout.writeAll("Roc app completed successfully!\n") catch {};

        // Decref the final boxed model - render consumed the init box,
        // so we only need to decref the render result
        const final_model = render_result.getModel();
        std.log.debug("[HOST] Decrementing refcount for final model box=0x{x}", .{@intFromPtr(final_model)});
        decrefRocBox(final_model, &roc_ops);
    }

    // Check for memory leaks before returning
    const leak_status = host_env.gpa.deinit();
    if (leak_status == .leak) {
        std.log.warn("Memory leak detected", .{});
    }

    // If dbg or expect_failed was called, ensure non-zero exit code
    // to prevent accidental commits with debug statements or failing tests
    if (debug_or_expect_called.load(.acquire) and exit_code == 0) {
        return 1;
    }

    return exit_code;
}

/// Build a RocList of RocStr from argc/argv
fn buildStrArgsList(argc: usize, argv: [*][*:0]u8, roc_ops: *builtins.host_abi.RocOps) RocList {
    if (argc == 0) {
        return RocList.empty();
    }

    // Allocate list with proper refcount header using RocList.allocateExact
    const args_list = RocList.allocateExact(
        @alignOf(RocStr),
        argc,
        @sizeOf(RocStr),
        true, // elements are refcounted (RocStr)
        roc_ops,
    );

    const args_ptr: [*]RocStr = @ptrCast(@alignCast(args_list.bytes));

    // Build each argument string
    for (0..argc) |i| {
        const arg_cstr = argv[i];
        const arg_len = std.mem.len(arg_cstr);

        // RocStr.init takes a const pointer to read FROM and allocates internally
        args_ptr[i] = RocStr.init(arg_cstr, arg_len, roc_ops);
    }

    return args_list;
}
