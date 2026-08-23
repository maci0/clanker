//! The session-id alphabet, one rule for every entry point that accepts a
//! session id. Session ids are path fragments under `state/sessions/` and
//! `state/spills/`, so an id outside this alphabet could smuggle a separator
//! or a `..` past whichever caller forgot its own check.
//!
//! Shared across the trust boundary: `src/agent/session.zig` reaches this
//! file root-relatively, while the guests that build paths from ids
//! (`spill`, `rewind`, `janitor`) import it by name as a module wired in
//! `build.zig`. One owning module per compilation: never both spellings in
//! the same build graph.

const std = @import("std");

/// True when `id` is a usable session id: 1..64 chars of ASCII alphanumerics,
/// dashes, or underscores. Anything else is refused before it can become a
/// path fragment.
pub fn validSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

test "validSessionId accepts the harness alphabet and refuses escapes" {
    try std.testing.expect(validSessionId("default"));
    try std.testing.expect(validSessionId("abc-123_DEF"));
    try std.testing.expect(validSessionId("a"));
    try std.testing.expect(!validSessionId(""));
    try std.testing.expect(!validSessionId("a/b"));
    try std.testing.expect(!validSessionId("../x"));
    var too_long: [65]u8 = .{'x'} ** 65;
    try std.testing.expect(!validSessionId(&too_long));
    const max_len: [64]u8 = .{'x'} ** 64;
    try std.testing.expect(validSessionId(&max_len));
}
