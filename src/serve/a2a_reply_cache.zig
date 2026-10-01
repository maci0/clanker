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
//!   - id seen and completed inside the window, for the same task text: the
//!     stored reply is replayed.
//!   - the first request failed (provider error, agent init refused): the
//!     claim is released rather than stored, so the peer's retry is a fresh
//!     attempt instead of a replay of a failure.
//!
//! The key is the id *plus* a fingerprint of the task text, because the route
//! has no caller identity (THREAT_MODEL R1: `POST /api/a2a/message` is
//! unauthenticated in a stock install), so every caller on the host shares one
//! id namespace. Ids are short and countable (`1`, `"1"`, `"req-1"` are what
//! clients send), so an id alone let the *second* sender of an id collect the
//! *first* one's agent answer, which is that task's output rather than a copy
//! of their own. Replay requires id and text to agree; a reused id with a
//! different task runs again, which is the pre-cache behaviour and never
//! worse. `keyFor` also namespaces by JSON type, so the string `"42"` and the
//! integer `42` are two requests rather than one.
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
    /// Fingerprint of the task text this claim was taken for. The id alone is
    /// not a duplicate key on this route: any local caller may reuse it, and
    /// replaying across tasks would hand one caller's agent output to
    /// another.
    task_fp: u64,
    /// When the claim was taken, seconds: the window and the eviction order.
    at: i64,
    /// The completed reply, or null while the first request is still running.
    body: ?[]u8,
};

/// Fingerprint of the task text bound to a claim. Wyhash over the bytes.
pub fn taskFingerprint(text: []const u8) u64 {
    return std.hash.Wyhash.hash(0xA2A0DACADE5EED1E, text);
}

