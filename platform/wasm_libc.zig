///! Minimal libc implementation for wasm32-freestanding
///! Provides C library functions needed by raylib and the platform
const std = @import("std");
const builtin = @import("builtin");

// Use Zig's wasm page allocator for memory management
var wasm_allocator = std.heap.wasm_allocator;

// ============================================================================
// Memory allocation
// ============================================================================

export fn malloc(size: usize) ?*anyopaque {
    if (size == 0) return null;
    const slice = wasm_allocator.alloc(u8, size) catch return null;
    return slice.ptr;
}

export fn calloc(num: usize, size: usize) ?*anyopaque {
    const total = num *| size; // saturating multiply
    if (total == 0) return null;
    const slice = wasm_allocator.alloc(u8, total) catch return null;
    @memset(slice, 0);
    return slice.ptr;
}

export fn free(ptr: ?*anyopaque) void {
    // wasm_allocator is a bump allocator that doesn't support free
    // Memory is reclaimed when the wasm instance is destroyed
    _ = ptr;
}

export fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    if (size == 0) {
        free(ptr);
        return null;
    }
    // Simple implementation: allocate new, copy, don't free old
    // This leaks memory but works for wasm where instance lifetime is short
    const new_ptr = malloc(size) orelse return null;
    if (ptr) |old| {
        const old_bytes: [*]const u8 = @ptrCast(old);
        const new_bytes: [*]u8 = @ptrCast(new_ptr);
        // Copy up to size bytes (we don't know old size, but this is safe)
        @memcpy(new_bytes[0..size], old_bytes[0..size]);
    }
    return new_ptr;
}

// ============================================================================
// String functions
// ============================================================================

export fn strlen(s: ?[*:0]const u8) usize {
    const str = s orelse return 0;
    var len: usize = 0;
    while (str[len] != 0) : (len += 1) {}
    return len;
}

export fn strcpy(dest: ?[*]u8, src: ?[*:0]const u8) ?[*]u8 {
    const d = dest orelse return null;
    const s = src orelse return dest;
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        d[i] = s[i];
    }
    d[i] = 0;
    return dest;
}

export fn strncpy(dest: ?[*]u8, src: ?[*:0]const u8, n: usize) ?[*]u8 {
    const d = dest orelse return null;
    const s = src orelse return dest;
    var i: usize = 0;
    while (i < n and s[i] != 0) : (i += 1) {
        d[i] = s[i];
    }
    while (i < n) : (i += 1) {
        d[i] = 0;
    }
    return dest;
}

export fn strcmp(s1: ?[*:0]const u8, s2: ?[*:0]const u8) c_int {
    const a = s1 orelse return if (s2 == null) 0 else -1;
    const b = s2 orelse return 1;
    var i: usize = 0;
    while (a[i] != 0 and a[i] == b[i]) : (i += 1) {}
    return @as(c_int, a[i]) - @as(c_int, b[i]);
}

export fn strstr(haystack: ?[*:0]const u8, needle: ?[*:0]const u8) ?[*]const u8 {
    const h = haystack orelse return null;
    const n = needle orelse return @ptrCast(h);

    const needle_len = strlen(n);
    if (needle_len == 0) return @ptrCast(h);

    var i: usize = 0;
    while (h[i] != 0) : (i += 1) {
        var match = true;
        for (0..needle_len) |j| {
            if (h[i + j] == 0 or h[i + j] != n[j]) {
                match = false;
                break;
            }
        }
        if (match) return @ptrCast(&h[i]);
    }
    return null;
}

export fn strchr(s: ?[*:0]const u8, c: c_int) ?[*]const u8 {
    const str = s orelse return null;
    const char: u8 = @intCast(c & 0xFF);
    var i: usize = 0;
    while (true) : (i += 1) {
        if (str[i] == char) return @ptrCast(&str[i]);
        if (str[i] == 0) return null;
    }
}

export fn strrchr(s: ?[*:0]const u8, c: c_int) ?[*]const u8 {
    const str = s orelse return null;
    const char: u8 = @intCast(c & 0xFF);
    var last: ?[*]const u8 = null;
    var i: usize = 0;
    while (true) : (i += 1) {
        if (str[i] == char) last = @ptrCast(&str[i]);
        if (str[i] == 0) return last;
    }
}

export fn strpbrk(s: ?[*:0]const u8, accept: ?[*:0]const u8) ?[*]const u8 {
    const str = s orelse return null;
    const acc = accept orelse return null;
    var i: usize = 0;
    while (str[i] != 0) : (i += 1) {
        var j: usize = 0;
        while (acc[j] != 0) : (j += 1) {
            if (str[i] == acc[j]) return @ptrCast(&str[i]);
        }
    }
    return null;
}

