//! First-class workspaces: a project id plus the folders (roots) it spans and
//! the conversations tagged with that id.
//!
//! A workspace *is* a project (RFC 0001): one stable id over one or more named
//! folders. A leaf opened alone is a project with one root — the same shape, no
//! special case. The roots are folders on one machine (the home instance); a
//! remote member maps them to local checkouts via an explicit bind, never
//! through this registry.
//!
//! Sessions still live in the serve instance's `state/sessions/`; this file
//! is the registry that binds an id to the directories the files browser and
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
    BadRootName,
    BadPath,
    NotADirectory,
    Duplicate,
    NoSuchWorkspace,
    Builtin,
    /// The registry file is there but does not read back as a workspace list.
    /// Not an empty registry: see `load`.
    StoreUnreadable,
};

/// One named folder of a project. `name` is the operator's label for the
/// component (`core`, `web`); the empty name is the single, unnamed root of a
/// leaf project. `path` is an absolute directory on the home instance.
pub const Root = struct {
    name: []const u8 = "",
    path: []const u8,
};

pub const Workspace = struct {
    id: []const u8,
    name: []const u8,
    /// One or more named folders. Never empty after load or creation: a row
    /// written before multi-root (a legacy `path` string) is normalised to one
    /// unnamed root.
    roots: []const Root = &.{},
    /// Per-project membership roster (RFC 0001), owner first. Instance ids of
    /// the clankers that have entered this project; the home instance is always
    /// the first entry. Empty until mesh Phase 3 populates entered members.
    members: []const []const u8 = &.{},
    created: i64 = 0,
};

/// A workspace id is what sessions store. No separators, no controls, so the
/// rail cannot lie about nesting and the id can never be a path. The `:`
/// separator is reserved for the room namespace (`ws:<id>:goal:<id>`), so a
/// workspace id carrying one would make that namespace ambiguous (RFC 0001
/// question 1). HTTP and session-tag callers that allow the empty default
/// workspace wrap this.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    for (name) |c| {
        if (c < 0x20 or c == 0x7f) return false;
        if (c == '/' or c == '\\' or c == ':') return false;
    }
    return true;
}

/// A root name is either empty (the single unnamed root) or a short component
/// label with the same separators forbidden as a workspace id.
pub fn validRootName(name: []const u8) bool {
    if (name.len == 0) return true;
    if (name.len > max_name_len) return false;
    for (name) |c| {
        if (c < 0x20 or c == 0x7f) return false;
        if (c == '/' or c == '\\' or c == ':') return false;
    }
    return true;
}

