//! First-class workspaces: a named folder plus the conversations tagged
//! with that workspace id.
//!
//! Sessions still live in the serve instance's `state/sessions/`; this file
//! is the registry that binds an id to a directory the files browser and
//! the agent sandbox may use. The empty id is the implicit default
//! (process cwd) and is never stored. There is no count cap.

const std = @import("std");
const ensure_dir = @import("../util/ensure_dir.zig");
const file_lock = @import("../util/file_lock.zig");
const atomic_write = @import("../util/atomic_write.zig");
const log = @import("../util/log.zig");

pub const state_dir = "state";
pub const store_path = "state/workspaces.json";
pub const max_store_bytes: usize = 1 << 20;
pub const max_path_bytes: usize = 4096;
pub const max_name_len: usize = 64;

pub const Error = error{
    BadName,
    BadPath,
    NotADirectory,
    Duplicate,
    NoSuchWorkspace,
    Builtin,
};

pub const Workspace = struct {
    id: []const u8,
    name: []const u8,
    path: []const u8,
    created: i64 = 0,
};

/// A workspace id is what sessions store. No separators, no controls, so the
/// rail cannot lie about nesting and the id can never be a path. HTTP and
/// session-tag callers that allow the empty default workspace wrap this.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    for (name) |c| {
        if (c < 0x20 or c == 0x7f) return false;
        if (c == '/' or c == '\\') return false;
    }
    return true;
}

pub fn validPath(path: []const u8) bool {
    if (path.len == 0 or path.len > max_path_bytes) return false;
    return std.mem.indexOfScalar(u8, path, 0) == null;
}

pub fn find(list: []const Workspace, id: []const u8) ?*const Workspace {
    for (list) |*w| {
        if (std.mem.eql(u8, w.id, id)) return w;
    }
    return null;
}

pub fn findMut(list: []Workspace, id: []const u8) ?*Workspace {
    for (list) |*w| {
        if (std.mem.eql(u8, w.id, id)) return w;
    }
    return null;
}

/// Reads the registry. A missing or unparseable file is an empty list.
pub fn load(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir) ![]Workspace {
    const raw = base.readFileAlloc(io, store_path, arena, .limited(max_store_bytes)) catch return &.{};
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return &.{};
    return std.json.parseFromSliceLeaky([]Workspace, arena, trimmed, .{ .ignore_unknown_fields = true }) catch {
        log.log(.warn, "workspaces: {s} is not a readable list; treating it as empty", .{store_path});
        return &.{};
    };
}

pub fn save(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir, list: []const Workspace) !void {
    ensure_dir.ensureDir(base, io, state_dir) catch |err| {
        log.log(.warn, "workspaces: could not create {s}: {s}", .{ state_dir, @errorName(err) });
    };
    var enc: std.Io.Writer.Allocating = .init(arena);
    defer enc.deinit();
    var s = std.json.Stringify{ .writer = &enc.writer, .options = .{ .whitespace = .indent_2, .emit_null_optional_fields = false } };
    try s.write(list);
    try enc.writer.writeByte('\n');
    try atomic_write.writeFile(io, base, store_path, enc.written());
}

/// Turns a typed path into an absolute real path that names a directory.
pub fn resolveDir(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (!validPath(path)) return Error.BadPath;
    const abs = std.Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch return Error.NotADirectory;
    const st = std.Io.Dir.cwd().statFile(io, abs, .{}) catch return Error.NotADirectory;
    if (st.kind != .directory) return Error.NotADirectory;
    return abs;
}

/// Absolute path of the process cwd, or "." if it cannot be resolved.
pub fn cwdPath(io: std.Io, arena: std.mem.Allocator) []const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena) catch ".";
}

/// Basename of `path` for a default label.
pub fn basenameOf(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (trimmed.len == 0) return path;
    if (std.mem.findScalarLast(u8, trimmed, '/')) |slash| return trimmed[slash + 1 ..];
    return trimmed;
}

pub fn nextId(arena: std.mem.Allocator, list: []const Workspace, name: []const u8) ![]const u8 {
    if (validName(name) and find(list, name) == null) return name;
    var n: u32 = 1;
    while (n < 10_000) : (n += 1) {
        const id = try std.fmt.allocPrint(arena, "ws-{d}", .{n});
        if (find(list, id) == null) return id;
    }
    return Error.Duplicate;
}

/// Appends a workspace. Caller holds no lock; this takes one for the
/// read-modify-write.
pub fn add(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    name: []const u8,
    path: []const u8,
    now: i64,
) !Workspace {
    if (!validName(name)) return Error.BadName;
    const abs = try resolveDir(io, arena, path);
    var guard = file_lock.acquire(io, base, state_dir, "workspaces", gpa);
    defer guard.release();
    var list: std.ArrayList(Workspace) = .empty;
    list.appendSlice(arena, try load(io, arena, base)) catch return error.OutOfMemory;
    if (find(list.items, name) != null) return Error.Duplicate;
    const id = try nextId(arena, list.items, name);
    const ws = Workspace{ .id = id, .name = name, .path = abs, .created = now };
    list.append(arena, ws) catch return error.OutOfMemory;
    try save(io, arena, base, list.items);
    return ws;
}

