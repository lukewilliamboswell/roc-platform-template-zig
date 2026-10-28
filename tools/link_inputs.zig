//! Fetch the content-addressed linker-input release once; check and stage it offline.
//!
//! Usage (run from the repository root; `zig build` does this):
//!   link_inputs fetch                  download or reuse the locked archive
//!   link_inputs check                  verify the cache matches the lock
//!   link_inputs stage                  check, then copy target files into platform/targets
//!   link_inputs verify-archive <path>  validate an archive and print its manifest version
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const json = std.json;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const max_archive: u64 = 256 * 1024 * 1024;
pub const max_unpacked: u64 = 512 * 1024 * 1024;
const cache_root = ".zig-cache/linker-inputs";
const repository = "lukewilliamboswell/roc-platform-template-zig";

/// Human-readable reason for the most recent `error.Invalid`.
var message: []const u8 = "";
var message_buffer: [512]u8 = undefined;

fn fail(comptime fmt: []const u8, args: anytype) error{Invalid} {
    message = std.fmt.bufPrint(&message_buffer, fmt, args) catch fmt;
    return error.Invalid;
}

// ---------------------------------------------------------------- validation helpers

fn isLowerHex(s: []const u8, len: usize) bool {
    if (s.len != len) return false;
    for (s) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn isSha256(s: ?[]const u8) bool {
    return if (s) |v| isLowerHex(v, 64) else false;
}

fn isCommit(s: ?[]const u8) bool {
    return if (s) |v| isLowerHex(v, 40) else false;
}

fn isVersionPart(p: []const u8) bool {
    if (p.len == 0) return false;
    if (p[0] == '0') return p.len == 1;
    for (p) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Matches `(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)`.
fn isVersion(s: ?[]const u8) bool {
    const v = s orelse return false;
    var it = std.mem.splitScalar(u8, v, '.');
    var n: usize = 0;
    while (it.next()) |p| : (n += 1) if (n >= 3 or !isVersionPart(p)) return false;
    return n == 3;
}

/// A relative, normalised POSIX path with no `\`, `:`, empty, `.` or `..` parts.
pub fn safeName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.indexOfAny(u8, name, "\\:") != null) return false;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn hexDigest(data: []const u8) [64]u8 {
    var out: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &out, .{});
    return std.fmt.bytesToHex(out, .lower);
}

fn object(v: ?json.Value) ?json.ObjectMap {
    const value = v orelse return null;
    return switch (value) {
        .object => |o| o,
        else => null,
    };
}

