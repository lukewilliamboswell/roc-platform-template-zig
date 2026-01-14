///! Platform host for roc-ray - a Roc platform for raylib graphics.
const std = @import("std");
const builtin = @import("builtin");
const builtins = @import("builtins");

/// Detect WASM target (freestanding wasm32)
const is_wasm = builtin.cpu.arch == .wasm32;

// Direct C interop with raylib (no wrapper dependency)
const rl = @cImport({
    @cInclude("raylib.h");
    @cInclude("rlgl.h");
});

// GLFW extern declarations for WASM builds (implementations provided by emscripten's -sUSE_GLFW=3)
// We declare these as extern rather than @cImport because GLFW headers are in emscripten's sysroot
const glfw = if (is_wasm) struct {
    pub extern fn glfwGetProcAddress(procname: [*:0]const u8) ?*anyopaque;
    pub extern fn glfwGetWindowAttrib(window: ?*anyopaque, attrib: i32) i32;
    pub extern fn glfwSetCursorPos(window: ?*anyopaque, xpos: f64, ypos: f64) void;
    pub extern fn glfwSetWindowAttrib(window: ?*anyopaque, attrib: i32, value: i32) void;
    pub extern fn glfwSetWindowSize(window: ?*anyopaque, width: i32, height: i32) void;
} else struct {};

// Emscripten HTML5 API extern declarations (used by raylib for browser interaction)
const emscripten = if (is_wasm) struct {
    pub extern fn emscripten_sleep(ms: c_uint) void;
    pub extern fn emscripten_asm_const_int(code: [*:0]const u8, sig: [*:0]const u8, args: ?*anyopaque) c_int;
    pub extern fn emscripten_set_window_title(title: [*:0]const u8) void;
    pub extern fn emscripten_set_canvas_element_size(target: [*:0]const u8, width: c_int, height: c_int) c_int;
    pub extern fn emscripten_exit_pointerlock() c_int;
    pub extern fn emscripten_request_pointerlock(target: [*:0]const u8, defer_until_in_event: c_int) c_int;
    pub extern fn emscripten_run_script(script: [*:0]const u8) void;
    pub extern fn emscripten_sample_gamepad_data() c_int;
    pub extern fn emscripten_get_num_gamepads() c_int;
    pub extern fn emscripten_get_gamepad_status(index: c_int, state: ?*anyopaque) c_int;
    pub extern fn emscripten_set_fullscreenchange_callback_on_thread(target: [*:0]const u8, user: ?*anyopaque, use_capture: c_int, callback: ?*anyopaque, thread: c_int) c_int;
    pub extern fn emscripten_set_resize_callback_on_thread(target: [*:0]const u8, user: ?*anyopaque, use_capture: c_int, callback: ?*anyopaque, thread: c_int) c_int;
    pub extern fn emscripten_set_click_callback_on_thread(target: [*:0]const u8, user: ?*anyopaque, use_capture: c_int, callback: ?*anyopaque, thread: c_int) c_int;
    pub extern fn emscripten_set_pointerlockchange_callback_on_thread(target: [*:0]const u8, user: ?*anyopaque, use_capture: c_int, callback: ?*anyopaque, thread: c_int) c_int;
    pub extern fn emscripten_set_mousemove_callback_on_thread(target: [*:0]const u8, user: ?*anyopaque, use_capture: c_int, callback: ?*anyopaque, thread: c_int) c_int;
    pub extern fn emscripten_set_touchstart_callback_on_thread(target: [*:0]const u8, user: ?*anyopaque, use_capture: c_int, callback: ?*anyopaque, thread: c_int) c_int;
    pub extern fn emscripten_set_touchend_callback_on_thread(target: [*:0]const u8, user: ?*anyopaque, use_capture: c_int, callback: ?*anyopaque, thread: c_int) c_int;
    pub extern fn emscripten_set_touchmove_callback_on_thread(target: [*:0]const u8, user: ?*anyopaque, use_capture: c_int, callback: ?*anyopaque, thread: c_int) c_int;
    pub extern fn emscripten_set_touchcancel_callback_on_thread(target: [*:0]const u8, user: ?*anyopaque, use_capture: c_int, callback: ?*anyopaque, thread: c_int) c_int;
    pub extern fn emscripten_set_gamepadconnected_callback_on_thread(user: ?*anyopaque, use_capture: c_int, callback: ?*anyopaque, thread: c_int) c_int;
    pub extern fn emscripten_set_gamepaddisconnected_callback_on_thread(user: ?*anyopaque, use_capture: c_int, callback: ?*anyopaque, thread: c_int) c_int;
    pub extern fn emscripten_get_element_css_size(target: [*:0]const u8, width: *f64, height: *f64) c_int;
} else struct {};

