//! Minimal Zig binding over the vendored SQLite amalgamation (vendor/sqlite).
//!
//! Host-only by design: WASM guests never link SQLite. The surface is the
//! small slice the session event store needs — open/close, exec, prepared
//! statements with text/int binds and columns, last-insert-rowid — plus the
//! constants that make step/status handling read clearly. Everything is
//! host-tested beside the store (src/agent/session_events.zig).

const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Error = error{
    OpenFailed,
    ExecFailed,
    PrepareFailed,
    StepFailed,
    BindFailed,
    ColumnFailed,
    NotOpen,
};

/// One SQLite row constant returned by step().
pub const Step = enum {
    row,
    done,
};

pub const Connection = struct {
    db: ?*c.sqlite3 = null,
    /// Human-readable diagnostics from the last failure, for the store to
    /// report WHERE the error came from.
    last_error: []const u8 = "",

    /// Opens (creating if needed) the database at `path`.
    pub fn open(self: *Connection, path: [:0]const u8) Error!void {
        if (self.db != null) self.close();
        const flags: c_int = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        var out: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path.ptr, &out, flags, null);
        if (rc != c.SQLITE_OK) {
            if (out) |db| {
                self.last_error = std.mem.span(@as([*:0]const u8, @ptrCast(c.sqlite3_errmsg(db))));
                _ = c.sqlite3_close_v2(db);
            } else {
                self.last_error = "sqlite3_open_v2 returned no handle";
            }
            return Error.OpenFailed;
        }
        self.db = out;
        // Busy handling: another connection (another thread, another process)
        // may hold the file briefly. Wait rather than fail an append.
        _ = c.sqlite3_busy_timeout(self.db.?, 5000);
    }

    pub fn close(self: *Connection) void {
        if (self.db) |db| {
            _ = c.sqlite3_close_v2(db);
            self.db = null;
        }
    }

    /// Runs a statement with no result rows (DDL, pragmas).
    pub fn exec(self: *Connection, sql: [:0]const u8) Error!void {
        const db = self.db orelse return Error.NotOpen;
        var err_msg: [*c]u8 = null;
        defer if (err_msg != null) c.sqlite3_free(@ptrCast(err_msg));
        const rc = c.sqlite3_exec(db, sql.ptr, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            self.last_error = if (err_msg != null) std.mem.span(@as([*:0]const u8, @ptrCast(err_msg))) else "sqlite3_exec failed";
            return Error.ExecFailed;
        }
    }

    /// Prepares a statement against this connection.
    pub fn prepare(self: *Connection, sql: []const u8) Error!Statement {
        const db = self.db orelse return Error.NotOpen;
        var out: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &out, null);
        if (rc != c.SQLITE_OK) {
            self.last_error = std.mem.span(@as([*:0]const u8, @ptrCast(c.sqlite3_errmsg(db))));
            return Error.PrepareFailed;
        }
        return .{ .stmt = out };
    }

    /// The row id of the last successful INSERT on this connection.
    pub fn lastInsertRowid(self: *Connection) i64 {
        const db = self.db orelse return 0;
        return c.sqlite3_last_insert_rowid(db);
    }

    /// The current error message, for diagnostics.
    pub fn errmsg(self: *Connection) []const u8 {
        const db = self.db orelse return self.last_error;
        return std.mem.span(@as([*:0]const u8, @ptrCast(c.sqlite3_errmsg(db))));
    }
};

pub const Statement = struct {
    stmt: ?*c.sqlite3_stmt = null,

    pub fn finalize(self: *Statement) void {
        if (self.stmt) |s| {
            _ = c.sqlite3_finalize(s);
            self.stmt = null;
        }
    }

    pub fn bindText(self: *Statement, index: c_int, value: []const u8) Error!void {
        const s = self.stmt orelse return Error.NotOpen;
        const rc = c.sqlite3_bind_text(s, index, value.ptr, @intCast(value.len), c.SQLITE_TRANSIENT);
        if (rc != c.SQLITE_OK) return Error.BindFailed;
    }

    pub fn bindInt(self: *Statement, index: c_int, value: i64) Error!void {
        const s = self.stmt orelse return Error.NotOpen;
        const rc = c.sqlite3_bind_int64(s, index, value);
        if (rc != c.SQLITE_OK) return Error.BindFailed;
    }

    pub fn bindNull(self: *Statement, index: c_int) Error!void {
        const s = self.stmt orelse return Error.NotOpen;
        const rc = c.sqlite3_bind_null(s, index);
        if (rc != c.SQLITE_OK) return Error.BindFailed;
    }

    /// Steps once. `.row` means columnText/columnInt are valid for this row;
    /// `.done` means the statement finished.
    pub fn step(self: *Statement) Error!Step {
        const s = self.stmt orelse return Error.NotOpen;
        const rc = c.sqlite3_step(s);
        return switch (rc) {
            c.SQLITE_ROW => .row,
            c.SQLITE_DONE => .done,
            else => Error.StepFailed,
        };
    }

    /// The text of column `index`, transient: copy it before the next step.
    pub fn columnText(self: *Statement, index: c_int) ?[]const u8 {
        const s = self.stmt orelse return null;
        const ptr = c.sqlite3_column_text(s, index);
        if (ptr == null) return null;
        const len = c.sqlite3_column_bytes(s, index);
        return @as([*]const u8, @ptrCast(ptr))[0..@intCast(len)];
    }

    pub fn columnInt(self: *Statement, index: c_int) i64 {
        const s = self.stmt orelse return 0;
        return c.sqlite3_column_int64(s, index);
    }

    pub fn reset(self: *Statement) void {
        if (self.stmt) |s| _ = c.sqlite3_reset(s);
    }
};

/// Convenience: a BEGIN/COMMIT wrapper for the rare multi-statement write.
pub const Transaction = struct {
    conn: *Connection,
    active: bool = false,

    pub fn begin(conn: *Connection) Error!Transaction {
        try conn.exec("BEGIN IMMEDIATE;");
        return .{ .conn = conn, .active = true };
    }

    pub fn commit(self: *Transaction) Error!void {
        try self.conn.exec("COMMIT;");
        self.active = false;
    }

    pub fn rollback(self: *Transaction) void {
        if (self.active) {
            self.conn.exec("ROLLBACK;") catch {};
            self.active = false;
        }
    }
};