fn string(o: ?json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = (o orelse return null).get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn integer(o: json.ObjectMap, key: []const u8) ?i64 {
    return switch (o.get(key) orelse return null) {
        .integer => |i| i,
        else => null,
    };
}

fn keysAre(o: ?json.ObjectMap, keys: []const []const u8) bool {
    const map = o orelse return false;
    if (map.count() != keys.len) return false;
    for (keys) |k| if (!map.contains(k)) return false;
    return true;
}

fn eql(a: ?[]const u8, b: []const u8) bool {
    return if (a) |v| std.mem.eql(u8, v, b) else false;
}

// ---------------------------------------------------------------- lock

pub const Lock = struct {
    url: []const u8,
    sha256: []const u8,
    size: u64,
    source_commit: []const u8,
    input_fingerprint: []const u8,
};

pub fn parseLock(arena: Allocator, bytes: []const u8) error{ Invalid, OutOfMemory }!Lock {
    const invalid = "Invalid content-addressed linker-input lock";
    const root = json.parseFromSliceLeaky(json.Value, arena, bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(invalid, .{}),
    };
    const lock = object(root);
    if (!keysAre(lock, &.{ "schema_version", "kind", "repository", "release", "manifest", "source", "targets" }))
        return fail(invalid, .{});
    const l = lock.?;
    const targets = object(l.get("targets"));
    const record = object(if (targets) |t| t.get("all") else null);
    const source = object(l.get("source"));
    const release = string(l, "release") orelse "";
    const repo = string(l, "repository") orelse "";
    const workflow = try std.fmt.allocPrint(arena, "{s}/.github/workflows/linker-inputs.yml", .{repo});
    const size = if (record) |r| integer(r, "size") else null;
    if (!eql(string(l, "kind"), "roc-zig-link-inputs") or
        !std.mem.eql(u8, repo, repository) or
        !std.mem.startsWith(u8, release, "link-inputs-sha256-") or
        !isSha256(release["link-inputs-sha256-".len..]) or
        !keysAre(targets, &.{"all"}) or
        !keysAre(record, &.{ "asset", "sha256", "size" }) or
        !eql(string(record, "asset"), "link-inputs-all.tar") or
        !isSha256(string(record, "sha256")) or
        size == null or size.? <= 0 or
        !eql(string(source, "repository"), repo) or
        !eql(string(source, "workflow"), workflow) or
        !isCommit(string(source, "sha")) or
        !isSha256(string(source, "input_fingerprint")))
        return fail(invalid, .{});
    return .{
        .url = try std.fmt.allocPrint(arena, "https://github.com/{s}/releases/download/{s}/{s}", .{
            repo, release, string(record, "asset").?,
        }),
        .sha256 = string(record, "sha256").?,
        .size = @intCast(size.?),
        .source_commit = string(source, "sha").?,
        .input_fingerprint = string(source, "input_fingerprint").?,
    };
}

fn loadLock(arena: Allocator, io: Io) !Lock {
    const cwd = Dir.cwd();
    for ([_][]const u8{ "linker-inputs.lock.json", "link-inputs.lock.json" }) |name| {
        const bytes = cwd.readFileAlloc(io, name, arena, .limited(1024 * 1024)) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };
        return parseLock(arena, bytes);
    }
    return fail("No aggregate linker-input release is pinned yet; see linker-inputs/README.md", .{});
}

fn cachePath(arena: Allocator, lock: Lock) ![]const u8 {
    return std.fmt.allocPrint(arena, cache_root ++ "/{s}", .{lock.sha256});
}

// ---------------------------------------------------------------- archive

pub const Archive = struct {
    version: []const u8,
    source_commit: []const u8,
    input_fingerprint: []const u8,
    /// Member name -> contents, in archive order (includes dependency.json).
    files: std.StringArrayHashMapUnmanaged([]const u8),
};

/// Validate an archive (plain or gzip-compressed tar) held in memory.
pub fn readArchiveBytes(arena: Allocator, bytes: []const u8) error{ Invalid, OutOfMemory }!Archive {
    if (bytes.len > max_archive) return fail("Linker-input archive exceeds size limit", .{});
    var input: Io.Reader = .fixed(bytes);
    var decompress_buffer: []u8 = &.{};
    var decompress: std.compress.flate.Decompress = undefined;
    const reader: *Io.Reader = if (bytes.len >= 2 and bytes[0] == 0x1f and bytes[1] == 0x8b) blk: {
        decompress_buffer = try arena.alloc(u8, std.compress.flate.max_window_len);
        decompress = .init(&input, .gzip, decompress_buffer);
        break :blk &decompress.reader;
    } else &input;

    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(reader, .{ .file_name_buffer = &name_buffer, .link_name_buffer = &link_buffer });
    var files: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var total: u64 = 0;
    while (true) {
        const member = (it.next() catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return fail("Unreadable linker-input archive: {t}", .{e}),
        }) orelse break;
        if (member.kind != .file or !safeName(member.name) or files.contains(member.name))
            return fail("Unsafe or duplicate archive entry: {s}", .{member.name});
        total += member.size;
        if (total > max_unpacked) return fail("Linker-input archive exceeds unpacked size limit", .{});
        const data = try arena.alloc(u8, @intCast(member.size));
        reader.readSliceAll(data) catch return fail("Missing archive data: {s}", .{member.name});
        it.unread_file_bytes = 0;
        try files.put(arena, try arena.dupe(u8, member.name), data);
    }

    const manifest_bytes = files.get("dependency.json") orelse
        return fail("Linker-input archive has no dependency.json", .{});
    const invalid = "Invalid linker-input dependency manifest";
    const root = json.parseFromSliceLeaky(json.Value, arena, manifest_bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(invalid, .{}),
    };
    const manifest = object(root) orelse return fail(invalid, .{});
    const schema = integer(manifest, "schema");
    const records = object(manifest.get("files"));
    if (schema == null or schema.? != 1 or
        !isVersion(string(manifest, "version")) or
        !isCommit(string(manifest, "source_commit")) or
        !isSha256(string(manifest, "input_fingerprint")) or
        records == null or records.?.count() != files.count() - 1)
        return fail(invalid, .{});
    for (files.keys()) |name| {
        if (std.mem.eql(u8, name, "dependency.json")) continue;
        if (!records.?.contains(name)) return fail(invalid, .{});
    }
    for (files.keys(), files.values()) |name, data| {
        if (std.mem.eql(u8, name, "dependency.json")) continue;
        const record = object(records.?.get(name));
        const size = if (record) |r| integer(r, "size") else null;
        if (!keysAre(record, &.{ "sha256", "size" }) or size == null or size.? != data.len or
            !eql(string(record, "sha256"), &hexDigest(data)))
            return fail("Linker-input integrity failure: {s}", .{name});
    }
    return .{
        .version = string(manifest, "version").?,
        .source_commit = string(manifest, "source_commit").?,
        .input_fingerprint = string(manifest, "input_fingerprint").?,
        .files = files,
    };
}

