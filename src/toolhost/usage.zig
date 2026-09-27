//! A running tally of how often each tool is actually called.
//!
//! It exists to answer one question at request time: which tools should have
//! their full schemas in front of the model without being asked for? A fixed
//! list would be a guess about how this clanker works. The tally is a
//! measurement of it, so a machine that spends its days reading code ends up
//! with the reading tools loaded, and one that spends its days talking to
//! peers ends up with the chat tools loaded, without either being configured.
//!
//! Counts live in `state/tool_usage.json` as a flat object of name to count,
//! which is small, mergeable by hand, and readable by anything.

const std = @import("std");
const ensure_dir = @import("../util/ensure_dir.zig");
const atomic_write = @import("../util/atomic_write.zig");
const file_lock = @import("../util/file_lock.zig");
const log = @import("../util/log.zig");

pub const path = "state/tool_usage.json";

pub const Entry = struct {
    name: []const u8,
    count: u64,
};

pub const Usage = struct {
    /// Name to call count. Order is insertion order, which is meaningless;
    /// `top` sorts.
    counts: std.array_hash_map.String(u64) = .empty,
    /// Increments made by this process since load. Save merges these into the
    /// latest on-disk snapshot while holding the cross-process state lock.
    deltas: std.array_hash_map.String(u64) = .empty,
    /// Set when a count changed since the last save, so a run that called no
    /// tools does not rewrite the file.
    dirty: bool = false,

    pub fn record(self: *Usage, arena: std.mem.Allocator, name: []const u8) void {
        const gop = self.counts.getOrPut(arena, name) catch return;
        if (!gop.found_existing) {
            // The key has to outlive whatever arena the tool call was parsed
            // into, so it is copied into the allocator that owns this tally.
            gop.key_ptr.* = arena.dupe(u8, name) catch {
                _ = self.counts.swapRemove(name);
                return;
            };
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
        self.dirty = true;
        const delta = self.deltas.getOrPut(arena, gop.key_ptr.*) catch return;
        if (!delta.found_existing) delta.value_ptr.* = 0;
        delta.value_ptr.* += 1;
    }

    pub fn get(self: *const Usage, name: []const u8) u64 {
        return self.counts.get(name) orelse 0;
    }

    /// The `n` most-called tools, most first. Ties break by name so the set is
    /// stable between runs rather than shuffling with hash order, a tool list
    /// that changes shape for no reason invalidates the provider's prompt
    /// cache on every request.
    pub fn top(self: *const Usage, arena: std.mem.Allocator, n: usize) ![]Entry {
        var all: std.ArrayList(Entry) = .empty;
        var it = self.counts.iterator();
        while (it.next()) |kv| {
            try all.append(arena, .{ .name = kv.key_ptr.*, .count = kv.value_ptr.* });
        }
        std.mem.sort(Entry, all.items, {}, lessThan);
        if (all.items.len > n) return all.items[0..n];
        return all.items;
    }

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        if (a.count != b.count) return a.count > b.count;
        return std.mem.lessThan(u8, a.name, b.name);
    }

    /// Reads the tally at `path`.
    ///
    /// A missing file is the fresh-start case and yields an empty tally. Any
    /// other failure is returned, because the file being there but unreadable
    /// is not the same fact as there being no file: a caller that merges this
    /// tally into a new one and writes it back would, on the old
    /// empty-tally-on-any-failure behavior, replace a tally it merely failed
    /// to read with a file holding this run's increments alone. Every count
    /// ever recorded would be gone, with nothing in the log to say so.
    pub fn load(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir) !Usage {
        var u = Usage{};
        const raw = base.readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => return u,
            else => return err,
        };
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return error.CorruptTally;
        if (parsed != .object) return error.CorruptTally;
        var it = parsed.object.iterator();
        while (it.next()) |kv| {
            const v = switch (kv.value_ptr.*) {
                .integer => |i| if (i < 0) continue else @as(u64, @intCast(i)),
                else => continue,
            };
            try u.counts.put(arena, kv.key_ptr.*, v);
        }
        return u;
    }

    pub fn save(self: *Usage, io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir) void {
        if (!self.dirty) return;
        ensure_dir.ensureDir(base, io, "state") catch |err| {
            log.log(.warn, "tool usage: could not create state directory: {s}", .{@errorName(err)});
            return;
        };
        var guard = file_lock.acquire(io, base, "state", "tool_usage", arena);
        defer guard.release();

        // Another process may have saved after this Usage was loaded. Merge
        // only this run's increments into its latest snapshot instead of
        // replacing them with our stale absolute counts.
        //
        // A read that fails here is not a missing tally, it is a tally this
        // process cannot see, and writing anyway would discard it: the file
        // would come back holding this run's deltas alone. Keep the counts in
        // memory, leave the file alone, and name the file in the log so an
        // operator can look at it.
        var merged = Usage.load(io, arena, base) catch |err| {
            log.log(.warn, "tool usage: {s} could not be read ({s}); leaving it as it is rather than writing over it", .{ path, @errorName(err) });
            return;
        };
        var delta_it = self.deltas.iterator();
        while (delta_it.next()) |kv| {
            const gop = merged.counts.getOrPut(arena, kv.key_ptr.*) catch return;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* +|= kv.value_ptr.*;
        }
        var out: std.Io.Writer.Allocating = .init(arena);
        defer out.deinit();
        serialize(arena, &out, &merged) catch |err| {
            log.log(.warn, "tool usage: could not encode the tally ({s}); {s} is unchanged", .{ @errorName(err), path });
            return;
        };
        // Said rather than swallowed: a tally that silently stops being written
        // decays into a fixed tool set that nobody knows has stopped adapting.
        atomic_write.writeFile(io, base, path, out.written()) catch |err| {
            log.log(.warn, "tool usage: could not write {s}: {s}", .{ path, @errorName(err) });
            return;
        };
        self.dirty = false;
        self.deltas.clearRetainingCapacity();
    }
};

