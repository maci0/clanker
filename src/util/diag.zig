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

const std = @import("std");

/// One `error: ...` line on stderr. The caller still returns an error, which
/// is what sets the exit status.
pub fn errorLine(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("error: " ++ fmt ++ "\n", args);
}
