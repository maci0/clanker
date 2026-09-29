//! Reply cache for `POST /api/a2a/message`, keyed by the JSON-RPC request id.
//!
//! A2A is delegation: the route runs the peer's task through a full agent run,
//! so it spends a provider bill and can touch files before it answers. A peer
//! that loses the response (a proxy timeout, a dropped connection, an agent
//! retrying its own delegation) resends the *same* request id, and the route
//! used to run the agent a second time and answer twice. The duplicate is
//! invisible in the logs: two runs with different run ids, one task.
//!
//! JSON-RPC gives the operation a key for free, so the second execution
//! returns the first one's stored reply instead of repeating the work:
//!   - id absent, null, or a non-scalar value: nothing to key on, so the run
//!     happens as before (a notification-style request is not a duplicate by
//!     anything the route can see).
//!   - id seen and still in flight: `begin` reports `.wait`, and the handler
//!     answers a JSON-RPC error instead of starting a second run beside the
//!     first. This is the concurrent case, which a completed-only cache would
//!     miss because the first request has not answered yet.
//!   - id seen and completed inside the window: the stored reply is replayed.
//!   - the first request failed (provider error, agent init refused): the
//!     claim is released rather than stored, so the peer's retry is a fresh
//!     attempt instead of a replay of a failure.
//!
//! Bounded on all three axes, because a long-lived `serve` would otherwise
//! hold one agent answer per request id for as long as the process lives:
//! `max_entries` bounds the count, `max_bytes` the stored bytes (both evict
//! oldest first) and `ttl_s` the age. A retry that arrives after eviction runs
//! the agent again, which is the pre-cache behaviour, never worse.

const std = @import("std");
const spin_mutex = @import("../util/spin_mutex.zig");

/// How long a stored reply is replayed for. A peer retrying a delegation that
/// ran for minutes comes back inside this window; one that comes back tomorrow
/// is a new request as far as this process is concerned.
pub const ttl_s: i64 = 15 * 60;

/// Most ids held at once. Delegations are human-paced, so a peer far past this
/// number has a broken retry loop rather than a slow one.
pub const max_entries: usize = 64;

/// Most reply bytes held at once. An agent answer is kilobytes, so this is
/// generous while staying small next to the agent runs it saves.
pub const max_bytes: usize = 4 << 20;

const Entry = struct {
    id: []u8,
    /// When the claim was taken, seconds: the window and the eviction order.
    at: i64,
    /// The completed reply, or null while the first request is still running.
    body: ?[]u8,
};

pub const Begin = union(enum) {
    /// The id is new: the caller owns the run and must call `finish` or
    /// `release`.
    fresh,
    /// The same id is mid-run. Answer a JSON-RPC error; do not start a run.
    wait,
    /// The same id already completed. Replay this body.
    replay: []const u8,
};

