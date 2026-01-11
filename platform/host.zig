///! Platform host for roc-ray - a Roc platform for raylib graphics.
const std = @import("std");
const builtins = @import("builtins");
const rl = @import("raylib");

const TRACE_ALLOCATIONS = false;
const TRACE_HOST = false;

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

    if (TRACE_ALLOCATIONS) {
        std.log.debug("[ALLOC] ptr=0x{x} size={d} align={d}", .{ @intFromPtr(roc_alloc.answer), roc_alloc.length, roc_alloc.alignment });
    }
}

/// Roc deallocation function with size-tracking metadata
fn rocDeallocFn(roc_dealloc: *builtins.host_abi.RocDealloc, env: *anyopaque) callconv(.c) void {
    if (TRACE_ALLOCATIONS) {
        std.log.debug("[DEALLOC] ptr=0x{x} align={d}", .{ @intFromPtr(roc_dealloc.ptr), roc_dealloc.alignment });
    }

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

    if (TRACE_ALLOCATIONS) {
        std.log.debug("[REALLOC] old=0x{x} new=0x{x} new_size={d}", .{ @intFromPtr(roc_realloc.answer), @intFromPtr(new_user_ptr), roc_realloc.new_length });
    }
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

/// Roc PlatformStateFromHost type layout (alignment desc, then alphabetical)
const RocPlatformState = extern struct {
    frame_count: u64, // @0 (align 8)
    mouse_wheel: f32, // @8 (align 4, "wheel" < "x" < "y")
    mouse_x: f32, // @12
    mouse_y: f32, // @16
    mouse_left: bool, // @20 (align 1, "left" < "middle" < "right")
    mouse_middle: bool, // @21
    mouse_right: bool, // @22
};

/// Args tuple for render_for_host! : Box(Model), PlatformStateFromHost => ...
/// Per RocCall ABI, all args are passed as a single pointer to a tuple struct
const RenderArgs = extern struct {
    model: RocBox,
    state: RocPlatformState,
};

extern fn roc__init_for_host(ops: *builtins.host_abi.RocOps, ret_ptr: *Try_BoxModel_I64, arg_ptr: ?*anyopaque) callconv(.c) void;
extern fn roc__render_for_host(ops: *builtins.host_abi.RocOps, ret_ptr: *Try_BoxModel_I64, args_ptr: *RenderArgs) callconv(.c) void;

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

/// Roc Vector2 type layout: { x: F32, y: F32 }
/// Fields ordered by alignment then alphabetically: x, y
const RocVector2 = extern struct {
    x: f32,
    y: f32,
};

/// Roc Rectangle type layout: { x, y, width, height: F32, color: Color }
/// Fields ordered by alignment (4 bytes for F32) then alphabetically, then 1-byte fields
const RocRectangle = extern struct {
    height: f32,
    width: f32,
    x: f32,
    y: f32,
    color: u8,
};

/// Roc Circle type layout: { center: Vector2, radius: F32, color: Color }
/// Fields ordered by alignment then alphabetically: center, radius, color
const RocCircle = extern struct {
    center: RocVector2,
    radius: f32,
    color: u8,
};

/// Roc Line type layout: { start: Vector2, end: Vector2, color: Color }
/// Fields ordered by alignment then alphabetically: end, start, color
const RocLine = extern struct {
    end: RocVector2,
    start: RocVector2,
    color: u8,
};

/// Roc Text type layout: { pos: Vector2, text: Str, size: I32, color: Color }
/// Fields ordered by alignment then alphabetically: text (8), pos (4), size (4), color (1)
const RocText = extern struct {
    text: RocStr,
    pos: RocVector2,
    size: i32,
    color: u8,
};

/// Convert Roc Color tag union discriminant to raylib Color
/// Tags sorted alphabetically: Black=0, Blue=1, DarkGray=2, Gray=3, Green=4,
/// LightGray=5, Orange=6, Pink=7, Purple=8, RayWhite=9, Red=10, White=11, Yellow=12
fn rocColorToRaylib(discriminant: u8) rl.Color {
    return switch (discriminant) {
        0 => rl.Color.black,
        1 => rl.Color.blue,
        2 => rl.Color.dark_gray,
        3 => rl.Color.gray,
        4 => rl.Color.green,
        5 => rl.Color.light_gray,
        6 => rl.Color.orange,
        7 => rl.Color.pink,
        8 => rl.Color.purple,
        9 => rl.Color.ray_white,
        10 => rl.Color.red,
        11 => rl.Color.white,
        12 => rl.Color.yellow,
        else => rl.Color.magenta, // Error fallback
    };
}

/// Hosted function: Draw.begin_frame! (index 0 alphabetically)
fn hostedDrawBeginFrame(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr;
    _ = args_ptr;
    rl.beginDrawing();
}

/// Hosted function: Draw.circle! (index 1 alphabetically)
fn hostedDrawCircle(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr;
    const circle: *const RocCircle = @ptrCast(@alignCast(args_ptr));
    rl.drawCircle(
        @intFromFloat(circle.center.x),
        @intFromFloat(circle.center.y),
        circle.radius,
        rocColorToRaylib(circle.color),
    );
}

/// Hosted function: Draw.clear! (index 2 alphabetically)
fn hostedDrawClear(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr;
    const color_discriminant: *const u8 = @ptrCast(args_ptr);
    rl.clearBackground(rocColorToRaylib(color_discriminant.*));
}

/// Hosted function: Draw.end_frame! (index 3 alphabetically)
fn hostedDrawEndFrame(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr;
    _ = args_ptr;
    rl.endDrawing();
}

/// Hosted function: Draw.line! (index 4 alphabetically)
fn hostedDrawLine(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr;
    const line: *const RocLine = @ptrCast(@alignCast(args_ptr));
    rl.drawLine(
        @intFromFloat(line.start.x),
        @intFromFloat(line.start.y),
        @intFromFloat(line.end.x),
        @intFromFloat(line.end.y),
        rocColorToRaylib(line.color),
    );
}

/// Hosted function: Draw.rectangle! (index 5 alphabetically)
fn hostedDrawRectangle(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr;
    const rect: *const RocRectangle = @ptrCast(@alignCast(args_ptr));
    rl.drawRectangle(
        @intFromFloat(rect.x),
        @intFromFloat(rect.y),
        @intFromFloat(rect.width),
        @intFromFloat(rect.height),
        rocColorToRaylib(rect.color),
    );
}

/// Hosted function: Draw.text! (index 6 alphabetically)
fn hostedDrawText(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr;
    const txt: *const RocText = @ptrCast(@alignCast(args_ptr));
    const text_slice = txt.text.asSlice();
    // raylib expects null-terminated string, use stack buffer for small strings
    var buf: [256:0]u8 = undefined;
    if (text_slice.len < buf.len) {
        @memcpy(buf[0..text_slice.len], text_slice);
        buf[text_slice.len] = 0;
        rl.drawText(buf[0..text_slice.len :0], @intFromFloat(txt.pos.x), @intFromFloat(txt.pos.y), txt.size, rocColorToRaylib(txt.color));
    }
}

/// Array of hosted function pointers, sorted alphabetically by fully-qualified name
/// Order: Draw.begin_frame!, Draw.circle!, Draw.clear!, Draw.end_frame!, Draw.line!, Draw.rectangle!, Draw.text!
const hosted_function_ptrs = [_]builtins.host_abi.HostedFn{
    hostedDrawBeginFrame, // Draw.begin_frame! (0)
    hostedDrawCircle, // Draw.circle! (1)
    hostedDrawClear, // Draw.clear! (2)
    hostedDrawEndFrame, // Draw.end_frame! (3)
    hostedDrawLine, // Draw.line! (4)
    hostedDrawRectangle, // Draw.rectangle! (5)
    hostedDrawText, // Draw.text! (6)
};

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

    // Initialize raylib window
    const screen_width = 800;
    const screen_height = 600;
    rl.initWindow(screen_width, screen_height, "Roc + Raylib");
    defer rl.closeWindow();

    rl.setTargetFPS(60);

    if (TRACE_HOST) {
        // Call the app's init! entrypoint
        std.log.debug("[HOST] Calling roc__init_for_host...", .{});
    }

    var init_result: Try_BoxModel_I64 = undefined;
    var unit: struct {} = .{};
    roc__init_for_host(&roc_ops, &init_result, @ptrCast(&unit));

    if (TRACE_HOST) {
        std.log.debug("[HOST] init returned, discriminant={d}", .{init_result.discriminant});
    }

    // Check if init failed
    if (init_result.isErr()) {
        const err_code = init_result.getErrCode();
        if (TRACE_HOST) {
            std.log.debug("[HOST] init returned Err({d})", .{err_code});
        }
        return @intCast(err_code);
    }

    // Get the boxed model from init
    var boxed_model = init_result.getModel();
    if (TRACE_HOST) {
        std.log.debug("[HOST] init returned Ok, model box=0x{x}", .{@intFromPtr(boxed_model)});
    }

    // Main render loop
    var exit_code: i32 = 0;
    var frame_count: u64 = 0;
    while (!rl.windowShouldClose()) {
        // Build platform state for this frame
        const mouse_pos = rl.getMousePosition();
        const platform_state = RocPlatformState{
            .frame_count = frame_count,
            .mouse_left = rl.isMouseButtonDown(.left),
            .mouse_middle = rl.isMouseButtonDown(.middle),
            .mouse_right = rl.isMouseButtonDown(.right),
            .mouse_wheel = rl.getMouseWheelMove(),
            .mouse_x = mouse_pos.x,
            .mouse_y = mouse_pos.y,
        };

        if (TRACE_HOST and frame_count % 60 == 0) {
            const dbg_stderr: std.fs.File = .stderr();
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "[HOST] frame={d} mouse=({d:.1}, {d:.1}) left={}\n", .{
                frame_count,
                platform_state.mouse_x,
                platform_state.mouse_y,
                platform_state.mouse_left,
            }) catch "[HOST] print error\n";
            dbg_stderr.writeAll(msg) catch {};
        }

        // Call render with the boxed model and platform state
        // Per RocCall ABI, args are passed as a single pointer to a tuple struct
        var render_args = RenderArgs{
            .model = boxed_model,
            .state = platform_state,
        };
        var render_result: Try_BoxModel_I64 = undefined;
        roc__render_for_host(&roc_ops, &render_result, &render_args);

        // Check render result
        if (render_result.isErr()) {
            exit_code = @intCast(render_result.getErrCode());
            if (TRACE_HOST) {
                std.log.debug("[HOST] render returned Err({d})", .{exit_code});
            }
            break;
        }

        // Update boxed_model for next iteration
        boxed_model = render_result.getModel();
        frame_count += 1;

        // Drawing is now handled by the Roc app via Draw effects
    }

    // Clean up final model
    if (exit_code == 0) {
        if (TRACE_HOST) {
            std.log.debug("[HOST] Decrementing refcount for final model box=0x{x}", .{@intFromPtr(boxed_model)});
        }
        decrefRocBox(boxed_model, &roc_ops);
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
