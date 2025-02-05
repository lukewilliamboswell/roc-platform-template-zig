const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const glue = @import("glue.zig");

const RocStr = glue.RocStr;

// the highest alignment of any primitive type
// can we make this finer-grained, zig wants to
// have a comptime constant for alignemnt
const Align = @alignOf(u128);

const PlatformEffects = glue.PlatformEffects;

// the host implementation... calls into roc using the platform API
// `roc__init_for_host` and `roc__run_for_host`
pub fn main() void {

    // let's use an AreaAllocator as an example
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) testing.expect(false) catch @panic("TEST FAIL");
    }
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    var allocator = arena.allocator();

    // We will be passing in function pointers for everything, instead of
    // the old roc double linking shenanigans
    const platform_effects = glue.PlatformEffects{
        .data = &allocator,
        .roc_alloc = &roc_alloc,
        .roc_realloc = &roc_realloc,
        .roc_dealloc = &roc_dealloc,
        .roc_panic = &roc_panic,
        .roc_dbg = &roc_dbg,
        .roc_expect_failed = &roc_expect_failed,
        .stdout_line = &stdout_line,
        .stdin_line = &stdin_line,
    };

    // Intermediate state returned from init.
    var state: RocStr = RocStr.empty;

    // call into roc
    glue.roc__init_for_host(
        &platform_effects,
        &state,
    );

    // Overall return value from run.
    var exit_code: i32 = -1;

    // call into roc
    glue.roc__run_for_host(
        &platform_effects,
        &exit_code,
        &state,
    );

    if (exit_code != 0) {
        std.log.info("Exited with code {d}\n", .{exit_code});
    }
}

fn roc_alloc(effects: *glue.PlatformEffects, requested_size: usize, alignment: u32) callconv(.C) ?*anyopaque {
    _ = alignment;
    const allocator: *std.mem.Allocator = @ptrCast(@alignCast(effects.data));

    // we allocate extra bytes to store the size of the allocation
    const ptr = allocator.alignedAlloc(u8, Align, requested_size + @sizeOf(usize)) catch return null;
    @as(*usize, @ptrCast(ptr)).* = requested_size;

    // we return a pointer to the location immediately after the size of the allocation
    return @as([*]u8, @ptrCast(ptr)) + @sizeOf(usize);
}

fn roc_realloc(effects: *glue.PlatformEffects, c_ptr: *anyopaque, new_size: usize, old_size: usize, alignment: u32) callconv(.C) ?*anyopaque {
    _ = alignment;
    const allocator: *std.mem.Allocator = @ptrCast(@alignCast(effects.data));
    const ptr = @as([*]align(Align) u8, @alignCast(@ptrCast(c_ptr))) - @sizeOf(usize);
    return (allocator.realloc(ptr[0 .. old_size + @sizeOf(usize)], new_size + @sizeOf(usize)) catch return null).ptr;
}

fn roc_dealloc(effects: *glue.PlatformEffects, c_ptr: *anyopaque, alignment: u32) callconv(.C) void {
    _ = alignment;
    const allocator: *std.mem.Allocator = @ptrCast(@alignCast(effects.data));
    const ptr = @as([*]align(Align) u8, @alignCast(@ptrCast(c_ptr))) - @sizeOf(usize);
    const size = @as(*usize, @ptrCast(ptr)).*;
    allocator.free(ptr[0 .. size + @sizeOf(usize)]);
}

fn roc_panic(_: *PlatformEffects, msg: *RocStr, tag_id: u32) callconv(.C) void {
    switch (tag_id) {
        0 => {
            std.log.err(
                "Roc standard library crashed with message\n\n    {s}\n\nShutting down\n",
                .{msg.asSlice()},
            );
            std.process.exit(1);
        },
        1 => {
            std.log.err(
                "Application crashed with message\n\n    {s}\n\nShutting down\n",
                .{msg.asSlice()},
            );
            std.process.exit(1);
        },
        else => unreachable,
    }
}

fn roc_dbg(_: *PlatformEffects, loc: *RocStr, msg: *RocStr, src: *RocStr) callconv(.C) void {
    std.log.debug(
        "[{s}] {s} = {s}\n",
        .{
            loc.asSlice(),
            src.asSlice(),
            msg.asSlice(),
        },
    );
}

// TODO
fn roc_expect_failed(_: *PlatformEffects, loc: *RocStr, src: *RocStr, variables: *anyopaque) callconv(.C) void {
    _ = loc;
    _ = src;

    // TODO take in a list of variables {name, value} and print them
    _ = variables;

    std.log.err("A roc `expect` failed somewhere...\n", .{});
}

// an example effect to provide to the platform
// this is where roc will call back into the host
fn stdout_line(_: *PlatformEffects, msg: *RocStr) callconv(.C) void {
    const stdout = std.io.getStdOut().writer();

    // TODO handle STDIO errors here
    stdout.print("{s}\n", .{msg.asSlice()}) catch unreachable;
}

fn stdin_line(effects: *PlatformEffects, out: *RocStr) callconv(.C) void {
    const stdin = std.io.getStdIn().reader();

    const allocator: *std.mem.Allocator = @ptrCast(@alignCast(effects.data));
    const MAX_SIZE = std.math.maxInt(usize);
    const buf = stdin.readUntilDelimiterOrEofAlloc(allocator.*, '\n', MAX_SIZE) catch {
        @panic("Failed to read from STDIN\n");
    };

    if (buf) |data| {
        out.* = RocStr.fromSlice(effects, data);
    } else {
        out.* = RocStr.empty;
    }
}