pub const Cache = struct {
    gpa: std.mem.Allocator,
    /// Connections are handled one thread each, so two retries of one id can
    /// arrive together and both reach `begin` before either has stored
    /// anything. The lock is what makes the second one see the first's claim.
    mutex: spin_mutex.SpinMutex = .{},
    entries: std.ArrayList(Entry) = .empty,
    bytes: usize = 0,

    fn lock(self: *Cache) void {
        self.mutex.lock();
    }

    fn unlock(self: *Cache) void {
        self.mutex.unlock();
    }

    pub fn init(gpa: std.mem.Allocator) Cache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Cache) void {
        self.lock();
        defer self.unlock();
        for (self.entries.items) |e| {
            if (e.body) |b| self.gpa.free(b);
            self.gpa.free(e.id);
        }
        self.entries.deinit(self.gpa);
    }

    /// The JSON-RPC id as a key: a string is the key itself, an integer is its
    /// decimal spelling. Everything else (null, float, object, array, absent)
    /// has no stable spelling and is not deduplicated.
    pub fn keyFor(value: std.json.Value, buf: []u8) ?[]const u8 {
        return switch (value) {
            .string => |s| s,
            .integer => |i| std.fmt.bufPrint(buf, "{d}", .{i}) catch null,
            else => null,
        };
    }

    fn find(self: *Cache, key: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.id, key)) return i;
        }
        return null;
    }

    fn removeAt(self: *Cache, index: usize) void {
        const e = self.entries.orderedRemove(index);
        if (e.body) |b| {
            self.bytes -= b.len;
            self.gpa.free(b);
        }
        self.gpa.free(e.id);
    }

    /// Expire everything past the window, then make room for one more. A stamp
    /// in the future (a wall clock stepped backwards) is not expired: the entry
    /// is young by any reading, and the caps still bound the table.
    fn sweep(self: *Cache, now: i64) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (now - self.entries.items[i].at > ttl_s) {
                self.removeAt(i);
            } else {
                i += 1;
            }
        }
        while (self.entries.items.len > 0 and self.bytes > max_bytes) {
            self.removeAt(0);
        }
    }

    /// Registers interest in `key`. See `Begin`.
    pub fn begin(self: *Cache, key: []const u8, now: i64) Begin {
        self.lock();
        defer self.unlock();
        self.sweep(now);
        if (self.find(key)) |i| {
            if (self.entries.items[i].body) |b| return .{ .replay = b };
            return .wait;
        }
        while (self.entries.items.len >= max_entries) {
            self.removeAt(0);
        }
        const id = self.gpa.dupe(u8, key) catch return .fresh;
        self.entries.append(self.gpa, .{ .id = id, .at = now, .body = null }) catch {
            self.gpa.free(id);
            // Without a claim the duplicate cannot be told from the original,
            // which is the pre-cache behaviour. Losing the key is not a reason
            // to refuse the request.
            return .fresh;
        };
        return .fresh;
    }

    /// Stores the reply for a claimed id, so the next request with the same id
    /// replays it instead of running the agent again. The body is copied: the
    /// caller's buffer is a stack frame that is gone by the time a retry lands.
    /// Swept at the entry's own stamp, so a long run does not expire itself.
    pub fn finish(self: *Cache, key: []const u8, body: []const u8) void {
        self.lock();
        defer self.unlock();
        const i = self.find(key) orelse return;
        if (self.entries.items[i].body != null) return;
        const copy = self.gpa.dupe(u8, body) catch return;
        self.entries.items[i].body = copy;
        self.bytes += copy.len;
        self.sweep(self.entries.items[i].at);
    }

    /// Drops a claim whose run failed, so the peer's retry runs the agent
    /// instead of replaying a failure as a success.
    pub fn release(self: *Cache, key: []const u8) void {
        self.lock();
        defer self.unlock();
        const i = self.find(key) orelse return;
        if (self.entries.items[i].body != null) return;
        self.removeAt(i);
    }

    pub fn count(self: *const Cache) usize {
        return self.entries.items.len;
    }
};

// ------------------------------------------------------------------- tests --

const testing = std.testing;

test "a second request with the same id replays the first reply instead of running again" {
    var c = Cache.init(testing.allocator);
    defer c.deinit();

    try testing.expectEqual(Begin{ .fresh = {} }, c.begin("req-1", 100));
    // The first request is still running when its retry arrives.
    try testing.expectEqual(Begin{ .wait = {} }, c.begin("req-1", 101));
    c.finish("req-1", "{\"result\":1}");

    switch (c.begin("req-1", 102)) {
        .replay => |body| try testing.expectEqualStrings("{\"result\":1}", body),
        else => return error.ExpectedReplay,
    }
    // A different id is a different operation.
    try testing.expectEqual(Begin{ .fresh = {} }, c.begin("req-2", 102));
}

test "a failed run releases its claim so the retry is a fresh attempt" {
    var c = Cache.init(testing.allocator);
    defer c.deinit();

    try testing.expectEqual(Begin{ .fresh = {} }, c.begin("req-1", 100));
    c.release("req-1");
    try testing.expectEqual(Begin{ .fresh = {} }, c.begin("req-1", 101));
    try testing.expectEqual(@as(usize, 1), c.count());
}

test "the table is bounded by count and by age" {
    var c = Cache.init(testing.allocator);
    defer c.deinit();

    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < max_entries + 8) : (i += 1) {
        const key = try std.fmt.bufPrint(&buf, "req-{d}", .{i});
        const owned = try testing.allocator.dupe(u8, key);
        _ = c.begin(owned, 1000);
        c.finish(owned, "reply");
        testing.allocator.free(owned);
        try testing.expect(c.count() <= max_entries);
    }
    try testing.expectEqual(@as(usize, max_entries), c.count());

    // Age: every entry is stamped at 1000, so a sweep past the window finds
    // nothing left to replay.
    c.sweep(1000 + ttl_s + 1);
    try testing.expectEqual(@as(usize, 0), c.count());
    try testing.expectEqual(Begin{ .fresh = {} }, c.begin("req-0", 1000 + ttl_s + 2));
}

test "an integer id keys on its decimal spelling and an unusable one does not key at all" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("42", Cache.keyFor(.{ .integer = 42 }, &buf).?);
    try testing.expectEqualStrings("abc", Cache.keyFor(.{ .string = "abc" }, &buf).?);
    try testing.expect(Cache.keyFor(.null, &buf) == null);
    try testing.expect(Cache.keyFor(.{ .float = 1.5 }, &buf) == null);
    try testing.expect(Cache.keyFor(.{ .bool = true }, &buf) == null);
}