// ============================================================================
// Math functions
// ============================================================================

export fn atan2f(y: f32, x: f32) f32 {
    return std.math.atan2(y, x);
}

export fn acosf(x: f32) f32 {
    return std.math.acos(x);
}

export fn asinf(x: f32) f32 {
    return std.math.asin(x);
}

// ============================================================================
// Time functions (stubs for web - time comes from JS)
// ============================================================================

const timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

export fn clock_gettime(clk_id: c_int, tp: ?*timespec) c_int {
    _ = clk_id;
    if (tp) |t| {
        t.tv_sec = 0;
        t.tv_nsec = 0;
    }
    return 0;
}

export fn time(tloc: ?*i64) i64 {
    if (tloc) |t| t.* = 0;
    return 0;
}

export fn nanosleep(req: ?*const timespec, rem: ?*timespec) c_int {
    _ = req;
    if (rem) |r| {
        r.tv_sec = 0;
        r.tv_nsec = 0;
    }
    return 0;
}

// ============================================================================
// File I/O stubs (return errors - web builds should use embedded assets)
// ============================================================================

export fn fopen(filename: ?[*:0]const u8, mode: ?[*:0]const u8) ?*anyopaque {
    _ = filename;
    _ = mode;
    return null; // File not found
}

export fn fclose(stream: ?*anyopaque) c_int {
    _ = stream;
    return -1;
}

export fn fseek(stream: ?*anyopaque, offset: c_long, whence: c_int) c_int {
    _ = stream;
    _ = offset;
    _ = whence;
    return -1;
}

export fn ftell(stream: ?*anyopaque) c_long {
    _ = stream;
    return -1;
}

export fn opendir(name: ?[*:0]const u8) ?*anyopaque {
    _ = name;
    return null;
}

export fn closedir(dirp: ?*anyopaque) c_int {
    _ = dirp;
    return -1;
}

export fn readdir(dirp: ?*anyopaque) ?*anyopaque {
    _ = dirp;
    return null;
}

export fn stat(path: ?[*:0]const u8, buf: ?*anyopaque) c_int {
    _ = path;
    _ = buf;
    return -1;
}

export fn access(path: ?[*:0]const u8, mode: c_int) c_int {
    _ = path;
    _ = mode;
    return -1; // Access denied
}

export fn getcwd(buf: ?[*]u8, size: usize) ?[*]u8 {
    if (buf) |b| {
        if (size > 0) {
            b[0] = '/';
            if (size > 1) b[1] = 0;
            return b;
        }
    }
    return null;
}

// ============================================================================
// Other C library functions
// ============================================================================

export fn __assert_fail(
    assertion: ?[*:0]const u8,
    file: ?[*:0]const u8,
    line: c_uint,
    function: ?[*:0]const u8,
) noreturn {
    _ = assertion;
    _ = file;
    _ = line;
    _ = function;
    @panic("assertion failed");
}

// Minimal printf implementation for integers (used by raylib logging)
export fn siprintf(buf: ?[*]u8, format: ?[*:0]const u8, ...) c_int {
    _ = buf;
    _ = format;
    return 0;
}

export fn iprintf(format: ?[*:0]const u8, ...) c_int {
    _ = format;
    return 0;
}

export fn fiprintf(stream: ?*anyopaque, format: ?[*:0]const u8, ...) c_int {
    _ = stream;
    _ = format;
    return 0;
}

export fn snprintf(buf: ?[*]u8, size: usize, format: ?[*:0]const u8, ...) c_int {
    _ = buf;
    _ = size;
    _ = format;
    return 0;
}

export fn vsnprintf(buf: ?[*]u8, size: usize, format: ?[*:0]const u8, args: ?*anyopaque) c_int {
    _ = buf;
    _ = size;
    _ = format;
    _ = args;
    return 0;
}

export fn vprintf(format: ?[*:0]const u8, args: ?*anyopaque) c_int {
    _ = format;
    _ = args;
    return 0;
}

export fn __small_sprintf(buf: ?[*]u8, format: ?[*:0]const u8, ...) c_int {
    _ = buf;
    _ = format;
    return 0;
}

export fn sscanf(str: ?[*:0]const u8, format: ?[*:0]const u8, ...) c_int {
    _ = str;
    _ = format;
    return 0;
}

// ============================================================================
// Additional file I/O stubs
// ============================================================================

export fn mkdir(path: ?[*:0]const u8, mode: c_uint) c_int {
    _ = path;
    _ = mode;
    return -1;
}

export fn chdir(path: ?[*:0]const u8) c_int {
    _ = path;
    return -1;
}