pub fn update(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    id: []const u8,
    name: ?[]const u8,
    path: ?[]const u8,
) !Workspace {
    if (id.len == 0) return Error.Builtin;
    if (!validName(id)) return Error.BadName;
    var guard = file_lock.acquire(io, base, state_dir, "workspaces", gpa);
    defer guard.release();
    const loaded = try load(io, arena, base);
    var list: std.ArrayList(Workspace) = .empty;
    list.appendSlice(arena, loaded) catch return error.OutOfMemory;
    const slot = findMut(list.items, id) orelse return Error.NoSuchWorkspace;
    if (name) |n| {
        if (!validName(n)) return Error.BadName;
        slot.name = n;
    }
    if (path) |p| {
        slot.path = try resolveDir(io, arena, p);
    }
    try save(io, arena, base, list.items);
    return slot.*;
}

/// Drops the registry row. Sessions keep the tag until the caller reassigns
/// them; this function does not touch session files.
pub fn remove(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    id: []const u8,
) !void {
    if (id.len == 0) return Error.Builtin;
    if (!validName(id)) return Error.BadName;
    var guard = file_lock.acquire(io, base, state_dir, "workspaces", gpa);
    defer guard.release();
    const loaded = try load(io, arena, base);
    var list: std.ArrayList(Workspace) = .empty;
    var found = false;
    for (loaded) |w| {
        if (std.mem.eql(u8, w.id, id)) {
            found = true;
            continue;
        }
        list.append(arena, w) catch return error.OutOfMemory;
    }
    if (!found) return Error.NoSuchWorkspace;
    try save(io, arena, base, list.items);
}

/// Path the files browser and a run should use for `id`. Null means the
/// process cwd (default workspace, or a label with no registered folder).
pub fn pathFor(list: []const Workspace, id: []const u8) ?[]const u8 {
    if (id.len == 0) return null;
    const ws = find(list, id) orelse return null;
    if (ws.path.len == 0) return null;
    return ws.path;
}

// ------------------------------------------------------------------ tests --

test "validName rejects empty, separators, and oversize" {
    try std.testing.expect(!validName(""));
    try std.testing.expect(validName("research"));
    try std.testing.expect(validName("web ui"));
    try std.testing.expect(!validName("a/b"));
    try std.testing.expect(!validName("a\\b"));
    try std.testing.expect(!validName("a\nb"));
    try std.testing.expect(!validName("x" ** 65));
}

test "workspace registry create list update remove" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(io, "proj-a");
    try tmp.dir.createDirPath(io, "proj-b");
    const a_path = try tmp.dir.realPathFileAlloc(io, "proj-a", arena);
    const b_path = try tmp.dir.realPathFileAlloc(io, "proj-b", arena);

    const first = try add(io, gpa, arena, tmp.dir, "alpha", a_path, 10);
    try std.testing.expectEqualStrings("alpha", first.id);
    try std.testing.expectEqualStrings(a_path, first.path);

    try std.testing.expectError(Error.Duplicate, add(io, gpa, arena, tmp.dir, "alpha", b_path, 11));
    try std.testing.expectError(Error.NotADirectory, add(io, gpa, arena, tmp.dir, "missing", "/no/such/clanker/ws", 12));
    try std.testing.expectError(Error.BadName, add(io, gpa, arena, tmp.dir, "a/b", a_path, 13));

    const listed = try load(io, arena, tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), listed.len);

    const second = try add(io, gpa, arena, tmp.dir, "beta", b_path, 20);
    try std.testing.expectEqualStrings("beta", second.id);
    try std.testing.expectEqual(@as(usize, 2), (try load(io, arena, tmp.dir)).len);

    const moved = try update(io, gpa, arena, tmp.dir, "beta", "beta two", a_path);
    try std.testing.expectEqualStrings("beta two", moved.name);
    try std.testing.expectEqualStrings(a_path, moved.path);

    try remove(io, gpa, arena, tmp.dir, "alpha");
    const after = try load(io, arena, tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqualStrings("beta", after[0].id);
    try std.testing.expectError(Error.NoSuchWorkspace, remove(io, gpa, arena, tmp.dir, "alpha"));
    try std.testing.expectError(Error.Builtin, remove(io, gpa, arena, tmp.dir, ""));
}

test "an arbitrary number of workspaces can be registered" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(io, "root");
    const root = try tmp.dir.realPathFileAlloc(io, "root", arena);
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        const name = try std.fmt.allocPrint(arena, "ws{d}", .{i});
        _ = try add(io, gpa, arena, tmp.dir, name, root, i);
    }
    try std.testing.expectEqual(@as(usize, 32), (try load(io, arena, tmp.dir)).len);
}
