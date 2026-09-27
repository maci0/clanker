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

/// The longest fragment this module accepts. Named because it is a rule, not
/// a buffer size: the two copies of the alphabet that used to exist (here and
/// in `chatrooms.validMessageId`) each spelled it `64` inline, so raising one
/// left the other refusing ids the first had started minting.
pub const max_id_len: usize = 64;

/// True when `id` is a usable path fragment: 1..`max_id_len` chars of ASCII
/// alphanumerics, dashes, or underscores. Anything else is refused before it
/// can become a path fragment.
///
/// The one alphabet, shared with the ids a caller supplies rather than one
/// this harness mints (`chatrooms.validMessageId` holds message ids at the
/// `ck_chat` boundary). `validSessionId` is this predicate under the name its
/// callers read it by.
pub fn validIdFragment(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_len) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

/// True when `id` is a usable session id: 1..`max_id_len` chars of ASCII
/// alphanumerics, dashes, or underscores. Anything else is refused before it
/// can become a path fragment.
pub fn validSessionId(id: []const u8) bool {
    return validIdFragment(id);
}

test "validSessionId accepts the harness alphabet and refuses escapes" {
    try std.testing.expect(validSessionId("default"));
    try std.testing.expect(validSessionId("abc-123_DEF"));
    try std.testing.expect(validSessionId("a"));
    try std.testing.expect(!validSessionId(""));
    try std.testing.expect(!validSessionId("a/b"));
    try std.testing.expect(!validSessionId("../x"));
    try std.testing.expect(!validSessionId("a\\b"));
    try std.testing.expect(!validSessionId("a:b"));
    try std.testing.expect(!validSessionId("a.b"));
    try std.testing.expect(!validSessionId("a b"));
    try std.testing.expect(!validSessionId("sess@id"));
    try std.testing.expect(!validSessionId("a\x00b"));
    var too_long: [max_id_len + 1]u8 = .{'x'} ** (max_id_len + 1);
    try std.testing.expect(!validSessionId(&too_long));
    const max_len: [max_id_len]u8 = .{'x'} ** max_id_len;
    try std.testing.expect(validSessionId(&max_len));
}

test "the fragment alphabet is the one session ids and message ids share" {
    // `chatrooms.validMessageId` is a thin alias over this predicate; a
    // session id and a message id are the same shape on disk, so they must
    // not answer differently about the same bytes.
    for ([_][]const u8{ "default", "m1758000000-4242-1", "webui-7", "a", "" }) |id| {
        try std.testing.expectEqual(validSessionId(id), validIdFragment(id));
    }
}
