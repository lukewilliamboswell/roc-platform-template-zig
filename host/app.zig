// EVERYTHING IN THIS FILE WOULD BE GENERATED BY ROC
// WE ARE STUBBING OUT THE IMPLEMENTATIONS UNTIL ROC CAN COMPILE
// AND CODE GEN AN OBJECT FILE
const std = @import("std");

const MASK_ISIZE: isize = std.math.minInt(isize);
const MASK: usize = @as(usize, @bitCast(MASK_ISIZE));
const SEAMLESS_SLICE_BIT: usize = MASK;
const REFCOUNT_MAX_ISIZE: isize = 0;

pub const RocStr = extern struct {
    bytes: ?[*]u8,
    length: usize,
    capacity_or_alloc_ptr: usize,

    pub const alignment = @alignOf(usize);

    pub fn len(self: RocStr) usize {
        if (self.isSmallStr()) {
            return self.asArray()[@sizeOf(RocStr) - 1] ^ 0b1000_0000;
        } else {
            return self.length & (~SEAMLESS_SLICE_BIT);
        }
    }

    fn asArray(self: RocStr) [@sizeOf(RocStr)]u8 {
        const as_ptr = @as([*]const u8, @ptrCast(&self));
        const slice = as_ptr[0..@sizeOf(RocStr)];

        return slice.*;
    }


    pub fn isSmallStr(self: RocStr) bool {
        return @as(isize, @bitCast(self.capacity_or_alloc_ptr)) < 0;
    }

    pub fn asU8ptr(self: *const RocStr) [*]const u8 {
        if (self.isSmallStr()) {
            return @as([*]const u8, @ptrCast(self));
        } else {
            return @as([*]const u8, @ptrCast(self.bytes));
        }
    }

    pub fn incref(self: RocStr, n: usize) void {
        if (!self.isSmallStr()) {
            const alloc_ptr = self.getAllocationPtr();
            if (alloc_ptr != null) {
                const isizes: [*]isize = @as([*]isize, @ptrCast(@alignCast(alloc_ptr)));
                utils_increfRcPtrC(@as(*isize, @ptrCast(isizes - 1)), @as(isize, @intCast(n)));
            }
        }
    }

    pub fn decref(self: RocStr, effects: *PlatformEffects) void {
        if (!self.isSmallStr()) {
            utils_decref(effects, self.getAllocationPtr(), self.capacity_or_alloc_ptr, RocStr.alignment, false);
        }
    }

    // returns a pointer to the original allocation.
    // This pointer points to the first element of the allocation.
    // The pointer is to just after the refcount.
    // For big strings, it just returns their bytes pointer.
    // For seamless slices, it returns the pointer stored in capacity_or_alloc_ptr.
    // This does not return a valid value if the input is a small string.
    pub fn getAllocationPtr(self: RocStr) ?[*]u8 {
        const str_alloc_ptr = @intFromPtr(self.bytes);
        const slice_alloc_ptr = self.capacity_or_alloc_ptr << 1;
        const slice_mask = self.seamlessSliceMask();
        const alloc_ptr = (str_alloc_ptr & ~slice_mask) | (slice_alloc_ptr & slice_mask);
        return @as(?[*]u8, @ptrFromInt(alloc_ptr));
    }

    // This returns all ones if the list is a seamless slice.
    // Otherwise, it returns all zeros.
    // This is done without branching for optimization purposes.
    pub fn seamlessSliceMask(self: RocStr) usize {
        return @as(usize, @bitCast(@as(isize, @bitCast(self.length)) >> (@bitSizeOf(isize) - 1)));
    }

    pub fn fromSlice(slice: []const u8) RocStr {
        // this is probably wrong...
        return RocStr{
            .bytes = @constCast(slice.ptr),
            .length = slice.len,
            .capacity_or_alloc_ptr = 0,
        };
    }

};

pub fn utils_increfRcPtrC(ptr_to_refcount: *isize, amount: isize) callconv(.C) void {
    // Ensure that the refcount is not whole program lifetime.
    const refcount: isize = ptr_to_refcount.*;
    if (!(refcount == REFCOUNT_MAX_ISIZE)) {
        ptr_to_refcount.* = refcount +% amount;
    }
}

pub fn utils_decref(
    effects: *PlatformEffects,
    bytes_or_null: ?[*]u8,
    data_bytes: usize,
    alignment: u32,
    elements_refcounted: bool,
) void {
    if (data_bytes == 0) {
        return;
    }

    const bytes = bytes_or_null orelse return;

    const isizes: [*]isize = @as([*]isize, @ptrCast(@alignCast(bytes)));

    utils_decref_ptr_to_refcount(effects, isizes - 1, alignment, elements_refcounted);
}