pub fn validPath(path: []const u8) bool {
    if (path.len == 0 or path.len > max_path_bytes) return false;
    return std.mem.findScalar(u8, path, 0) == null;
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

/// The on-disk shape, kept separate from `Workspace` so a file written before
/// multi-root (`path` string) still loads. `roots` is the current form.
const StoredRoot = struct {
    name: []const u8 = "",
    path: []const u8 = "",
};

const StoredWorkspace = struct {
    id: []const u8,
    name: []const u8,
    path: []const u8 = "",
    roots: []const StoredRoot = &.{},
    members: []const []const u8 = &.{},
    created: i64 = 0,
};

fn fromStored(arena: std.mem.Allocator, stored: []const StoredWorkspace) ![]Workspace {
    var out: std.ArrayList(Workspace) = .empty;
    for (stored) |sw| {
        var roots: std.ArrayList(Root) = .empty;
        if (sw.roots.len > 0) {
            for (sw.roots) |r| {
                try roots.append(arena, .{ .name = r.name, .path = r.path });
            }
        } else if (sw.path.len > 0) {
            try roots.append(arena, .{ .name = "", .path = sw.path });
        }
        try out.append(arena, .{
            .id = sw.id,
            .name = sw.name,
            .roots = try roots.toOwnedSlice(arena),
            .members = sw.members,
            .created = sw.created,
        });
    }
    return out.toOwnedSlice(arena);
}

/// Reads the registry. A missing (or empty) file is an empty list.
///
/// A file that is *there* and cannot be read is not: `add`, `remove` and
/// `updateRoots` all load, mutate and then `save` the whole list, so answering
/// "empty" for an unreadable registry makes the next mutation write a one-entry
/// file over every workspace the operator had, and report success. `FileNotFound`
/// is the only error that means empty; every other one is surfaced so those
/// callers refuse to mutate instead. That covers JSON that will not parse just
/// as much as an I/O failure — the write that follows replaces the file either
/// way, and a hand-edit with a trailing comma is the likelier of the two.
pub fn load(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir) ![]Workspace {
    const raw = base.readFileAlloc(io, store_path, arena, .limited(max_store_bytes)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => {
            log.log(.warn, "workspaces: could not read {s}: {s}", .{ store_path, @errorName(err) });
            return err;
        },
    };
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return &.{};
    const stored = std.json.parseFromSliceLeaky([]StoredWorkspace, arena, trimmed, .{ .ignore_unknown_fields = true }) catch {
        log.log(.error_, "workspaces: {s} is not a readable list; fix or move it", .{store_path});
        return Error.StoreUnreadable;
    };
    return fromStored(arena, stored);
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
    // Owner-only: the store maps projects to their saved conversation ids,
    // which other local users have no reason to read.
    try atomic_write.writeFilePerms(io, base, store_path, enc.written(), atomic_write.private_file);
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

/// Resolves and validates a list of named roots. A single empty-named root is
/// the leaf case; every path must already exist and name a directory.
fn resolveRoots(io: std.Io, arena: std.mem.Allocator, roots: []const Root) ![]Root {
    if (roots.len == 0) return Error.BadPath;
    var out: std.ArrayList(Root) = .empty;
    for (roots) |r| {
        if (!validRootName(r.name)) return Error.BadRootName;
        const abs = try resolveDir(io, arena, r.path);
        try out.append(arena, .{ .name = r.name, .path = abs });
    }
    return out.toOwnedSlice(arena);
}

/// Appends a workspace with one or more named roots. Caller holds no lock;
/// this takes one for the read-modify-write. `owner` is the home instance id
/// (may be empty when the harness has no identity yet); it becomes the first
/// membership roster entry.
pub fn addRoots(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    name: []const u8,
    roots: []const Root,
    owner: []const u8,
    now: i64,
) !Workspace {
    if (!validName(name)) return Error.BadName;
    const resolved = try resolveRoots(io, arena, roots);
    var guard = file_lock.acquire(io, base, state_dir, "workspaces", gpa);
    defer guard.release();
    var list: std.ArrayList(Workspace) = .empty;
    list.appendSlice(arena, try load(io, arena, base)) catch return error.OutOfMemory;
    if (find(list.items, name) != null) return Error.Duplicate;
    const id = try nextId(arena, list.items, name);
    const members: []const []const u8 = if (owner.len > 0) blk: {
        const m = try arena.alloc([]const u8, 1);
        m[0] = owner;
        break :blk m;
    } else &.{};
    const ws = Workspace{ .id = id, .name = name, .roots = resolved, .members = members, .created = now };
    list.append(arena, ws) catch return error.OutOfMemory;
    try save(io, arena, base, list.items);
    return ws;
}

/// Appends a single-folder workspace (the pre-multi-root call shape).
pub fn add(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    name: []const u8,
    path: []const u8,
    owner: []const u8,
    now: i64,
) !Workspace {
    return addRoots(io, gpa, arena, base, name, &.{.{ .name = "", .path = path }}, owner, now);
}

fn updateWith(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    id: []const u8,
    name: ?[]const u8,
    roots: ?[]const Root,
) !Workspace {
    if (id.len == 0) return Error.Builtin;
    if (!validName(id)) return Error.BadName;
    const resolved = if (roots) |rs| try resolveRoots(io, arena, rs) else null;
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
    if (resolved) |rs| slot.roots = rs;
    try save(io, arena, base, list.items);
    return slot.*;
}

/// Replaces the folder of a single-root workspace. Existing multi-root rows
/// keep their extra roots unless `updateRoots` is used.
pub fn update(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    id: []const u8,
    name: ?[]const u8,
    path: ?[]const u8,
) !Workspace {
    const roots: ?[]const Root = if (path) |p| blk: {
        const resolved = try resolveDir(io, arena, p);
        break :blk try arena.dupe(Root, &.{.{ .name = "", .path = resolved }});
    } else null;
    return updateWith(io, gpa, arena, base, id, name, roots);
}

/// Replaces the whole root set of a workspace.
pub fn updateRoots(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    id: []const u8,
    name: ?[]const u8,
    roots: []const Root,
) !Workspace {
    return updateWith(io, gpa, arena, base, id, name, roots);
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

/// The primary root's path — the directory the files browser and a run should
/// use when a caller still assumes one root. Null means the process cwd
/// (default workspace, or a label with no registered folder).
pub fn pathFor(list: []const Workspace, id: []const u8) ?[]const u8 {
    const roots = rootsFor(list, id) orelse return null;
    if (roots.len == 0) return null;
    if (roots[0].path.len == 0) return null;
    return roots[0].path;
}

/// The workspace's root set. Null means the empty default workspace (process
/// cwd); an empty slice is a registered row with no folder.
pub fn rootsFor(list: []const Workspace, id: []const u8) ?[]const Root {
    if (id.len == 0) return null;
    const ws = find(list, id) orelse return null;
    return ws.roots;
}

// ------------------------------------------------------------------ tests --

test "validName rejects empty, separators, colon, and oversize" {
    try std.testing.expect(!validName(""));
    try std.testing.expect(validName("research"));
    try std.testing.expect(validName("web ui"));
    try std.testing.expect(!validName("a/b"));
    try std.testing.expect(!validName("a\\b"));
    try std.testing.expect(!validName("a:b"));
    try std.testing.expect(!validName("relumea:goal"));
    try std.testing.expect(!validName("a\nb"));
    try std.testing.expect(!validName("x" ** 65));
}

test "validRootName allows the unnamed root and rejects separators" {
    try std.testing.expect(validRootName(""));
    try std.testing.expect(validRootName("core"));
    try std.testing.expect(validRootName("web ui"));
    try std.testing.expect(!validRootName("a/b"));
    try std.testing.expect(!validRootName("a:b"));
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

    const first = try add(io, gpa, arena, tmp.dir, "alpha", a_path, "main", 10);
    try std.testing.expectEqualStrings("alpha", first.id);
    try std.testing.expectEqualStrings(a_path, first.roots[0].path);
    try std.testing.expectEqual(@as(usize, 1), first.members.len);
    try std.testing.expectEqualStrings("main", first.members[0]);

    try std.testing.expectError(Error.Duplicate, add(io, gpa, arena, tmp.dir, "alpha", b_path, "", 11));
    try std.testing.expectError(Error.NotADirectory, add(io, gpa, arena, tmp.dir, "missing", "/no/such/clanker/ws", "", 12));
    try std.testing.expectError(Error.BadName, add(io, gpa, arena, tmp.dir, "a/b", a_path, "", 13));
    try std.testing.expectError(Error.BadName, add(io, gpa, arena, tmp.dir, "a:b", a_path, "", 14));

    const listed = try load(io, arena, tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), listed.len);

    const second = try add(io, gpa, arena, tmp.dir, "beta", b_path, "", 20);
    try std.testing.expectEqualStrings("beta", second.id);
    try std.testing.expectEqual(@as(usize, 2), (try load(io, arena, tmp.dir)).len);

    const moved = try update(io, gpa, arena, tmp.dir, "beta", "beta two", a_path);
    try std.testing.expectEqualStrings("beta two", moved.name);
    try std.testing.expectEqualStrings(a_path, moved.roots[0].path);

    try remove(io, gpa, arena, tmp.dir, "alpha");
    const after = try load(io, arena, tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqualStrings("beta", after[0].id);
    try std.testing.expectError(Error.NoSuchWorkspace, remove(io, gpa, arena, tmp.dir, "alpha"));
    try std.testing.expectError(Error.Builtin, remove(io, gpa, arena, tmp.dir, ""));
}

test "addRoots stores a named multi-root project" {
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

    try tmp.dir.createDirPath(io, "core");
    try tmp.dir.createDirPath(io, "web");
    const core = try tmp.dir.realPathFileAlloc(io, "core", arena);
    const web = try tmp.dir.realPathFileAlloc(io, "web", arena);

    const created = try addRoots(io, gpa, arena, tmp.dir, "relumea", &.{
        .{ .name = "core", .path = core },
        .{ .name = "web", .path = web },
    }, "main", 5);
    try std.testing.expectEqual(@as(usize, 2), created.roots.len);
    try std.testing.expectEqualStrings("core", created.roots[0].name);
    try std.testing.expectEqualStrings(core, created.roots[0].path);
    try std.testing.expectEqualStrings("web", created.roots[1].name);

    const loaded = try load(io, arena, tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqual(@as(usize, 2), loaded[0].roots.len);
    try std.testing.expectEqualStrings(core, pathFor(loaded, "relumea") orelse unreachable);
    try std.testing.expectEqualStrings(web, (rootsFor(loaded, "relumea") orelse unreachable)[1].path);

    // A leaf with no registered row is the default workspace.
    try std.testing.expect(pathFor(loaded, "") == null);
}

test "a legacy path-only row loads as one unnamed root" {
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

    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.writeFile(io, .{ .sub_path = store_path, .data =
        \\[{"id":"old","name":"old","path":"/tmp/old-folder","created":3}]
    });
    const loaded = try load(io, arena, tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqual(@as(usize, 1), loaded[0].roots.len);
    try std.testing.expectEqualStrings("", loaded[0].roots[0].name);
    try std.testing.expectEqualStrings("/tmp/old-folder", loaded[0].roots[0].path);
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
        _ = try add(io, gpa, arena, tmp.dir, name, root, "", i);
    }
    try std.testing.expectEqual(@as(usize, 32), (try load(io, arena, tmp.dir)).len);
}

test "an unreadable registry refuses the mutation instead of wiping it" {
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
    _ = try add(io, gpa, arena, tmp.dir, "keep", root, "", 1);

    // A registry larger than the read cap: on disk, holding real entries, and
    // refused by `readFileAlloc`. Treating that as an empty list is what let
    // the `save` below write one entry over the whole file.
    const oversized = try arena.alloc(u8, max_store_bytes + 1);
    @memset(oversized, ' ');
    @memcpy(oversized[0..2], "[]");
    try tmp.dir.writeFile(io, .{ .sub_path = store_path, .data = oversized });

    try std.testing.expectError(error.StreamTooLong, load(io, arena, tmp.dir));
    try std.testing.expectError(error.StreamTooLong, add(io, gpa, arena, tmp.dir, "second", root, "", 2));

    // Still the file that was there, byte for byte: nothing was written through.
    const after = try tmp.dir.readFileAlloc(io, store_path, arena, .limited(4 * max_store_bytes));
    try std.testing.expectEqual(oversized.len, after.len);
}

test "a registry that will not parse refuses the mutation too" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root");
    const root = try tmp.dir.realPathFileAlloc(io, "root", arena);
    _ = try add(io, gpa, arena, tmp.dir, "keep", root, "", 1);

    // A hand-edit that broke the JSON is the same hazard as a failed read: the
    // mutation below rewrites the whole file, so "empty" here would persist as
    // a deletion of every workspace.
    const broken = "[{\"id\":\"keep\",}]";
    try tmp.dir.writeFile(io, .{ .sub_path = store_path, .data = broken });

    try std.testing.expectError(Error.StoreUnreadable, load(io, arena, tmp.dir));
    try std.testing.expectError(Error.StoreUnreadable, add(io, gpa, arena, tmp.dir, "second", root, "", 2));

    const after = try tmp.dir.readFileAlloc(io, store_path, arena, .limited(max_store_bytes));
    try std.testing.expectEqualStrings(broken, after);
}
