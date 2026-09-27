//! The compare-and-swap lock path for a state file, shared by every writer of
//! one target.
//!
//! ADR 0031 puts the lock for a CAS write on `{state_dir}/locks/<hex>.lock`,
//! where `<hex>` is the SHA-256 of the target's directory part *resolved* and
//! its basename appended as written. That key was private to
//! `src/sandbox/host.zig`'s `fsWriteIfImpl`, which meant any native writer of
//! the same store took a lock of its own invention (`state/<name>.lock` side)
//! and excluded nothing: the schedule runner's read-modify-write and a guest's
//! `schedule add` could interleave, and the native save clobbered the guest's
//! entry silently. One key function, one lock inode per target, both sides
//! call it here.
//!
//! The lock file itself is permanent by design and carries the fixed-width
//! holder record (`tools/zig/cas_lock_record.zig`) when the host writes it;
//! this module only names and takes it.

const std = @import("std");
const ensure_dir = @import("ensure_dir.zig");
const file_lock = @import("file_lock.zig");
const log = @import("log.zig");

/// The lock key for `target`: the directory part resolved to an absolute path
/// (walking up to the nearest ancestor that exists when the target does not
/// exist yet), the basename appended rather than resolved, ASCII-folded when
/// the volume it names is case-insensitive.
///
/// Resolving beats hashing the spelling: one file reached as
/// `./state/goals.json`, `/abs/checkout/state/goals.json`, and a grant-spelled
/// path must map to one lock inode or two writers exclude nothing. The
/// basename stays unresolved so a writer of a symlink's own name and a writer
/// of its destination do not share a lock they cannot both mean.
///
/// Folding is the same argument one level down. macOS ships a case-insensitive
/// APFS by default, so `state/Goals.json` and `state/goals.json` are one file
/// with two spellings; hashing them as written mints two lock inodes and
/// neither writer excludes the other, which is the whole failure this function
/// exists to prevent. Two files that really are distinct on a case-sensitive
/// volume still get their own locks, because the fold is off there.
pub fn resolvedKey(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, target: []const u8) ![]u8 {
    const key = try resolveSpelling(alloc, io, base, target);
    if (volumeIsCaseInsensitive(alloc, io, base, key)) {
        defer alloc.free(key);
        return foldCase(alloc, key);
    }
    return key;
}

/// The key as written, with the directory part resolved. Split out so the fold
/// decision sees the final spelling; `resolvedKey` is the only caller.
fn resolveSpelling(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, target: []const u8) ![]u8 {
    const cut = std.mem.findScalarLast(u8, target, '/');
    const dir_part = if (cut) |i| (if (i == 0) target[0..1] else target[0..i]) else ".";
    const leaf = if (cut) |i| target[i + 1 ..] else target;

    // A first write into a missing directory has nothing below it to resolve,
    // so walk up to the nearest ancestor that does exist and keep the rest as
    // written. An absolute path floors at "/", a relative one at the base dir.
    const floor: usize = if (dir_part[0] == '/') 1 else 0;
    var end = dir_part.len;
    while (true) {
        const head = dir_part[0..end];
        if (base.realPathFileAlloc(io, if (head.len == 0) "." else head, alloc)) |abs| {
            defer alloc.free(abs);
            const tail = std.mem.trim(u8, dir_part[end..], "/");
            const stem = std.mem.trimEnd(u8, abs, "/");
            if (tail.len == 0) return std.fmt.allocPrint(alloc, "{s}/{s}", .{ stem, leaf });
            return std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ stem, tail, leaf });
        } else |_| {
            // Unresolvable all the way up: keep the path as written rather than
            // fail the write. A lock keyed on the raw string is what this
            // scheme replaced, so the fallback is never worse than that.
            if (end <= floor) return alloc.dupe(u8, target);
            end = std.mem.findScalarLast(u8, dir_part[0..end], '/') orelse floor;
            if (end < floor) end = floor;
        }
    }
}

