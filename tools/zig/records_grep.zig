//! The record stores' shared guest-ABI half: search matching and the
//! numbered stores' listing, in one place.
//!
//! `search` used to hand the whole query to one host grep, which is an exact
//! substring per line. That is the phrase form with no way to ask for the
//! other one, so `reports search "concurrent sessions"` answered "no report or
//! runbook mentions it" while
//! `docs/runbooks/concurrent-agent-sessions-on-one-checkout.md` sat in the
//! store saying both words on different lines, and the caller concluded the
//! runbook was missing. A search over the project's own memory that misses an
//! existing record is the expensive failure: the answer is a duplicate record,
//! not an empty result.
//!
//! So a query is a set of terms every record must contain, `"a quoted phrase"`
//! is one term, and a one-word query behaves exactly as it always did. The
//! splitting and the intersection are pure and live in `doc_scaffold.zig`
//! where `zig build test` can run them; what stays here is the half that
//! calls the host (one grep per term, one header read per listed record),
//! which is why the module is not in the pure-tool list.

const std = @import("std");
const lib = @import("lib.zig");
const doc = @import("doc_scaffold.zig");

/// Hits for the records under `dir` that contain every term in `query`, as the
/// same `[{"file":...,"line":...,"text":...}]` array a single grep returns.
///
/// One host call per term, each parsed before the next is issued: a host
/// response lives in the shared host arena and the following call overwrites
/// it. `error.NotFound` still means the store directory is absent, which is a
/// normal fresh checkout.
///
/// Each grep is separately capped by the host's result limit, so a term that
/// hits the cap can hide a record a rarer term would have kept. That trade is
/// deliberate: the alternative is reading every record into the guest arena.
pub fn grepAll(dir: []const u8, query: []const u8) lib.FsError!std.json.Value {
    var term_buf: [doc.max_search_terms][]const u8 = undefined;
    const terms = doc.searchTerms(query, &term_buf);
    var per_term: [doc.max_search_terms]std.json.Value = undefined;
    for (terms, 0..) |term, i| {
        const raw = try lib.fsGrep(dir, term);
        per_term[i] = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{}) catch
            return error.IoError;
    }
    return doc.intersectHits(lib.alloc, per_term[0..terms.len]) catch return error.TooLarge;
}

/// Reading every record in `list` is bounded so a store that grew past the
/// arena degrades into a listing instead of an error.
pub const max_listed_reads: usize = 60;

/// The numbered stores' `list`: `{"ok":true, "<field>":[{path,title,status}],
/// "next_number":N}`, plus `unread` and a note when the cap was hit.
///
/// The index can drift, so the document is the truth about its own status and
/// is read rather than trusted -- but only its header is: title and status
/// both live in the first few lines, and a whole-document read per row is what
/// exhausts the guest arena.
pub fn listNumbered(
    out: *lib.Out,
    dir: []const u8,
    field: []const u8,
    plural: []const u8,
    statuses: []const []const u8,
) !void {
    const raw_names = lib.fsList(dir) catch "[]";
    const listing = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw_names, .{}) catch
        return lib.fail(out, try std.fmt.allocPrint(lib.alloc, "could not read the {s} listing", .{dir}));

    const Row = struct { path: []const u8, title: []const u8, status: []const u8 };
    var rows: std.ArrayList(Row) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var unread: usize = 0;
    if (listing == .array) {
        for (listing.array.items) |item| {
            if (item != .string) continue;
            // The host arena the listing points into is overwritten by the
            // header reads below, so every name is copied before the first one.
            const name = try lib.alloc.dupe(u8, item.string);
            try names.append(lib.alloc, name);
            if (!doc.isDocFile(name)) continue;
            const path = try std.fmt.allocPrint(lib.alloc, "{s}/{s}", .{ dir, name });
            const header: ?[]const u8 = if (rows.items.len >= max_listed_reads) null else blk: {
                const raw = lib.fsReadRange(path, 0, doc.header_read_bytes) catch break :blk null;
                break :blk try lib.alloc.dupe(u8, raw);
            };
            if (header) |text| {
                try rows.append(lib.alloc, .{
                    .path = path,
                    .title = doc.documentTitle(text),
                    .status = doc.statusFrom(text, statuses),
                });
            } else {
                unread += 1;
                try rows.append(lib.alloc, .{ .path = path, .title = "", .status = "" });
            }
        }
    }

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField(field);
    try s.beginArray();
    for (rows.items) |row| {
        try s.beginObject();
        try s.objectField("path");
        try s.write(row.path);
        try s.objectField("title");
        try s.write(row.title);
        try s.objectField("status");
        try s.write(row.status);
        try s.endObject();
    }
    try s.endArray();
    if (unread > 0) {
        try s.objectField("unread");
        try s.write(@as(u64, unread));
        try s.objectField("note");
        try s.write(try std.fmt.allocPrint(
            lib.alloc,
            "some {s} were listed without reading their status; open them individually",
            .{plural},
        ));
    }
    try s.objectField("next_number");
    try s.write(@as(u64, doc.nextNumber(names.items)));
    try s.endObject();
    lib.commit(out, &w);
}