pub fn readArchive(arena: Allocator, io: Io, dir: Dir, path: []const u8) !Archive {
    const stat = try dir.statFile(io, path, .{});
    if (stat.size > max_archive) return fail("Linker-input archive exceeds size limit", .{});
    const bytes = try dir.readFileAlloc(io, path, arena, .limited(max_archive + 1));
    return readArchiveBytes(arena, bytes);
}

// ---------------------------------------------------------------- commands

const Checked = struct { tree: []const u8, archive: Archive };

fn check(arena: Allocator, io: Io, lock: Lock) !Checked {
    const cwd = Dir.cwd();
    const directory = try cachePath(arena, lock);
    const archive_path = try std.fmt.allocPrint(arena, "{s}/archive.tar.gz", .{directory});
    const stat = cwd.statFile(io, archive_path, .{}) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return fail("Linker inputs are missing. Run: zig build fetch-link-inputs", .{}),
        else => return e,
    };
    if (stat.kind != .file) return fail("Linker inputs are missing. Run: zig build fetch-link-inputs", .{});
    if (stat.size != lock.size) return fail("Cached linker-input archive does not match the lock", .{});
    const bytes = try cwd.readFileAlloc(io, archive_path, arena, .limited(max_archive + 1));
    if (!std.mem.eql(u8, &hexDigest(bytes), lock.sha256))
        return fail("Cached linker-input archive does not match the lock", .{});
    const archive = try readArchiveBytes(arena, bytes);
    if (!std.mem.eql(u8, archive.source_commit, lock.source_commit))
        return fail("Archive dependency metadata does not match the lock", .{});

    const tree = try std.fmt.allocPrint(arena, "{s}/tree", .{directory});
    try checkTree(arena, io, cwd, tree, archive);
    return .{ .tree = tree, .archive = archive };
}

/// The staged tree must hold exactly the archive's files, byte for byte, and no symlinks.
fn checkTree(arena: Allocator, io: Io, base: Dir, tree: []const u8, archive: Archive) !void {
    const inventory = "Unexpected staged linker-input inventory";
    var tree_dir = base.openDir(io, tree, .{ .iterate = true, .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir, error.SymLinkLoop => return fail(inventory, .{}),
        else => return e,
    };
    defer tree_dir.close(io);
    var walker = try tree_dir.walk(arena);
    defer walker.deinit();
    var seen: usize = 0;
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => {},
        .file => {
            const name = try arena.dupe(u8, entry.path);
            if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, name, std.fs.path.sep, '/');
            if (!archive.files.contains(name)) return fail(inventory, .{});
            seen += 1;
        },
        // Symlinks and special files are never part of a staged tree.
        else => return fail(inventory, .{}),
    };
    if (seen != archive.files.count()) return fail(inventory, .{});
    for (archive.files.keys(), archive.files.values()) |name, data| {
        const actual = try tree_dir.readFileAlloc(io, name, arena, .limited(data.len + 1));
        if (!std.mem.eql(u8, actual, data)) return fail("Staged linker input differs from archive: {s}", .{name});
    }
}