fn foldCase(alloc: std.mem.Allocator, key: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, key);
    errdefer alloc.free(out);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

/// Whether the volume `key` names treats names case-insensitively.
///
/// Probed, not read off the OS: a capability the code asks the filesystem
/// about, because "case-insensitive" is a per-volume property and macOS can be
/// formatted either way. The probe asks for the key's directory with its
/// letters flipped -- on a case-insensitive volume that names the same
/// directory and resolves, on a case-sensitive one there is no such entry and
/// it does not. One `realpath`, nothing created, nothing written, so it is
/// cheap enough to ask per write; caching it would need process-global state
/// that two volumes in one process would then share wrongly.
///
/// When the probe cannot answer (no letters to flip, or nothing below `key`
/// resolved at all) it answers "case-insensitive", because the two errors are
/// not symmetric: folding on a case-sensitive volume costs two genuinely
/// distinct files one shared lock, which only serialises them against each
/// other, while not folding on a case-insensitive one costs the mutual
/// exclusion the lock exists to provide.
///
/// A flipped name that happens to exist as a *different* entry on a
/// case-sensitive volume reads as case-insensitive, which is the safe half of
/// that same trade.
fn volumeIsCaseInsensitive(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, key: []const u8) bool {
    const cut = std.mem.findScalarLast(u8, key, '/');
    const dir = if (cut) |i| (if (i == 0) key[0..1] else key[0..i]) else key;
    // The longest prefix of `dir` that exists is the deepest name whose volume
    // this answers for; the components below it are the ones the write is
    // about to create, and a not-yet-created name cannot be probed.
    var head = dir;
    while (head.len > 0) {
        if (base.realPathFileAlloc(io, head, alloc)) |abs| {
            defer alloc.free(abs);
            return flipResolvesToSelf(alloc, io, base, abs);
        } else |_| {}
        const next = std.mem.findScalarLast(u8, head, '/') orelse break;
        head = head[0..next];
    }
    return true;
}

fn flipResolvesToSelf(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, dir: []const u8) bool {
    const flipped = foldCase(alloc, dir) catch return true;
    defer alloc.free(flipped);
    if (std.mem.eql(u8, flipped, dir)) return true; // no letters to flip: cannot ask
    const resolved = base.realPathFileAlloc(io, flipped, alloc) catch return false;
    defer alloc.free(resolved);
    return std.mem.eql(u8, resolved, dir);
}

/// Where the advisory lock for `target` lives: `<locks_dir>/<sha256(key)>.lock`.
/// Caller creates `locks_dir` (or calls `acquire`, which ensures it).
pub fn lockPath(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, locks_dir: []const u8, target: []const u8) ![]u8 {
    const key = try resolvedKey(alloc, io, base, target);
    defer alloc.free(key);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(key);
    const name = std.fmt.bytesToHex(hasher.finalResult(), .lower);
    return std.fmt.allocPrint(alloc, "{s}/{s}.lock", .{ locks_dir, name });
}

/// Takes the exclusive lock guarding writes of `target`, creating `locks_dir`
/// when missing. Best effort like `file_lock.acquire`: losing a record is bad,
/// refusing every write because a lock could not be taken is worse, so a
/// failure warns and the caller proceeds unserialised. Free the returned
/// path with `gpa` when done.
pub fn acquire(io: std.Io, base: std.Io.Dir, gpa: std.mem.Allocator, locks_dir: []const u8, target: []const u8) struct { guard: file_lock.Guard, path: ?[]u8 } {
    ensure_dir.ensureDir(base, io, locks_dir) catch |err| {
        log.log(.warn, "could not create {s}: {s}", .{ locks_dir, @errorName(err) });
        return .{ .guard = .{ .io = io }, .path = null };
    };
    const path = lockPath(gpa, io, base, locks_dir, target) catch |err| {
        log.log(.warn, "could not derive lock path for {s}: {s}", .{ target, @errorName(err) });
        return .{ .guard = .{ .io = io }, .path = null };
    };
    const file = file_lock.createFileRetry(io, base, path, .{ .truncate = false, .lock = .exclusive }) catch |err| {
        log.log(.warn, "could not lock {s} ({s}); a concurrent write may be lost", .{ path, @errorName(err) });
        gpa.free(path);
        return .{ .guard = .{ .io = io }, .path = null };
    };
    return .{ .guard = .{ .file = file, .io = io }, .path = path };
}