inline fn utils_decref_ptr_to_refcount(
    effects: *PlatformEffects,
    refcount_ptr: [*]isize,
    element_alignment: u32,
    elements_refcounted: bool,
) void {

    // Due to RC alignmen tmust take into acount pointer size.
    const ptr_width = @sizeOf(usize);
    const alignment = @max(ptr_width, element_alignment);

    // Ensure that the refcount is not whole program lifetime.
    const refcount: isize = refcount_ptr[0];
    if (!(refcount == REFCOUNT_MAX_ISIZE)) {
        refcount_ptr[0] = refcount -% 1;
        if (refcount == 1) {
            const ptr_width2 = @sizeOf(usize);
            const required_space: usize = if (elements_refcounted) (2 * ptr_width2) else ptr_width2;
            const extra_bytes = @max(required_space, alignment);
            const allocation_ptr = @as([*]u8, @ptrCast(refcount_ptr)) - (extra_bytes - @sizeOf(usize));

            effects.roc_dealloc(effects, allocation_ptr, alignment);
        }
    }
}

export fn roc__str_len(out: *u64, str: *RocStr) void {
    const length = str.len();
    out.* = @as(u64, length);
}

export fn roc__str_ptr(out: *?[*]const u8, str: *RocStr) void {
    const ptr = str.asU8ptr();
    out.* = ptr;
}

export fn roc__str_new(effects: *PlatformEffects, out: *RocStr, data: [*]const u8, len: *const u64) void {

    _ = data;

    const len_usize: usize =@intCast(len.*);
    const ptr = effects.*.roc_alloc(effects, @as(usize, len.*), 1);
    if (ptr) |bytes| {
       out.*.bytes = @ptrCast(bytes);
       out.*.length = len_usize;
       out.*.capacity_or_alloc_ptr = len_usize;
    } else {
        // TODO: fill in panic call.
        var msg = RocStr.fromSlice(PANIC_MSG);
       effects.*.roc_panic(effects, &msg, 0);
    }
}

const PANIC_STR = RocStr{
    .bytes = PANIC_MSG.ptr,
    .length = PANIC_MSG.len,
    .capacity_or_alloc_ptr = PANIC_MSG.len,
};
const PANIC_MSG = "Failed to allocate RocStr";

export fn roc__str_incref(str: *RocStr) void {
    str.incref(1);
}

export fn roc__str_decref(effects: *PlatformEffects, str: *RocStr) void {
    str.decref(effects);
}

pub const PlatformEffects = extern struct {
    // 1. DATA STORE
    // store any state for the host, ie. the allocator might be required by an effect
    data: *anyopaque,

    // 2. ROC ALLOCATORS (in alphabetical order)

    // Allocators for roc to use
    roc_alloc: *const fn (effects: *PlatformEffects, size: usize, alignment: u32) callconv(.C) ?*anyopaque,
    roc_dealloc: *const fn (effects: *PlatformEffects, c_ptr: *anyopaque, alignment: u32) callconv(.C) void,
    roc_realloc: *const fn (effects: *PlatformEffects, c_ptr: *anyopaque, new_size: usize, old_size: usize, alignment: u32) callconv(.C) ?*anyopaque,

    // 3. ROC OTHER (in alphabetical order)

    // `dbg` was called
    roc_dbg: *const fn (effects: *PlatformEffects, loc: *RocStr, msg: *RocStr, src: *RocStr) callconv(.C) void,

    // `roc test` was ran and an expect failed, or an inline `expect` assertion failed
    roc_expect_failed: *const fn (effects: *PlatformEffects, loc: *RocStr, src: *RocStr, variables: *anyopaque) callconv(.C) void,

    // roc crashed in an unrecoverable way
    roc_panic: *const fn (effects: *PlatformEffects, msg: *RocStr, tag_id: u32) callconv(.C) void,

    // 4. PLATFORM EFFECTS (in alphabetical order)

    // the stdin_line! effect
    stdin_line: *const fn (effects: *PlatformEffects, ret: *RocStr) callconv(.C) void,
    // the stdout_line! effect
    stdout_line: *const fn (effects: *PlatformEffects, msg: *RocStr) callconv(.C) void,
};

export fn roc__init_for_host(_: *PlatformEffects, out: *RocStr) callconv(.C) void {
    const str = RocStr.fromSlice("Hello");
    out.* = str;
}

export fn roc__run_for_host(effects: *PlatformEffects,out: *i32,state: *RocStr) callconv(.C) void {
    std.log.info("Running Roc APP", .{});
    effects.*.stdout_line(effects, state);
    out.* = 0;
}