fn download(arena: Allocator, io: Io, environ: *const std.process.Environ.Map, url: []const u8, dir: Dir, path: []const u8) !void {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    try client.initDefaultProxies(arena, environ);
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer.interface,
        .redirect_behavior = .init(5),
    });
    try writer.interface.flush();
    if (result.status != .ok) return fail("Download failed with HTTP {d}: {s}", .{ @backingInt(result.status), url });
}

fn fetch(arena: Allocator, io: Io, environ: *const std.process.Environ.Map) !void {
    const cwd = Dir.cwd();
    const lock = try loadLock(arena, io);
    const destination = try cachePath(arena, lock);
    try cwd.createDirPath(io, cache_root);
    if (cwd.access(io, destination, .{})) |_| {
        if (check(arena, io, lock)) |_| {
            try stdoutPrint(io, "Reused content-hashed linker inputs from the verified cache\n");
            return;
        } else |_| {}
    } else |_| {}

    var random: [8]u8 = undefined;
    io.random(&random);
    const temporary = try std.fmt.allocPrint(arena, cache_root ++ "/linker-input-download-{x}", .{&random});
    try cwd.createDir(io, temporary, .default_dir);
    defer cwd.deleteTree(io, temporary) catch {};
    {
        var directory = try cwd.openDir(io, temporary, .{});
        defer directory.close(io);

        try download(arena, io, environ, lock.url, directory, "archive.tar.gz");
        const bytes = try directory.readFileAlloc(io, "archive.tar.gz", arena, .limited(max_archive + 1));
        if (bytes.len != lock.size or !std.mem.eql(u8, &hexDigest(bytes), lock.sha256))
            return fail("Downloaded linker inputs do not match the lock", .{});
        const archive = try readArchiveBytes(arena, bytes);
        for (archive.files.keys(), archive.files.values()) |name, data| {
            const path = try std.fmt.allocPrint(arena, "tree/{s}", .{name});
            if (std.fs.path.dirnamePosix(path)) |parent| try directory.createDirPath(io, parent);
            try directory.writeFile(io, .{ .sub_path = path, .data = data });
        }
        if (!std.mem.eql(u8, archive.source_commit, lock.source_commit))
            return fail("Downloaded dependency metadata does not match the lock", .{});
    }

    const backup = try std.fmt.allocPrint(arena, "{s}.previous", .{destination});
    if (cwd.access(io, backup, .{})) |_| {
        return fail("Interrupted linker-input installation found: {s}", .{backup});
    } else |_| {}
    const had_destination = if (cwd.access(io, destination, .{})) |_| true else |_| false;
    if (had_destination) try cwd.rename(destination, cwd, backup, io);
    cwd.rename(temporary, cwd, destination, io) catch |e| {
        if (had_destination) cwd.rename(backup, cwd, destination, io) catch {};
        return e;
    };
    if (had_destination) try cwd.deleteTree(io, backup);
    _ = try check(arena, io, lock);
}

const mappings = [_][2][]const u8{
    .{ "x64musl", "x64musl" },     .{ "x64v1musl", "x64musl" },
    .{ "arm64musl", "arm64musl" }, .{ "arm64v1musl", "arm64musl" },
    .{ "x64mac", "x64mac" },       .{ "arm64mac", "arm64mac" },
    .{ "x64win", "x64win" },
};

