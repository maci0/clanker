//! A blocking lock for structures that do not carry an `std.Io` handle.
//!
//! `std.Io.Mutex` is the tree's lock everywhere an `Io` exists, but a
//! process-global registry touched at first use, and a table a connection
//! thread reaches without one, have no handle to hand it: `std.Thread.Mutex`
//! is gone in Zig 0.16 and there is no other std lock that takes none. This
//! is that lock, in the one place, so the process table, the job table and the
//! A2A reply cache stop each carrying their own copy.
//!
//! The critical sections it guards are short (map lookup, a dupe, an append),
//! so yielding between attempts is enough; a long wait would want `Io`.

const std = @import("std");

pub const SpinMutex = struct {
    raw: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *SpinMutex) void {
        while (!self.raw.tryLock()) {
            std.Thread.yield() catch {};
        }
    }

    pub fn unlock(self: *SpinMutex) void {
        self.raw.unlock();
    }
};