pub const Begin = union(enum) {
    /// The id is new, or is held by a request for a *different* task: the
    /// caller owns the run and must call `finish` or `release`. A `finish`
    /// whose key is taken by another task stores nothing, so the first run's
    /// stored reply is never overwritten by the second's.
    fresh,
    /// The same id, same task, mid-run. Answer a JSON-RPC error; do not start
    /// a run.
    wait,
    /// The same id, same task, already completed. Replay this body.
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

    /// The JSON-RPC id as a key, namespaced by JSON type. A string keeps its
    /// own bytes behind a `"s:` tag and an integer its decimal spelling behind
    /// `#i:`: `1` and `"1"` are different requests, and one key space let a
    /// client that counts up collide with one that sends strings and collect
    /// its reply. Everything else (null, float, object, array, absent) has no
    /// stable spelling and is not deduplicated.
    pub fn keyFor(value: std.json.Value, buf: []u8) ?[]const u8 {
        return switch (value) {
            .string => |s| std.fmt.bufPrint(buf, "\"s:{s}", .{s}) catch null,
            .integer => |i| std.fmt.bufPrint(buf, "#i:{d}", .{i}) catch null,
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

    /// Registers interest in `key` for the task text `task_fp` names. See `Begin`.
    ///
    /// An entry whose fingerprint differs is not a duplicate of this request:
    /// the claim is left alone (its own run still owns it) and `.fresh` is
    /// returned, so a reused id from a second caller runs its task instead of
    /// replaying the first one's answer. That costs one agent run the cache
    /// cannot save, which is exactly the pre-cache behaviour.
    pub fn begin(self: *Cache, key: []const u8, task_fp: u64, now: i64) Begin {
        self.lock();
        defer self.unlock();
        self.sweep(now);
        if (self.find(key)) |i| {
            if (self.entries.items[i].task_fp != task_fp) return .fresh;
            if (self.entries.items[i].body) |b| return .{ .replay = b };
            return .wait;
        }
        while (self.entries.items.len >= max_entries) {
            self.removeAt(0);
        }
        const id = self.gpa.dupe(u8, key) catch return .fresh;
        self.entries.append(self.gpa, .{ .id = id, .task_fp = task_fp, .at = now, .body = null }) catch {
            self.gpa.free(id);
            // Without a claim the duplicate cannot be told from the original,
            // which is the pre-cache behaviour. Losing the key is not a reason
            // to refuse the request.
            return .fresh;
        };
        return .fresh;
    }

    /// Stores the reply for a claimed id, so the next request with the same id
    /// and task replays it instead of running the agent again. The body is
    /// copied: the caller's buffer is a stack frame that is gone by the time a
    /// retry lands. Swept at the entry's own stamp, so a long run does not
    /// expire itself.
    ///
    /// A key whose claim belongs to a *different* task is left untouched: this
    /// run shares its id with one already in flight, and overwriting that
    /// entry would make the first caller replay the second caller's answer.
    pub fn finish(self: *Cache, key: []const u8, task_fp: u64, body: []const u8) void {
        self.lock();
        defer self.unlock();
        const i = self.find(key) orelse return;
        if (self.entries.items[i].task_fp != task_fp) return;
        if (self.entries.items[i].body != null) return;
        const copy = self.gpa.dupe(u8, body) catch return;
        self.entries.items[i].body = copy;
        self.bytes += copy.len;
        self.sweep(self.entries.items[i].at);
    }

    /// Drops a claim whose run failed, so the peer's retry runs the agent
    /// instead of replaying a failure as a success. A claim belonging to a
    /// different task is left alone for the same reason `finish` leaves it.
    pub fn release(self: *Cache, key: []const u8, task_fp: u64) void {
        self.lock();
        defer self.unlock();
        const i = self.find(key) orelse return;
        if (self.entries.items[i].task_fp != task_fp) return;
        if (self.entries.items[i].body != null) return;
        self.removeAt(i);
    }

    pub fn count(self: *const Cache) usize {
        return self.entries.items.len;
    }
};

// ------------------------------------------------------------------- tests --

const testing = std.testing;

test "a second request with the same id and task replays the first reply instead of running again" {
    var c = Cache.init(testing.allocator);
    defer c.deinit();

    const task = taskFingerprint("summarise the changelog");
    try testing.expectEqual(Begin{ .fresh = {} }, c.begin("req-1", task, 100));
    // The first request is still running when its retry arrives.
    try testing.expectEqual(Begin{ .wait = {} }, c.begin("req-1", task, 101));
    c.finish("req-1", task, "{\"result\":1}");

    switch (c.begin("req-1", task, 102)) {
        .replay => |body| try testing.expectEqualStrings("{\"result\":1}", body),
        else => return error.ExpectedReplay,
    }
    // A different id is a different operation.
    try testing.expectEqual(Begin{ .fresh = {} }, c.begin("req-2", task, 102));
}

test "a reused id from another caller does not replay the first task's answer" {
    var c = Cache.init(testing.allocator);
    defer c.deinit();

    const first = taskFingerprint("read the operator's private notes");
    const second = taskFingerprint("what is the capital of France");
    try testing.expectEqual(Begin{ .fresh = {} }, c.begin("req-1", first, 100));
    c.finish("req-1", first, "{\"result\":\"the notes\"}");

    // Same id, different task: the second caller must run its own agent rather
    // than collect the first one's output.
    switch (c.begin("req-1", second, 101)) {
        .fresh => {},
        else => return error.ExpectedFreshRun,
    }
    // Its own finish leaves the first caller's stored reply in place, and the
    // first caller still replays its own answer rather than the second's.
    c.finish("req-1", second, "{\"result\":\"Paris\"}");
    switch (c.begin("req-1", first, 102)) {
        .replay => |body| try testing.expectEqualStrings("{\"result\":\"the notes\"}", body),
        else => return error.ExpectedReplay,
    }
    // A failed run for an unclaimed task must not release the held claim.
    c.release("req-1", taskFingerprint("a task that never claimed anything"));
    try testing.expectEqual(@as(usize, 1), c.count());
}

test "an in-flight claim for another task is not answered as a duplicate either" {
    var c = Cache.init(testing.allocator);
    defer c.deinit();

    const first = taskFingerprint("task A");
    const second = taskFingerprint("task B");
    _ = c.begin("req-7", first, 100);
    // Not `.wait`: that is a 409 telling the caller "this id is in flight",
    // which for a different task is a statement about the other caller's run.
    try testing.expectEqual(Begin{ .fresh = {} }, c.begin("req-7", second, 101));
}

test "a failed run releases its claim so the retry is a fresh attempt" {
    var c = Cache.init(testing.allocator);
    defer c.deinit();

    const task = taskFingerprint("do the thing");
    try testing.expectEqual(Begin{ .fresh = {} }, c.begin("req-1", task, 100));
    c.release("req-1", task);
    try testing.expectEqual(Begin{ .fresh = {} }, c.begin("req-1", task, 101));
    try testing.expectEqual(@as(usize, 1), c.count());
}

test "the table is bounded by count and by age" {
    var c = Cache.init(testing.allocator);
    defer c.deinit();

    var buf: [32]u8 = undefined;
    const task = taskFingerprint("bounded");
    var i: usize = 0;
    while (i < max_entries + 8) : (i += 1) {
        const key = try std.fmt.bufPrint(&buf, "req-{d}", .{i});
        const owned = try testing.allocator.dupe(u8, key);
        _ = c.begin(owned, task, 1000);
        c.finish(owned, task, "reply");
        testing.allocator.free(owned);
        try testing.expect(c.count() <= max_entries);
    }
    try testing.expectEqual(@as(usize, max_entries), c.count());

    // Age: every entry is stamped at 1000, so a sweep past the window finds
    // nothing left to replay.
    c.sweep(1000 + ttl_s + 1);
    try testing.expectEqual(@as(usize, 0), c.count());
    try testing.expectEqual(Begin{ .fresh = {} }, c.begin("req-0", task, 1000 + ttl_s + 2));
}

test "an integer id keys on its decimal spelling and an unusable one does not key at all" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("#i:42", Cache.keyFor(.{ .integer = 42 }, &buf).?);
    try testing.expectEqualStrings("\"s:abc", Cache.keyFor(.{ .string = "abc" }, &buf).?);
    try testing.expect(Cache.keyFor(.null, &buf) == null);
    try testing.expect(Cache.keyFor(.{ .float = 1.5 }, &buf) == null);
    try testing.expect(Cache.keyFor(.{ .bool = true }, &buf) == null);
}

test "the string id 42 and the integer id 42 are two requests, not one" {
    var int_buf: [32]u8 = undefined;
    var str_buf: [32]u8 = undefined;
    const as_int = Cache.keyFor(.{ .integer = 42 }, &int_buf).?;
    const as_str = Cache.keyFor(.{ .string = "42" }, &str_buf).?;
    try std.testing.expect(!std.mem.eql(u8, as_int, as_str));

    var c = Cache.init(testing.allocator);
    defer c.deinit();
    const task = taskFingerprint("one task");
    try testing.expectEqual(Begin{ .fresh = {} }, c.begin(as_int, task, 100));
    c.finish(as_int, task, "{\"result\":\"integer id\"}");
    // The string id must not collect the integer id's reply.
    try testing.expectEqual(Begin{ .fresh = {} }, c.begin(as_str, task, 101));
}

test "a string id cannot be crafted to spell another id's key" {
    // One buffer per key: `keyFor` writes into the caller's buffer, so sharing
    // one across two calls would compare a key against its own overwrite.
    var a_buf: [64]u8 = undefined;
    var b_buf: [64]u8 = undefined;
    var i_buf: [64]u8 = undefined;
    // Every string key carries the same tag, so two string keys are equal only
    // when their bytes after the tag are, and neither can reach the integer
    // namespace (whose tag no string can produce).
    const a = Cache.keyFor(.{ .string = "s:1" }, &a_buf).?;
    const b = Cache.keyFor(.{ .string = "1" }, &b_buf).?;
    try std.testing.expect(!std.mem.eql(u8, a, b));
    const int_a = Cache.keyFor(.{ .integer = 1 }, &i_buf).?;
    try std.testing.expect(!std.mem.eql(u8, int_a, a));
    try std.testing.expect(!std.mem.eql(u8, int_a, b));
}