fn stage(arena: Allocator, io: Io) !void {
    const cwd = Dir.cwd();
    const lock = try loadLock(arena, io);
    const checked = try check(arena, io, lock);
    for (mappings) |mapping| {
        const source_path = try std.fmt.allocPrint(arena, "{s}/targets/{s}", .{ checked.tree, mapping[1] });
        const destination_path = try std.fmt.allocPrint(arena, "platform/targets/{s}", .{mapping[0]});
        var source = try cwd.openDir(io, source_path, .{ .iterate = true });
        defer source.close(io);
        var destination = try cwd.createDirPathOpen(io, destination_path, .{});
        defer destination.close(io);
        var it = source.iterate();
        while (try it.next(io)) |item| {
            if (item.kind != .file)
                return fail("Invalid linker-input staging source: {s}/{s}", .{ source_path, item.name });
            const data = try source.readFileAlloc(io, item.name, arena, .limited(max_unpacked));
            var atomic = try destination.createFileAtomic(io, item.name, .{ .replace = true });
            defer atomic.deinit(io);
            try atomic.file.writeStreamingAll(io, data);
            try atomic.replace(io);
        }
    }
}

fn stdoutPrint(io: Io, bytes: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, bytes);
}

const usage =
    \\usage: link_inputs {fetch,check,stage,verify-archive <path>}
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        Io.File.stderr().writeStreamingAll(io, usage) catch {};
        std.process.exit(2);
    }
    const command = args[1];
    run(arena, io, init.environ_map, command, args[2..]) catch |e| {
        const text = if (e == error.Invalid)
            message
        else
            std.fmt.allocPrint(arena, "linker inputs: {t}", .{e}) catch "linker inputs: error";
        Io.File.stderr().writeStreamingAll(io, text) catch {};
        Io.File.stderr().writeStreamingAll(io, "\n") catch {};
        std.process.exit(1);
    };
}