/// A store's index as read, with the hash the write-back must still match.
pub const Index = struct { text: []const u8, expected: []const u8 };

/// Reads an index for editing. Both fields are copied out of the host arena,
/// which the write-back call overwrites.
pub fn readIndex(path: []const u8) !Index {
    const raw = try lib.fsRead(path);
    const text = try lib.alloc.dupe(u8, raw);
    return .{ .text = text, .expected = try lib.alloc.dupe(u8, try lib.hash(text)) };
}

/// Writes an edited index back, compare-and-swap. False means someone else
/// edited it first: the record itself is already written, so the caller
/// reports an unindexed record rather than failing the whole action.
pub fn writeIndex(path: []const u8, index: Index, updated: []const u8) !bool {
    lib.fsWriteIf(path, index.expected, updated) catch |err| switch (err) {
        error.Mismatch => return false,
        else => return err,
    };
    return true;
}

/// `grepAll` narrowed to the store's records: a missing or unreadable store is
/// an empty result, not an error, and non-record files are dropped.
///
/// The index lists every record by title, so an unfiltered grep answers one
/// real hit with an inventory line stapled to it. `isDocPath` drops those and
/// the template: neither is a record, and neither is what a searcher meant.
pub fn grepRecords(dir: []const u8, query: []const u8) !std.json.Value {
    const parsed = grepAll(dir, query) catch |err| switch (err) {
        error.NotFound, error.IoError => return .{ .array = std.json.Array.init(lib.alloc) },
        else => return err,
    };
    if (parsed != .array) return .{ .array = std.json.Array.init(lib.alloc) };

    var kept = std.json.Array.init(lib.alloc);
    for (parsed.array.items) |hit| {
        if (hit != .object) continue;
        const file = hit.object.get("file") orelse continue;
        if (file != .string or !doc.isDocPath(file.string)) continue;
        try kept.append(hit);
    }
    return .{ .array = kept };
}

/// The number and path the next record in `dir` takes, one past the highest
/// already there.
pub const NextRecord = struct { number: u32, number_text: []const u8, path: []const u8 };

/// Null once the listing was unreadable and the refusal has been written to
/// `out`.
pub fn nextRecord(out: *lib.Out, dir: []const u8, slug: []const u8) !?NextRecord {
    const raw_names = lib.fsList(dir) catch "[]";
    const listing = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw_names, .{}) catch {
        try lib.fail(out, try std.fmt.allocPrint(lib.alloc, "could not read the {s} listing", .{dir}));
        return null;
    };
    var names: std.ArrayList([]const u8) = .empty;
    if (listing == .array) {
        for (listing.array.items) |item| {
            if (item != .string) continue;
            try names.append(lib.alloc, try lib.alloc.dupe(u8, item.string));
        }
    }
    const number = doc.nextNumber(names.items);
    const number_text = try std.fmt.allocPrint(lib.alloc, "{d:0>4}", .{number});
    return .{
        .number = number,
        .number_text = number_text,
        .path = try std.fmt.allocPrint(lib.alloc, "{s}/{s}-{s}.md", .{ dir, number_text, slug }),
    };
}

/// The `{"ok":true,"action":...,"path":...}` reply every record store returns
/// from a write. All five stores answered in exactly this shape from their own
/// copy of this function; one copy keeps the wire contract single-sourced.
pub fn mutationResult(out: *lib.Out, action: []const u8, path: []const u8) !void {
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("action");
    try s.write(action);
    try s.objectField("path");
    try s.write(path);
    try s.endObject();
    lib.commit(out, &w);
}
