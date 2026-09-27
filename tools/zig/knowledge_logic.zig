//! Knowledge collection bookkeeping that is pure enough to test from the host
//! (`host_tested_helpers` in build.zig) while the guest in `knowledge.zig`
//! imports it by name (`linked_helpers`). The document record lives here so
//! the guest and the tests agree on one shape.
//!
//! The rule this module exists for: a document is identified by its name
//! within its collection, so adding one twice is one document. `add_doc`
//! reached over HTTP (`POST /api/knowledge/<id>/docs`) and from the agent
//! alike, and a retried POST, a double-clicked Send, or a model repeating a
//! call whose reply it never saw each appended a second copy of the same
//! name. A duplicate is not a harmless second row: both copies are returned
//! to `search`, both are injected into the prompt of every later run that
//! asks for the collection, and the folder sync's prune then reads one of
//! them as the orphan and deletes it, leaving the name with a new id each
//! time. Keyed on the name, the second execution is a no-op.
//!
//! The upsert is the shape the folder sync already wanted: it deleted the
//! old document and added the new one in two calls, so a crash between them
//! lost the document outright, and a retry of the pair raced the prune.

const std = @import("std");

pub const Doc = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    content: []const u8 = "",
    bytes: usize = 0,
    created: i64 = 0,
};

/// One collection file, `state/knowledge/<id>.json`. The host reads the same
/// file directly when a run injects selected collections into its prompt
/// (`POST /api/run`), because that read is on the request path and cannot
/// afford a guest dispatch; a field dropped from the guest's copy would
/// silently reach the model as an empty string there, so the record is
/// declared once, here, for both sides. Mutable `docs` because the guest
/// rewrites a loaded collection in place.
pub const Collection = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
    created: i64 = 0,
    updated: i64 = 0,
    docs: []Doc = &.{},
};

/// The document `name` already has in this collection, or null when the name
/// is new. First match wins: a collection written before this rule can hold
/// more than one, and the oldest is the one an update should land on.
pub fn findByName(docs: []const Doc, name: []const u8) ?usize {
    for (docs, 0..) |d, i| {
        if (std.mem.eql(u8, d.name, name)) return i;
    }
    return null;
}

/// Whether re-adding `name` would leave the collection exactly as it is.
pub fn unchangedBy(docs: []const Doc, name: []const u8, content: []const u8) bool {
    const i = findByName(docs, name) orelse return false;
    return std.mem.eql(u8, docs[i].content, content);
}

const testing = std.testing;

fn docOf(id: []const u8, name: []const u8, content: []const u8) Doc {
    return .{ .id = id, .name = name, .content = content, .bytes = content.len, .created = 7 };
}

test "a name is found regardless of where it sits in the collection" {
    const docs = [_]Doc{ docOf("a", "one.md", "1"), docOf("b", "two.md", "2") };
    try testing.expectEqual(@as(?usize, 0), findByName(&docs, "one.md"));
    try testing.expectEqual(@as(?usize, 1), findByName(&docs, "two.md"));
    try testing.expectEqual(@as(?usize, null), findByName(&docs, "three.md"));
    // Names are compared whole, not by prefix or extension.
    try testing.expectEqual(@as(?usize, null), findByName(&docs, "one"));
    try testing.expectEqual(@as(?usize, null), findByName(&docs, "ONE.md"));
}

test "re-adding the same document leaves the collection with one document" {
    // What `actionAddDoc` does with this: an index means replace in place, and
    // the same name must never also be appended.
    var docs = [_]Doc{docOf("a", "one.md", "1")};
    const again = findByName(&docs, "one.md");
    try testing.expectEqual(@as(?usize, 0), again);
    docs[again.?] = docOf("a", "one.md", "1");
    try testing.expectEqual(@as(usize, 1), docs.len);
    try testing.expect(unchangedBy(&docs, "one.md", "1"));
}

test "a second add of the same name and content is a no-op, a changed one is an update" {
    const docs = [_]Doc{ docOf("kb-1", "notes.md", "first"), docOf("kb-2", "other.md", "x") };
    try testing.expect(unchangedBy(&docs, "notes.md", "first"));
    try testing.expect(!unchangedBy(&docs, "notes.md", "second"));
    // A name the collection does not have is never "unchanged", however
    // plausible the content looks.
    try testing.expect(!unchangedBy(&docs, "new.md", "first"));
}

test "a collection file written by the guest parses here, title and docs included" {
    // The `POST /api/run` knowledge inject reads this record natively
    // (`src/cli.zig`) rather than dispatching the guest, so the field names
    // below are the contract between the two. A field renamed in the guest
    // without the host following fails here, where a private copy of the
    // struct would have gone on parsing as an empty string.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const raw =
        \\{"id":"notes","title":"Notes","description":"d","created":1,"updated":2,
        \\ "docs":[{"id":"kb-1","name":"a.md","content":"body","bytes":4,"created":7}]}
    ;
    const col = try std.json.parseFromSliceLeaky(Collection, arena_state.allocator(), raw, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("Notes", col.title);
    try testing.expectEqual(@as(usize, 1), col.docs.len);
    try testing.expectEqualStrings("body", col.docs[0].content);
    try testing.expectEqual(@as(usize, 4), col.docs[0].bytes);
}
