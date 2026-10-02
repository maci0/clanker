//! Operator-facing diagnostics, in one place.
//!
//! clanker writes two different things to stderr and they are not
//! interchangeable. A *log record* (`util/log.zig`) is `[ERROR] ts_ms=...`,
//! written for a collector and for `--verbose` tracing. A *diagnostic* is the
//! one line a person reads when a command they just typed refused to run: no
//! timestamp, no level, the recovery action first. `cli.printUsageError` is
//! this shape for everything that has a `std.Io` in hand; subsystems reached
//! from the CLI (the record stores, the mesh client) do not, so they print
//! through here rather than falling back to the logger and answering the same
//! class of mistake in a second format.
//!
//! The shape is pinned at the boundary instead of in a `test` block here:
//! `tests/e2e/journeys_test.zig` reads the real `error: ...` line off a real
//! child's stderr. A unit test would have to swap fd 2 under a shared test
//! runner, which is the fragile kind of test worth less than the journey that
//! reads what an operator actually sees.

const std = @import("std");

/// One `error: ...` line on stderr. The caller still returns an error, which
/// is what sets the exit status.
pub fn errorLine(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("error: " ++ fmt ++ "\n", args);
}
