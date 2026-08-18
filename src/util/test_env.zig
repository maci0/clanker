//! The `io` + arena + temp-directory prelude a filesystem test opens with.
//!
//! Six identical lines repeated once per test block is six lines the reader
//! re-parses before reaching the case, and three teardowns that have to stay
//! in the right order by hand. `Env` is that prelude as one value.

const std = @import("std");

/// Declare one `var env: Env = .init(); defer env.deinit();` and take `io`,
/// `arena` and `env.tmp.dir` from it.
///
/// `io()` and `arena()` are methods rather than stored fields because both
/// hand out a pointer to the value they are called on: a copy taken during
/// `init` would dangle the moment the returned struct was moved into the
/// caller's slot.
pub const Env = struct {
    threaded: std.Io.Threaded,
    arena_state: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,

    pub fn init() Env {
        return .{
            .threaded = std.Io.Threaded.init(std.testing.allocator, .{}),
            .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator),
            .tmp = std.testing.tmpDir(.{}),
        };
    }

    /// Torn down newest-first, matching the order the stacked `defer`s this
    /// replaces ran in: the temp tree goes before the allocators that own the
    /// paths naming it.
    pub fn deinit(self: *Env) void {
        self.tmp.cleanup();
        self.arena_state.deinit();
        self.threaded.deinit();
    }

    pub fn io(self: *Env) std.Io {
        return self.threaded.io();
    }

    pub fn arena(self: *Env) std.mem.Allocator {
        return self.arena_state.allocator();
    }
};