const TRACE_ALLOCATIONS = false;
const TRACE_HOST = false;

/// WASM console output functions (provided by JavaScript environment)
extern "env" fn js_console_log(ptr: [*]const u8, len: usize) void;
extern "env" fn js_console_error(ptr: [*]const u8, len: usize) void;

fn wasmConsoleLog(msg: []const u8) void {
    if (is_wasm) {
        js_console_log(msg.ptr, msg.len);
    }
}

fn wasmConsoleError(msg: []const u8) void {
    if (is_wasm) {
        js_console_error(msg.ptr, msg.len);
    }
}

/// Global flag to track if dbg or expect_failed was called.
/// If set, program exits with non-zero code to prevent accidental commits.
/// Note: For WASM, we use a simple bool since it's single-threaded.
/// For native builds, we use atomic to handle potential multi-threaded scenarios.
var debug_or_expect_called: if (is_wasm) bool else std.atomic.Value(bool) =
    if (is_wasm) false else std.atomic.Value(bool).init(false);

/// Host environment - conditionally uses different allocators for WASM vs native
const HostEnv = if (is_wasm) struct {
    // WASM uses a simple allocator, no stdin
    wasm_alloc: std.mem.Allocator,

    pub fn allocator(self: *@This()) std.mem.Allocator {
        return self.wasm_alloc;
    }
} else struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    stdin_reader: std.fs.File.Reader,

    pub fn allocator(self: *@This()) std.mem.Allocator {
        return self.gpa.allocator();
    }
};