/// Renders the whole tally as one flat JSON object. Its own function so every
/// step's error reaches `save`'s single handler: a bare `catch return` per
/// write made an encoding failure (out of memory) look exactly like a save
/// that had nothing to write.
fn serialize(arena: std.mem.Allocator, out: *std.Io.Writer.Allocating, u: *const Usage) !void {
    _ = arena;
    var s = std.json.Stringify{ .writer = &out.writer };
    try s.beginObject();
    var it = u.counts.iterator();
    while (it.next()) |kv| {
        try s.objectField(kv.key_ptr.*);
        try s.write(kv.value_ptr.*);
    }
    try s.endObject();
}

test "record counts and orders by use" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var u = Usage{};
    u.record(arena, "read_file");
    u.record(arena, "read_file");
    u.record(arena, "read_file");
    u.record(arena, "git");
    u.record(arena, "git");
    u.record(arena, "calculator");

    try std.testing.expectEqual(@as(u64, 3), u.get("read_file"));
    try std.testing.expectEqual(@as(u64, 0), u.get("never_called"));

    const top = try u.top(arena, 2);
    try std.testing.expectEqual(@as(usize, 2), top.len);
    try std.testing.expectEqualStrings("read_file", top[0].name);
    try std.testing.expectEqualStrings("git", top[1].name);
}

test "ties break by name so the set is stable between runs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var u = Usage{};
    u.record(arena, "zebra");
    u.record(arena, "alpha");
    const top = try u.top(arena, 2);
    try std.testing.expectEqualStrings("alpha", top[0].name);
    try std.testing.expectEqualStrings("zebra", top[1].name);
}

test "top returns everything when asked for more than it holds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var u = Usage{};
    u.record(arena, "only");
    const top = try u.top(arena, 10);
    try std.testing.expectEqual(@as(usize, 1), top.len);
}

test "a fresh tally is not dirty and saves nothing" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var u = Usage{};
    try std.testing.expect(!u.dirty);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    u.save(io, arena_state.allocator(), tmp.dir);
    // `save` must not touch the file when nothing changed: a run that called
    // no tools should not rewrite (or create) the tally.
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, path, .{}));
}

test "concurrent process-style saves merge increments" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const Worker = struct {
        io: std.Io,
        base: std.Io.Dir,
        fn run(self: *@This()) void {
            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var usage = Usage.load(self.io, arena, self.base) catch Usage{};
            for (0..25) |_| usage.record(arena, "read_file");
            usage.save(self.io, arena, self.base);
        }
    };

    var workers: [6]Worker = undefined;
    var threads: [workers.len]std.Thread = undefined;
    for (&workers, 0..) |*worker, i| {
        worker.* = .{ .io = io, .base = tmp.dir };
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{worker});
    }
    for (&threads) |*thread| thread.join();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const loaded = try Usage.load(io, arena_state.allocator(), tmp.dir);
    try std.testing.expectEqual(@as(u64, workers.len * 25), loaded.get("read_file"));
}

test "a corrupt tally is reported and left on disk, not replaced by this run's deltas" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Bytes that are not a tally: the shape a hand edit or a truncated write
    // leaves behind. Reading them is an error, not an empty tally.
    try ensure_dir.ensureDir(tmp.dir, io, "state");
    try atomic_write.writeFile(io, tmp.dir, path, "{not a tally");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.CorruptTally, Usage.load(io, arena, tmp.dir));

    // The run still counts, and saving must not turn "I could not read the
    // old tally" into "the old tally is gone": the file keeps its bytes.
    var u = Usage{};
    u.record(arena, "read_file");
    u.save(io, arena, tmp.dir);

    var buf: [64]u8 = undefined;
    const raw = try tmp.dir.readFile(io, path, &buf);
    try std.testing.expectEqualStrings("{not a tally", raw);
    // Still dirty, so the increments are not lost either: a later save that
    // can read the file merges them in.
    try std.testing.expect(u.dirty);
}

test "a missing tally reads as empty, not as an error" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const loaded = try Usage.load(io, arena_state.allocator(), tmp.dir);
    try std.testing.expectEqual(@as(usize, 0), loaded.counts.count());
}