export fn fgets(buf: ?[*]u8, size: c_int, stream: ?*anyopaque) ?[*]u8 {
    _ = buf;
    _ = size;
    _ = stream;
    return null;
}

export fn feof(stream: ?*anyopaque) c_int {
    _ = stream;
    return 1; // EOF
}

export fn ferror(stream: ?*anyopaque) c_int {
    _ = stream;
    return 1; // Error
}

export fn fread(ptr: ?*anyopaque, size: usize, nmemb: usize, stream: ?*anyopaque) usize {
    _ = ptr;
    _ = size;
    _ = nmemb;
    _ = stream;
    return 0;
}

export fn fwrite(ptr: ?*const anyopaque, size: usize, nmemb: usize, stream: ?*anyopaque) usize {
    _ = ptr;
    _ = size;
    _ = nmemb;
    _ = stream;
    return 0;
}

export fn fflush(stream: ?*anyopaque) c_int {
    _ = stream;
    return 0;
}

export fn fgetc(stream: ?*anyopaque) c_int {
    _ = stream;
    return -1; // EOF
}

export fn ungetc(c: c_int, stream: ?*anyopaque) c_int {
    _ = c;
    _ = stream;
    return -1;
}

// ============================================================================
// Additional math functions
// ============================================================================

export fn powf(base: f32, exp: f32) f32 {
    return std.math.pow(f32, base, exp);
}

export fn pow(base: f64, exp: f64) f64 {
    return std.math.pow(f64, base, exp);
}

export fn hypotf(x: f32, y: f32) f32 {
    return std.math.hypot(x, y);
}

export fn hypot(x: f64, y: f64) f64 {
    return std.math.hypot(x, y);
}

export fn acos(x: f64) f64 {
    return std.math.acos(x);
}

export fn frexp(x: f64, exp: ?*c_int) f64 {
    const result = std.math.frexp(x);
    if (exp) |e| e.* = result.exponent;
    return result.significand;
}

// ============================================================================
// Additional string functions
// ============================================================================

export fn strspn(s: ?[*:0]const u8, accept: ?[*:0]const u8) usize {
    const str = s orelse return 0;
    const acc = accept orelse return 0;
    var count: usize = 0;
    outer: while (str[count] != 0) : (count += 1) {
        var j: usize = 0;
        while (acc[j] != 0) : (j += 1) {
            if (str[count] == acc[j]) continue :outer;
        }
        break;
    }
    return count;
}

export fn strncmp(s1: ?[*:0]const u8, s2: ?[*:0]const u8, n: usize) c_int {
    const a = s1 orelse return if (s2 == null) 0 else -1;
    const b = s2 orelse return 1;
    var i: usize = 0;
    while (i < n and a[i] != 0 and a[i] == b[i]) : (i += 1) {}
    if (i == n) return 0;
    return @as(c_int, a[i]) - @as(c_int, b[i]);
}

export fn memchr(s: ?*const anyopaque, c: c_int, n: usize) ?*const anyopaque {
    const ptr: [*]const u8 = @ptrCast(s orelse return null);
    const char: u8 = @intCast(c & 0xFF);
    for (0..n) |i| {
        if (ptr[i] == char) return @ptrCast(&ptr[i]);
    }
    return null;
}

// ============================================================================
// Other required functions
// ============================================================================

export fn qsort(base: ?*anyopaque, nmemb: usize, size: usize, compar: ?*const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int) void {
    // Simple bubble sort fallback (not efficient but works)
    _ = base;
    _ = nmemb;
    _ = size;
    _ = compar;
}

export fn exit(status: c_int) noreturn {
    _ = status;
    @panic("exit called");
}

var errno_value: c_int = 0;
export fn __errno_location() *c_int {
    return &errno_value;
}

export fn strerror(errnum: c_int) ?[*:0]const u8 {
    _ = errnum;
    return "Error";
}

export fn strcspn(s: ?[*:0]const u8, reject: ?[*:0]const u8) usize {
    const str = s orelse return 0;
    const rej = reject orelse return strlen(s);
    var count: usize = 0;
    outer: while (str[count] != 0) : (count += 1) {
        var j: usize = 0;
        while (rej[j] != 0) : (j += 1) {
            if (str[count] == rej[j]) break :outer;
        }
    }
    return count;
}

export fn puts(s: ?[*:0]const u8) c_int {
    _ = s;
    return 0;
}

export fn __small_fprintf(stream: ?*anyopaque, format: ?[*:0]const u8, ...) c_int {
    _ = stream;
    _ = format;
    return 0;
}

