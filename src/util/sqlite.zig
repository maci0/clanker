//! Minimal Zig binding over the vendored SQLite amalgamation (vendor/sqlite).
//!
//! Host-only by design: WASM guests never link SQLite. The surface is the
//! small slice the session event store needs — open/close, exec, prepared
//! statements with text/int binds and columns, last-insert-rowid — plus the
//! constants that make step/status handling read clearly. Everything is
//! host-tested beside the store (src/agent/session_events.zig).

const std = @import("std");
// 0.16 deprecates @cImport: sqlite3.h is translated by the build system
// (`addTranslateC` in build.zig) and linked here as a module. The amalgamation
// itself (vendor/sqlite/sqlite3.c) is compiled into each consuming module.
const c = @import("sqlite3_h");

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

/// sqlite3_errmsg / sqlite3_exec err_msg are NUL-terminated C strings.
/// translate-c types them `[*c]const u8` (nullable); after a null check
/// the same address is a sentinel-terminated string.
fn cSpan(p: [*c]const u8) []const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

pub const Connection = struct {
    db: ?*c.sqlite3 = null,
    /// Human-readable diagnostics from the last failure, for the store to
    /// report WHERE the error came from. Always a slice of `err_buf` (or a
    /// static string): sqlite3's own error strings live in memory that
    /// `sqlite3_free`/`sqlite3_close_v2` reclaims before the caller can read
    /// a slice of it, so the text is copied out at the failure site.
    last_error: []const u8 = "",
    err_buf: [256]u8 = undefined,

    fn setErr(self: *Connection, msg: []const u8) void {
        const n = @min(msg.len, self.err_buf.len);
        @memcpy(self.err_buf[0..n], msg[0..n]);
        self.last_error = self.err_buf[0..n];
    }

    /// Opens (creating if needed) the database at `path`.
    pub fn open(self: *Connection, path: [:0]const u8) Error!void {
        if (self.db != null) self.close();
        const flags: c_int = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        var out: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path.ptr, &out, flags, null);
        if (rc != c.SQLITE_OK) {
            if (out) |db| {
                // Copy before close: the message lives in the handle being
                // freed on the next line.
                self.setErr(cSpan(c.sqlite3_errmsg(db)));
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
        // WAL: readers (listing, search, event tails) proceed while a writer
        // (a streaming turn's save, the FTS swap) holds its transaction,
        // instead of queueing on the busy timeout. The mode persists in the
        // database file, so this is a one-time conversion per database; a
        // failure (read-only path, filesystem without shared memory) keeps
        // the default rollback journal and nothing else changes.
        _ = c.sqlite3_exec(self.db.?, "PRAGMA journal_mode=WAL;", null, null, null);
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
        // sqlite3_free takes `?*anyopaque`; err_msg is the same heap pointer
        // typed as `[*c]u8` by translate-c.
        defer if (err_msg != null) c.sqlite3_free(@ptrCast(err_msg));
        const rc = c.sqlite3_exec(db, sql.ptr, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            // Copy, not alias: the deferred sqlite3_free above reclaims
            // err_msg when this function returns, and the one reader of
            // last_error that matters — openDb's duplicate-column check on a
            // fresh database, where CREATE TABLE already carries the column
            // the migration ALTER re-adds — was matching against freed
            // memory and turning the expected "duplicate column name" into
            // a fatal open error.
            if (err_msg != null) self.setErr(cSpan(err_msg)) else self.last_error = "sqlite3_exec failed";
            return Error.ExecFailed;
        }
    }

    /// Prepares a statement against this connection.
    pub fn prepare(self: *Connection, sql: []const u8) Error!Statement {
        const db = self.db orelse return Error.NotOpen;
        var out: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &out, null);
        if (rc != c.SQLITE_OK) {
            // Same copy as exec: sqlite3_errmsg's buffer is only good until
            // the next call on this handle.
            self.setErr(cSpan(c.sqlite3_errmsg(db)));
            return Error.PrepareFailed;
        }
        return .{ .stmt = out };
    }

    /// The row id of the last successful INSERT on this connection.
    pub fn lastInsertRowid(self: *Connection) i64 {
        const db = self.db orelse return 0;
        return c.sqlite3_last_insert_rowid(db);
    }
};

/// `c.SQLITE_TRANSIENT` is `(sqlite3_destructor_type)-1`, and translate-c
/// materializes that cast as a comptime `@ptrFromInt` of all-ones, which zig
/// rejects on targets whose function pointers carry an alignment requirement
/// (aarch64-macos: "pointer type ... requires aligned address"). Redeclare
/// `sqlite3_bind_text` with the destructor parameter as the pointer-sized
/// integer it is at the ABI, so the sentinel never has to exist as a zig
/// function pointer at all.
const sqlite3_bind_text_raw = @extern(
    *const fn (?*c.sqlite3_stmt, c_int, [*c]const u8, c_int, usize) callconv(.c) c_int,
    .{ .name = "sqlite3_bind_text" },
);

/// SQLITE_TRANSIENT: sqlite copies the buffer before the bind returns.
const sqlite_transient: usize = std.math.maxInt(usize);

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
        const rc = sqlite3_bind_text_raw(s, index, value.ptr, @intCast(value.len), sqlite_transient);
        if (rc != c.SQLITE_OK) return Error.BindFailed;
    }

    pub fn bindInt(self: *Statement, index: c_int, value: i64) Error!void {
        const s = self.stmt orelse return Error.NotOpen;
        const rc = c.sqlite3_bind_int64(s, index, value);
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
        // Non-null after the check; length is sqlite3_column_bytes, not a sentinel.
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
