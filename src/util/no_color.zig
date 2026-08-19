//! The https://no-color.org/ opt-out, in one place.
//!
//! The convention is precise: colour is suppressed when `NO_COLOR` is present
//! **and not an empty string**. `tui/theme.zig` read it that way while the two
//! colour decisions in `cli.zig` (streamed `run` output, the `serve` banner)
//! only checked for presence, so `NO_COLOR=` meant two different things in one
//! program: plain text from `clanker run`, colour from `clanker repl`.

const std = @import("std");

/// True when the environment asks for uncoloured output.
pub fn requested(environ_map: *const std.process.Environ.Map) bool {
    const v = environ_map.get("NO_COLOR") orelse return false;
    return v.len > 0;
}

test "NO_COLOR suppresses colour only when it carries a value" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();

    try std.testing.expect(!requested(&env));

    try env.put("NO_COLOR", "");
    try std.testing.expect(!requested(&env));

    try env.put("NO_COLOR", "1");
    try std.testing.expect(requested(&env));
}