fn run(arena: Allocator, io: Io, environ: *const std.process.Environ.Map, command: []const u8, rest: []const []const u8) !void {
    if (std.mem.eql(u8, command, "fetch") and rest.len == 0) {
        try fetch(arena, io, environ);
        try stdoutPrint(io, "Verified linker inputs installed; builds now work offline\n");
    } else if (std.mem.eql(u8, command, "check") and rest.len == 0) {
        _ = try check(arena, io, try loadLock(arena, io));
        try stdoutPrint(io, "Linker inputs match the signed lock\n");
    } else if (std.mem.eql(u8, command, "stage") and rest.len == 0) {
        try stage(arena, io);
    } else if (std.mem.eql(u8, command, "verify-archive") and rest.len == 1) {
        const archive = try readArchive(arena, io, Dir.cwd(), rest[0]);
        try stdoutPrint(io, try std.fmt.allocPrint(arena, "{s}\n", .{archive.version}));
    } else {
        Io.File.stderr().writeStreamingAll(io, usage) catch {};
        std.process.exit(2);
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Member = struct { name: []const u8, data: []const u8 = "" };

fn tarBytes(arena: Allocator, members: []const Member) ![]u8 {
    var out: Io.Writer.Allocating = .init(arena);
    var w: std.tar.Writer = .{ .underlying_writer = &out.writer };
    for (members) |m| try w.writeFileBytes(m.name, m.data, .{ .mode = 0o644 });
    try w.finishPedantically();
    return out.toOwnedSlice();
}

fn gzip(arena: Allocator, data: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = try .initCapacity(arena, 64);
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    var compress = try std.compress.flate.Compress.init(&out.writer, window, .gzip, .default);
    try compress.writer.writeAll(data);
    try compress.finish();
    return out.toOwnedSlice();
}

const payload_name = "targets/x64mac/libSystem.tbd";

fn manifestJson(arena: Allocator, data: []const u8, extra_file: ?[]const u8) ![]u8 {
    const extra = if (extra_file) |n| try std.fmt.allocPrint(arena, ",\"{s}\":{{\"sha256\":\"{s}\",\"size\":0}}", .{ n, &hexDigest("") }) else "";
    return std.fmt.allocPrint(arena,
        \\{{"schema":1,"version":"1.0.0","source_commit":"{s}","input_fingerprint":"{s}","files":{{"{s}":{{"sha256":"{s}","size":{d}}}{s}}}}}
    , .{ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", payload_name, &hexDigest(data), data.len, extra });
}

fn fixture(arena: Allocator, data: []const u8, stored: []const u8) ![]u8 {
    return tarBytes(arena, &.{
        .{ .name = "dependency.json", .data = try manifestJson(arena, data, null) },
        .{ .name = payload_name, .data = stored },
    });
}

fn expectInvalid(result: anytype, needle: []const u8) !void {
    try testing.expectError(error.Invalid, result);
    if (std.mem.indexOf(u8, message, needle) == null) {
        std.debug.print("message [{s}] lacks [{s}]\n", .{ message, needle });
        return error.TestUnexpectedResult;
    }
}

test "valid archive round-trips, plain and gzip" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const tar = try fixture(arena, "stub", "stub");
    for ([_][]const u8{ tar, try gzip(arena, tar) }) |bytes| {
        const archive = try readArchiveBytes(arena, bytes);
        try testing.expectEqualStrings("1.0.0", archive.version);
        try testing.expectEqualStrings("stub", archive.files.get(payload_name).?);
        try testing.expectEqual(@as(usize, 2), archive.files.count());
    }
}

test "rejects unsafe member names" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    for ([_][]const u8{ "../escape", "/absolute", "C:/escape", "a\\b", "a/./b", "a//b", "a/" }) |name| {
        const bytes = try gzip(arena, try tarBytes(arena, &.{.{ .name = name }}));
        try expectInvalid(readArchiveBytes(arena, bytes), "Unsafe or duplicate archive entry");
    }
    try testing.expect(safeName("targets/x64mac/libSystem.tbd"));
    try testing.expect(!safeName(""));
}

test "rejects duplicate members and non-files" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const dup = try tarBytes(arena, &.{ .{ .name = "x" }, .{ .name = "x" } });
    try expectInvalid(readArchiveBytes(arena, dup), "Unsafe or duplicate archive entry: x");

    var out: Io.Writer.Allocating = .init(arena);
    var w: std.tar.Writer = .{ .underlying_writer = &out.writer };
    try w.writeDir("d", .{});
    try w.finishPedantically();
    try expectInvalid(readArchiveBytes(arena, out.written()), "Unsafe or duplicate archive entry");
}

test "rejects tampered payload (digest and size mismatch)" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    try expectInvalid(readArchiveBytes(arena, try fixture(arena, "stub", "tamp")), "integrity");
    try expectInvalid(readArchiveBytes(arena, try fixture(arena, "stub", "tampered")), "integrity");
}

test "rejects manifest/file-set mismatch and bad manifests" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    // Manifest lists a file the archive lacks.
    const missing = try tarBytes(arena, &.{
        .{ .name = "dependency.json", .data = try manifestJson(arena, "stub", "extra") },
        .{ .name = payload_name, .data = "stub" },
    });
    try expectInvalid(readArchiveBytes(arena, missing), "dependency manifest");
    // Archive holds a file the manifest does not list.
    const unlisted = try tarBytes(arena, &.{
        .{ .name = "dependency.json", .data = try manifestJson(arena, "stub", null) },
        .{ .name = payload_name, .data = "stub" },
        .{ .name = "extra" },
    });
    try expectInvalid(readArchiveBytes(arena, unlisted), "dependency manifest");
    const no_manifest = try tarBytes(arena, &.{.{ .name = payload_name, .data = "stub" }});
    try expectInvalid(readArchiveBytes(arena, no_manifest), "no dependency.json");
    const bad_version = try tarBytes(arena, &.{.{ .name = "dependency.json", .data =
        \\{"schema":1,"version":"01.0.0","source_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","input_fingerprint":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","files":{}}
    }});
    try expectInvalid(readArchiveBytes(arena, bad_version), "dependency manifest");
    const not_json = try tarBytes(arena, &.{.{ .name = "dependency.json", .data = "nope" }});
    try expectInvalid(readArchiveBytes(arena, not_json), "dependency manifest");
}