/// Roc allocation function with size-tracking metadata
fn rocAllocFn(roc_alloc: *builtins.host_abi.RocAlloc, env: *anyopaque) callconv(.c) void {
    const host: *HostEnv = @ptrCast(@alignCast(env));
    const allocator = host.allocator();

    const min_alignment: usize = @max(roc_alloc.alignment, @alignOf(usize));
    const align_enum = std.mem.Alignment.fromByteUnits(min_alignment);

    // Calculate additional bytes needed to store the size
    const size_storage_bytes = @max(roc_alloc.alignment, @alignOf(usize));
    const total_size = roc_alloc.length + size_storage_bytes;

    // Allocate memory including space for size metadata
    const result = allocator.rawAlloc(total_size, align_enum, @returnAddress());

    const base_ptr = result orelse {
        if (is_wasm) {
            wasmConsoleError("Host error: allocation failed, out of memory");
            @panic("allocation failed");
        } else {
            const stderr: std.fs.File = .stderr();
            stderr.writeAll("\x1b[31mHost error:\x1b[0m allocation failed, out of memory\n") catch {};
            std.process.exit(1);
        }
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
    const allocator = host.allocator();

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
    const allocator = host.allocator();

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
        if (is_wasm) {
            wasmConsoleError("Host error: reallocation failed, out of memory");
            @panic("reallocation failed");
        } else {
            const stderr: std.fs.File = .stderr();
            stderr.writeAll("\x1b[31mHost error:\x1b[0m reallocation failed, out of memory\n") catch {};
            std.process.exit(1);
        }
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
    if (is_wasm) {
        debug_or_expect_called = true;
    } else {
        debug_or_expect_called.store(true, .release);
    }
    const message = roc_dbg.utf8_bytes[0..roc_dbg.len];
    if (is_wasm) {
        wasmConsoleLog("dbg: ");
        wasmConsoleLog(message);
    } else {
        const stderr: std.fs.File = .stderr();
        stderr.writeAll("\x1b[33mdbg:\x1b[0m ") catch {};
        stderr.writeAll(message) catch {};
        stderr.writeAll("\n") catch {};
    }
}

/// Roc expect failed function
fn rocExpectFailedFn(roc_expect: *const builtins.host_abi.RocExpectFailed, env: *anyopaque) callconv(.c) void {
    _ = env;
    if (is_wasm) {
        debug_or_expect_called = true;
    } else {
        debug_or_expect_called.store(true, .release);
    }
    const source_bytes = roc_expect.utf8_bytes[0..roc_expect.len];
    const trimmed = std.mem.trim(u8, source_bytes, " \t\n\r");
    if (is_wasm) {
        wasmConsoleError("expect failed: ");
        wasmConsoleError(trimmed);
    } else {
        const stderr: std.fs.File = .stderr();
        stderr.writeAll("\x1b[33mexpect failed:\x1b[0m ") catch {};
        stderr.writeAll(trimmed) catch {};
        stderr.writeAll("\n") catch {};
    }
}

/// Roc crashed function
fn rocCrashedFn(roc_crashed: *const builtins.host_abi.RocCrashed, env: *anyopaque) callconv(.c) noreturn {
    _ = env;
    const message = roc_crashed.utf8_bytes[0..roc_crashed.len];
    if (is_wasm) {
        wasmConsoleError("Roc crashed: ");
        wasmConsoleError(message);
        @panic("Roc crashed");
    } else {
        const stderr: std.fs.File = .stderr();
        var buf: [256]u8 = undefined;
        var w = stderr.writer(&buf);
        w.interface.print("\n\x1b[31mRoc crashed:\x1b[0m {s}\n", .{message}) catch {};
        w.interface.flush() catch {};
        std.process.exit(1);
    }
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
    if (!builtin.is_test) {
        // Export main for all platforms (including WASM/emscripten)
        @export(&main, .{ .name = "main" });

        // Windows MinGW/MSVCRT compatibility: export __main stub
        if (builtin.os.tag == .windows) {
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
        0 => rl.BLACK,
        1 => rl.BLUE,
        2 => rl.DARKGRAY,
        3 => rl.GRAY,
        4 => rl.GREEN,
        5 => rl.LIGHTGRAY,
        6 => rl.ORANGE,
        7 => rl.PINK,
        8 => rl.PURPLE,
        9 => rl.RAYWHITE,
        10 => rl.RED,
        11 => rl.WHITE,
        12 => rl.YELLOW,
        else => rl.MAGENTA, // Error fallback
    };
}

/// Hosted function: Draw.begin_frame! (index 0 alphabetically)
fn hostedDrawBeginFrame(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr;
    _ = args_ptr;
    rl.BeginDrawing();
}

/// Hosted function: Draw.circle! (index 1 alphabetically)
fn hostedDrawCircle(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr;
    const circle: *const RocCircle = @ptrCast(@alignCast(args_ptr));
    rl.DrawCircle(
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
    rl.ClearBackground(rocColorToRaylib(color_discriminant.*));
}

/// Hosted function: Draw.end_frame! (index 3 alphabetically)
fn hostedDrawEndFrame(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr;
    _ = args_ptr;
    rl.EndDrawing();
}

/// Hosted function: Draw.line! (index 4 alphabetically)
fn hostedDrawLine(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr;
    const line: *const RocLine = @ptrCast(@alignCast(args_ptr));
    rl.DrawLine(
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
    rl.DrawRectangle(
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
        rl.DrawText(buf[0..text_slice.len :0], @intFromFloat(txt.pos.x), @intFromFloat(txt.pos.y), txt.size, rocColorToRaylib(txt.color));
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

/// Force-include all rlgl/GL functions that raylib might use at runtime.
/// This prevents emscripten from dead-code-eliminating GL functions that
/// are only called through certain raylib code paths.
/// The function is never actually called - just referenced at comptime.
fn forceIncludeGLFunctions() void {
    // Framebuffer functions (glBindFramebuffer, glGenFramebuffers, glDeleteFramebuffers, etc.)
    _ = rl.rlLoadFramebuffer;
    _ = rl.rlUnloadFramebuffer;
    _ = rl.rlFramebufferAttach;
    _ = rl.rlFramebufferComplete;
    _ = rl.rlBindFramebuffer;
    _ = rl.rlEnableFramebuffer;
    _ = rl.rlDisableFramebuffer;

    // Renderbuffer functions (glBindRenderbuffer, glGenRenderbuffers, glRenderbufferStorage)
    _ = rl.rlLoadTextureDepth;

    // Blending functions (glBlendEquation, glBlendEquationSeparate, glBlendFuncSeparate)
    _ = rl.rlSetBlendMode;
    _ = rl.rlSetBlendFactors;
    _ = rl.rlSetBlendFactorsSeparate;
    _ = rl.rlEnableColorBlend;
    _ = rl.rlDisableColorBlend;

    // Texture functions (glTexParameterf, glTexSubImage2D, glGenerateMipmap)
    _ = rl.rlLoadTexture;
    _ = rl.rlLoadTextureCubemap;
    _ = rl.rlUnloadTexture;
    _ = rl.rlUpdateTexture;
    _ = rl.rlGenTextureMipmaps;
    _ = rl.rlReadTexturePixels;
    _ = rl.rlSetTexture;
    _ = rl.rlActiveTextureSlot;
    _ = rl.rlEnableTexture;
    _ = rl.rlDisableTexture;
    _ = rl.rlEnableTextureCubemap;
    _ = rl.rlDisableTextureCubemap;
    _ = rl.rlTextureParameters;

    // Shader uniform functions (glUniform1fv, glUniform2fv, glUniform3fv, glUniform4fv, etc.)
    _ = rl.rlSetUniform;
    _ = rl.rlSetUniformMatrix;
    _ = rl.rlSetUniformMatrices;
    _ = rl.rlSetUniformSampler;
    _ = rl.rlLoadShaderCode;
    _ = rl.rlLoadShaderProgram;
    _ = rl.rlUnloadShaderProgram;
    _ = rl.rlEnableShader;
    _ = rl.rlDisableShader;
    _ = rl.rlSetShader;
    _ = rl.rlGetLocationUniform;
    _ = rl.rlGetLocationAttrib;

    // Vertex attribute functions (glVertexAttrib1fv, glVertexAttrib2fv, etc.)
    _ = rl.rlSetVertexAttribute;
    _ = rl.rlSetVertexAttributeDefault;
    _ = rl.rlSetVertexAttributeDivisor;
    _ = rl.rlEnableVertexAttribute;
    _ = rl.rlDisableVertexAttribute;
    _ = rl.rlLoadVertexArray;
    _ = rl.rlLoadVertexBuffer;
    _ = rl.rlLoadVertexBufferElement;
    _ = rl.rlUnloadVertexArray;
    _ = rl.rlUnloadVertexBuffer;
    _ = rl.rlEnableVertexArray;
    _ = rl.rlDisableVertexArray;
    _ = rl.rlEnableVertexBuffer;
    _ = rl.rlDisableVertexBuffer;
    _ = rl.rlEnableVertexBufferElement;
    _ = rl.rlDisableVertexBufferElement;

    // Depth/stencil functions (glDepthMask, glColorMask)
    _ = rl.rlEnableDepthTest;
    _ = rl.rlDisableDepthTest;
    _ = rl.rlEnableDepthMask;
    _ = rl.rlDisableDepthMask;
    _ = rl.rlColorMask;

    // Scissor functions (glScissor)
    _ = rl.rlEnableScissorTest;
    _ = rl.rlDisableScissorTest;
    _ = rl.rlScissor;

    // Line width (glLineWidth)
    _ = rl.rlSetLineWidth;
    _ = rl.rlGetLineWidth;

    // Error checking (glGetError)
    _ = rl.rlGetGlTextureFormats;
    _ = rl.rlGetVersion;

    // Render batch (uses various GL functions internally)
    _ = rl.rlLoadRenderBatch;
    _ = rl.rlUnloadRenderBatch;
    _ = rl.rlDrawRenderBatch;
    _ = rl.rlSetRenderBatchActive;
    _ = rl.rlDrawRenderBatchActive;
    _ = rl.rlCheckRenderBatchLimit;

    // Matrix functions
    _ = rl.rlSetMatrixProjection;
    _ = rl.rlSetMatrixModelview;
    _ = rl.rlGetMatrixModelview;
    _ = rl.rlGetMatrixProjection;
    _ = rl.rlGetMatrixTransform;
    _ = rl.rlGetMatrixProjectionStereo;
    _ = rl.rlGetMatrixViewOffsetStereo;

    // Drawing primitives (to ensure basic GL calls are included)
    _ = rl.rlLoadDrawCube;
    _ = rl.rlLoadDrawQuad;

    // GLFW functions (only for WASM builds, provided by emscripten's -sUSE_GLFW=3)
    // Force emscripten to include these by generating actual call instructions
    if (is_wasm) {
        // These calls are in dead code (the function is never called with flag=true)
        // but they force the compiler to include the GLFW function imports
        _ = glfw.glfwGetProcAddress("dummy");
        _ = glfw.glfwGetWindowAttrib(null, 0);
        glfw.glfwSetCursorPos(null, 0, 0);
        glfw.glfwSetWindowAttrib(null, 0, 0);
        glfw.glfwSetWindowSize(null, 0, 0);

        // Emscripten HTML5 API functions (used by raylib for browser interaction)
        emscripten.emscripten_sleep(0);
        _ = emscripten.emscripten_asm_const_int("", "", null);
        emscripten.emscripten_set_window_title("");
        _ = emscripten.emscripten_set_canvas_element_size("", 0, 0);
        _ = emscripten.emscripten_exit_pointerlock();
        _ = emscripten.emscripten_request_pointerlock("", 0);
        emscripten.emscripten_run_script("");
        _ = emscripten.emscripten_sample_gamepad_data();
        _ = emscripten.emscripten_get_num_gamepads();
        _ = emscripten.emscripten_get_gamepad_status(0, null);
        _ = emscripten.emscripten_set_fullscreenchange_callback_on_thread("", null, 0, null, 0);
        _ = emscripten.emscripten_set_resize_callback_on_thread("", null, 0, null, 0);
        _ = emscripten.emscripten_set_click_callback_on_thread("", null, 0, null, 0);
        _ = emscripten.emscripten_set_pointerlockchange_callback_on_thread("", null, 0, null, 0);
        _ = emscripten.emscripten_set_mousemove_callback_on_thread("", null, 0, null, 0);
        _ = emscripten.emscripten_set_touchstart_callback_on_thread("", null, 0, null, 0);
        _ = emscripten.emscripten_set_touchend_callback_on_thread("", null, 0, null, 0);
        _ = emscripten.emscripten_set_touchmove_callback_on_thread("", null, 0, null, 0);
        _ = emscripten.emscripten_set_touchcancel_callback_on_thread("", null, 0, null, 0);
        _ = emscripten.emscripten_set_gamepadconnected_callback_on_thread(null, 0, null, 0);
        _ = emscripten.emscripten_set_gamepaddisconnected_callback_on_thread(null, 0, null, 0);
        var w: f64 = 0;
        var h: f64 = 0;
        _ = emscripten.emscripten_get_element_css_size("", &w, &h);
    }
}

// Force the compiler to include the GL/GLFW function references by exporting
// This prevents dead-code elimination during both Zig and emscripten compilation
export fn __force_gl_exports() void {
    forceIncludeGLFunctions();
}

/// Platform host entrypoint
fn platform_main(argc: usize, argv: [*][*:0]u8) c_int {
    var host_env: HostEnv = if (is_wasm) blk: {
        break :blk HostEnv{
            .wasm_alloc = std.heap.wasm_allocator,
        };
    } else blk: {
        var stdin_buffer: [4096]u8 = undefined;
        break :blk HostEnv{
            .gpa = std.heap.GeneralPurposeAllocator(.{}){},
            .stdin_reader = std.fs.File.stdin().reader(&stdin_buffer),
        };
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
    rl.InitWindow(screen_width, screen_height, "Roc + Raylib");
    defer rl.CloseWindow();

    rl.SetTargetFPS(60);

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

    rl.SetTargetFPS(240);

    // Main render loop
    var exit_code: i32 = 0;
    var frame_count: u64 = 0;
    while (!rl.WindowShouldClose()) {
        // Build platform state for this frame
        const mouse_pos = rl.GetMousePosition();
        const platform_state = RocPlatformState{
            .frame_count = frame_count,
            .mouse_left = rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT),
            .mouse_middle = rl.IsMouseButtonDown(rl.MOUSE_BUTTON_MIDDLE),
            .mouse_right = rl.IsMouseButtonDown(rl.MOUSE_BUTTON_RIGHT),
            .mouse_wheel = rl.GetMouseWheelMove(),
            .mouse_x = mouse_pos.x,
            .mouse_y = mouse_pos.y,
        };

        if (TRACE_HOST and frame_count % 60 == 0) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "[HOST] frame={d} mouse=({d:.1}, {d:.1}) left={}\n", .{
                frame_count,
                platform_state.mouse_x,
                platform_state.mouse_y,
                platform_state.mouse_left,
            }) catch "[HOST] print error\n";
            if (is_wasm) {
                wasmConsoleLog(msg);
            } else {
                const dbg_stderr: std.fs.File = .stderr();
                dbg_stderr.writeAll(msg) catch {};
            }
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

    // Check for memory leaks before returning (native builds only)
    if (!is_wasm) {
        const leak_status = host_env.gpa.deinit();
        if (leak_status == .leak) {
            std.log.warn("Memory leak detected", .{});
        }
    }

    // If dbg or expect_failed was called, ensure non-zero exit code
    // to prevent accidental commits with debug statements or failing tests
    const was_debug_called = if (is_wasm) debug_or_expect_called else debug_or_expect_called.load(.acquire);
    if (was_debug_called and exit_code == 0) {
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