test "one target, two spellings, one lock" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "state/sub");
    const base = tmp.dir;

    const a = try lockPath(std.testing.allocator, io, base, "state/locks", "state/schedule.json");
    defer std.testing.allocator.free(a);
    const b = try lockPath(std.testing.allocator, io, base, "state/locks", "./state/schedule.json");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);

    // A different leaf under the same directory is a different lock.
    const c = try lockPath(std.testing.allocator, io, base, "state/locks", "state/goals.json");
    defer std.testing.allocator.free(c);
    try std.testing.expect(!std.mem.eql(u8, a, c));
}

test "missing directories fall back up the tree deterministically" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = tmp.dir;

    // Neither `state` nor its parent spelling exists below base; both spellings
    // walk to the same existing ancestor (the temp root) and keep the tail.
    const a = try lockPath(std.testing.allocator, io, base, "state/locks", "state/schedule.json");
    defer std.testing.allocator.free(a);
    const b = try lockPath(std.testing.allocator, io, base, "state/locks", "./state/schedule.json");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
}

test "case-differing spellings of one name agree on a case-insensitive volume" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.writeFile(io, .{ .sub_path = "state/Goals.json", .data = "{}" });

    const lower = try lockPath(std.testing.allocator, io, tmp.dir, "state/locks", "state/goals.json");
    defer std.testing.allocator.free(lower);
    const upper = try lockPath(std.testing.allocator, io, tmp.dir, "state/locks", "state/Goals.json");
    defer std.testing.allocator.free(upper);

    // On a case-insensitive volume (macOS's default APFS) both spellings name
    // one file, so both must take one lock. On a case-sensitive one they are
    // two files and the keys stay apart; the volume is whatever the host gave
    // us, and a test that asserted one answer would be a test of the host.
    const insensitive = volumeIsCaseInsensitive(std.testing.allocator, io, tmp.dir, upper);
    try std.testing.expectEqual(insensitive, std.mem.eql(u8, lower, upper));
}

test "the fold merges case-differing spellings and nothing else" {
    // The decision is the only platform-conditional part of the key, so it is
    // asserted directly rather than through whichever volume the test ran on.
    const alloc = std.testing.allocator;
    const a = try foldCase(alloc, "/Users/me/Checkout/state/Goals.json");
    defer alloc.free(a);
    const b = try foldCase(alloc, "/users/ME/checkout/state/GOALS.json");
    defer alloc.free(b);
    // One file, two spellings, one key: the whole point on a case-insensitive
    // volume.
    try std.testing.expectEqualStrings(a, b);

    // Different leaves are different files whatever the volume does, so the
    // fold may not merge them (that would serialise unrelated writes and hide
    // a real per-file lock).
    const other = try foldCase(alloc, "/Users/me/Checkout/state/schedule.json");
    defer alloc.free(other);
    try std.testing.expect(!std.mem.eql(u8, a, other));
}

test "held lock excludes a second taker on the same inode" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state/locks");
    const base = tmp.dir;

    var first = acquire(io, base, std.testing.allocator, "state/locks", "state/schedule.json");
    defer {
        first.guard.release();
        if (first.path) |p| std.testing.allocator.free(p);
    }
    try std.testing.expect(first.guard.file != null);

    // Same target: blocked (WouldBlock), because it is the same inode.
    const second = file_lock.createFileRetry(io, base, first.path.?, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    });
    try std.testing.expectError(error.WouldBlock, second);
}