test "oversized archive is rejected" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    // Never dereferenced: the length check comes first.
    const huge: []const u8 = @as([*]const u8, @ptrFromInt(0x1000))[0 .. max_archive + 1];
    try expectInvalid(readArchiveBytes(state.allocator(), huge), "exceeds size limit");
}

const good_lock =
    \\{"schema_version":1,"kind":"roc-zig-link-inputs","repository":"lukewilliamboswell/roc-platform-template-zig",
    \\"release":"link-inputs-sha256-2889e4c509a3a247cb2d38ae1400ea71f87ec79c6d6cec58cd7a953e051bdf08",
    \\"manifest":{"asset":"build-input-release.json","sha256":"2889e4c509a3a247cb2d38ae1400ea71f87ec79c6d6cec58cd7a953e051bdf08"},
    \\"source":{"input_fingerprint":"a0a3a4bd00e19228089ae1fcab72f5760e75d373a994db82c391f27560283001","ref":"refs/heads/x",
    \\"repository":"lukewilliamboswell/roc-platform-template-zig","sha":"5db8f9b9e661f5cbde0254d3520366ef4eab8bd4",
    \\"workflow":"lukewilliamboswell/roc-platform-template-zig/.github/workflows/linker-inputs.yml"},
    \\"targets":{"all":{"asset":"link-inputs-all.tar","sha256":"a057de193f8c1f6e7f3bfc6f1999853e6c2a868567913af9384d7ecb99c5462a","size":8253440}}}
;

test "parses a valid lock" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const lock = try parseLock(state.allocator(), good_lock);
    try testing.expectEqual(@as(u64, 8253440), lock.size);
    try testing.expectEqualStrings(
        "https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/download/link-inputs-sha256-2889e4c509a3a247cb2d38ae1400ea71f87ec79c6d6cec58cd7a953e051bdf08/link-inputs-all.tar",
        lock.url,
    );
}

test "rejects malformed locks" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const Swap = struct { []const u8, []const u8 };
    const cases = [_]Swap{
        .{ "\"size\":8253440", "\"size\":0" },
        .{ "\"size\":8253440", "\"size\":\"1\"" },
        .{ "\"kind\":\"roc-zig-link-inputs\"", "\"kind\":\"other\"" },
        .{ "link-inputs-all.tar", "link-inputs-x.tar" },
        .{ "\"sha\":\"5db8", "\"sha\":\"XXXX" },
        .{ "\"schema_version\":1,", "" },
        .{ "\"schema_version\":1,", "\"schema_version\":1,\"extra\":1," },
        .{ "linker-inputs.yml", "other.yml" },
        .{ "release\":\"link-inputs-sha256-2889", "release\":\"link-inputs-sha256-ZZZZ" },
        .{ "{\"all\":", "{\"x64\":" },
    };
    for (cases) |case| {
        const bad = try std.mem.replaceOwned(u8, arena, good_lock, case[0], case[1]);
        try testing.expect(!std.mem.eql(u8, bad, good_lock));
        try expectInvalid(parseLock(arena, bad), "Invalid content-addressed linker-input lock");
    }
    try expectInvalid(parseLock(arena, "[]"), "Invalid content-addressed");
    try expectInvalid(parseLock(arena, "{"), "Invalid content-addressed");
}

test "staged-tree inventory check" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const io = testing.io;
    const archive = try readArchiveBytes(arena, try fixture(arena, "stub", "stub"));
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try expectInvalid(checkTree(arena, io, tmp.dir, "tree", archive), "inventory");
    for (archive.files.keys(), archive.files.values()) |name, data| {
        const path = try std.fmt.allocPrint(arena, "tree/{s}", .{name});
        if (std.fs.path.dirnamePosix(path)) |p| try tmp.dir.createDirPath(io, p);
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = data });
    }
    try checkTree(arena, io, tmp.dir, "tree", archive);
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/" ++ payload_name, .data = "diff" });
    try expectInvalid(checkTree(arena, io, tmp.dir, "tree", archive), "differs from archive");
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/" ++ payload_name, .data = "stub" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/extra", .data = "" });
    try expectInvalid(checkTree(arena, io, tmp.dir, "tree", archive), "inventory");
}
