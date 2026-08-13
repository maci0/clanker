//! Session-scoped subprocess registry. Kernel (PRD 0016) and DAP (PRD 0017)
//! share this: register by `<session-id>/<kind>`, SIGTERM the group on
//! session end. The registry never starts processes; callers own spawn.

const std = @import("std");
const session = @import("session.zig");

pub const Handle = struct {
    session_id: []const u8,
    kind: []const u8,
    pid: std.posix.pid_t,
};

pub const Registry = struct {
    mutex: std.Thread.Mutex = .{},
    items: std.ArrayList(Handle) = .empty,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |h| {
            self.gpa.free(h.session_id);
            self.gpa.free(h.kind);
        }
        self.items.deinit(self.gpa);
    }

    pub fn key(session_id: []const u8, kind: []const u8, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ session_id, kind });
    }

    /// Replaces any existing handle for the same session+kind.
    pub fn register(self: *Registry, session_id: []const u8, kind: []const u8, pid: std.posix.pid_t) !void {
        if (!session.validSessionId(session_id)) return error.InvalidSessionId;
        if (kind.len == 0) return error.EmptyKind;
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.items.items.len) {
            const h = self.items.items[i];
            if (std.mem.eql(u8, h.session_id, session_id) and std.mem.eql(u8, h.kind, kind)) {
                self.gpa.free(h.session_id);
                self.gpa.free(h.kind);
                _ = self.items.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        try self.items.append(self.gpa, .{
            .session_id = try self.gpa.dupe(u8, session_id),
            .kind = try self.gpa.dupe(u8, kind),
            .pid = pid,
        });
    }

    pub fn get(self: *Registry, session_id: []const u8, kind: []const u8) ?std.posix.pid_t {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |h| {
            if (std.mem.eql(u8, h.session_id, session_id) and std.mem.eql(u8, h.kind, kind))
                return h.pid;
        }
        return null;
    }

    /// SIGTERM every process for this session. Missing pids are ignored.
    pub fn terminateSession(self: *Registry, session_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.items.items.len) {
            const h = self.items.items[i];
            if (std.mem.eql(u8, h.session_id, session_id)) {
                std.posix.kill(h.pid, std.posix.SIG.TERM) catch {};
                self.gpa.free(h.session_id);
                self.gpa.free(h.kind);
                _ = self.items.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn count(self: *Registry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.items.items.len;
    }
};

test "register and get by session+kind" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.register("sess-1", "python", 42);
    try std.testing.expectEqual(@as(std.posix.pid_t, 42), reg.get("sess-1", "python").?);
    try std.testing.expect(reg.get("sess-1", "js") == null);
    try std.testing.expectEqual(@as(usize, 1), reg.count());
}

test "register replaces the previous pid for the same key" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.register("sess-1", "python", 1);
    try reg.register("sess-1", "python", 2);
    try std.testing.expectEqual(@as(std.posix.pid_t, 2), reg.get("sess-1", "python").?);
    try std.testing.expectEqual(@as(usize, 1), reg.count());
}

test "terminateSession drops every kind for that session" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.register("a", "python", 1);
    try reg.register("a", "js", 2);
    try reg.register("b", "python", 3);
    reg.terminateSession("a");
    try std.testing.expect(reg.get("a", "python") == null);
    try std.testing.expectEqual(@as(std.posix.pid_t, 3), reg.get("b", "python").?);
}

test "invalid session id is refused" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expectError(error.InvalidSessionId, reg.register("../x", "python", 1));
}