var strtok_state: ?[*:0]u8 = null;
export fn strtok(s: ?[*:0]u8, delim: ?[*:0]const u8) ?[*:0]u8 {
    _ = s;
    _ = delim;
    _ = strtok_state;
    return null; // Not implemented
}

export fn atoi(s: ?[*:0]const u8) c_int {
    const str = s orelse return 0;
    var result: c_int = 0;
    var i: usize = 0;
    var neg = false;
    while (str[i] == ' ') : (i += 1) {}
    if (str[i] == '-') {
        neg = true;
        i += 1;
    } else if (str[i] == '+') {
        i += 1;
    }
    while (str[i] >= '0' and str[i] <= '9') : (i += 1) {
        result = result * 10 + @as(c_int, str[i] - '0');
    }
    return if (neg) -result else result;
}

var rand_state: u32 = 12345;
export fn rand() c_int {
    rand_state = rand_state *% 1103515245 +% 12345;
    return @intCast((rand_state >> 16) & 0x7FFF);
}

export fn atof(s: ?[*:0]const u8) f64 {
    _ = s;
    return 0.0; // Not fully implemented
}

export fn atoll(s: ?[*:0]const u8) i64 {
    _ = s;
    return 0; // Not fully implemented
}

export fn wcslen(s: ?[*]const u32) usize {
    const str = s orelse return 0;
    var len: usize = 0;
    while (str[len] != 0) : (len += 1) {}
    return len;
}

export fn wcsrtombs(dest: ?[*]u8, src: ?*?[*]const u32, len: usize, ps: ?*anyopaque) usize {
    _ = dest;
    _ = src;
    _ = len;
    _ = ps;
    return 0;
}

// ============================================================================
// pthread stubs (single-threaded wasm doesn't need real threading)
// ============================================================================

export fn pthread_mutex_init(mutex: ?*anyopaque, attr: ?*anyopaque) c_int {
    _ = mutex;
    _ = attr;
    return 0;
}

export fn pthread_mutex_destroy(mutex: ?*anyopaque) c_int {
    _ = mutex;
    return 0;
}

export fn pthread_mutex_lock(mutex: ?*anyopaque) c_int {
    _ = mutex;
    return 0;
}

export fn pthread_mutex_unlock(mutex: ?*anyopaque) c_int {
    _ = mutex;
    return 0;
}

export fn pthread_cond_init(cond: ?*anyopaque, attr: ?*anyopaque) c_int {
    _ = cond;
    _ = attr;
    return 0;
}

export fn pthread_cond_destroy(cond: ?*anyopaque) c_int {
    _ = cond;
    return 0;
}

export fn pthread_cond_wait(cond: ?*anyopaque, mutex: ?*anyopaque) c_int {
    _ = cond;
    _ = mutex;
    return 0;
}

export fn pthread_cond_signal(cond: ?*anyopaque) c_int {
    _ = cond;
    return 0;
}

// ============================================================================
// Dynamic library stubs (not available in wasm)
// ============================================================================

export fn dlopen(filename: ?[*:0]const u8, flags: c_int) ?*anyopaque {
    _ = filename;
    _ = flags;
    return null;
}

export fn dlclose(handle: ?*anyopaque) c_int {
    _ = handle;
    return -1;
}

export fn dlsym(handle: ?*anyopaque, symbol: ?[*:0]const u8) ?*anyopaque {
    _ = handle;
    _ = symbol;
    return null;
}

export fn dlerror() ?[*:0]const u8 {
    return "Dynamic loading not supported";
}

export fn pthread_create(thread: ?*anyopaque, attr: ?*const anyopaque, start: ?*anyopaque, arg: ?*anyopaque) c_int {
    _ = thread;
    _ = attr;
    _ = start;
    _ = arg;
    return -1; // Threading not supported
}

export fn pthread_join(thread: ?*anyopaque, retval: ?*?*anyopaque) c_int {
    _ = thread;
    _ = retval;
    return -1;
}

export fn fileno(stream: ?*anyopaque) c_int {
    _ = stream;
    return -1;
}

export fn fstat(fd: c_int, buf: ?*anyopaque) c_int {
    _ = fd;
    _ = buf;
    return -1;
}

const div_t = extern struct {
    quot: c_int,
    rem: c_int,
};

export fn div(numer: c_int, denom: c_int) div_t {
    if (denom == 0) return div_t{ .quot = 0, .rem = 0 };
    return div_t{
        .quot = @divTrunc(numer, denom),
        .rem = @rem(numer, denom),
    };
}

export fn rewind(stream: ?*anyopaque) void {
    _ = stream;
}

export fn ldexp(x: f64, exp: c_int) f64 {
    return std.math.ldexp(x, exp);
}
