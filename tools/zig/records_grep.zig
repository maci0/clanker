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
const record_rename = @import("record_rename.zig");

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

/// Rewrites one inventory row's status in place, compare-and-swap against the
/// index as read. Every store keeps a second copy of a record's status in its
/// README, and only the `status` action writes both; the stores differ only in
/// which markers bound the inventory, so the read-modify-write lives here once.
pub fn setIndexStatus(
    index_path: []const u8,
    start_marker: []const u8,
    end_marker: []const u8,
    link: []const u8,
    label: []const u8,
) !bool {
    const idx = try readIndex(index_path);
    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    if (!try doc.setInventoryStatus(&updated.writer, idx.text, start_marker, end_marker, link, label)) return false;
    return writeIndex(index_path, idx, updated.written());
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
/// The `append` reply. `placement` is the part a caller cannot infer: an author
/// filling the scaffold's empty `## Root cause` and an author adding a brand
/// new section both call `append`, and only this says which happened.
pub fn appendResult(out: *lib.Out, path: []const u8, placement: doc.Placement) !void {
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("action");
    try s.write("append");
    try s.objectField("path");
    try s.write(path);
    switch (placement) {
        .end => {},
        .filled => |heading| {
            try s.objectField("filled");
            try s.write(heading);
            try s.objectField("note");
            try s.write("the block filled that section, which was present and empty, instead of being added at the end as a second copy of its heading");
        },
    }
    try s.endObject();
    lib.commit(out, &w);
}

/// The `update` reply. `replaced` is 1 for the ordinary unique-match update and
/// higher only when the caller asked for every copy.
pub fn updateResult(out: *lib.Out, path: []const u8, replaced: usize) !void {
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("action");
    try s.write("update");
    try s.objectField("path");
    try s.write(path);
    try s.objectField("replaced");
    try s.write(replaced);
    try s.endObject();
    lib.commit(out, &w);
}

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

/// The `open` reply the four numbered stores share: the record's own text,
/// plus the title and status read back out of it. `noun` names the record in
/// the refusals, article included ("an ADR", "a research note").
///
/// All four had their own byte-identical copy of this, differing only in that
/// noun and in the store they read from.
pub fn openNumbered(
    out: *lib.Out,
    obj: std.json.Value,
    dir: []const u8,
    statuses: []const []const u8,
    noun: []const u8,
) !void {
    const path = lib.str(obj, "path") catch
        return lib.fail(out, try std.fmt.allocPrint(lib.alloc, "open needs the path of {s}", .{noun}));
    if (!doc.isPathIn(dir, path))
        return lib.fail(out, try std.fmt.allocPrint(lib.alloc, "path must be a markdown file directly below {s}/", .{dir}));
    const raw = lib.fsRead(path) catch |err|
        return lib.failErr(out, err, try std.fmt.allocPrint(lib.alloc, "opening {s}", .{noun}));
    const text = try lib.alloc.dupe(u8, raw);

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("path");
    try s.write(path);
    try s.objectField("title");
    try s.write(doc.documentTitle(text));
    try s.objectField("status");
    try s.write(doc.statusFrom(text, statuses));
    try s.objectField("text");
    try s.write(text);
    try s.endObject();
    lib.commit(out, &w);
}

/// The `status` action's reply, identical across all five record stores: the
/// path, the label it now carries, and whether the store's README inventory
/// copy went with it. Only the note explaining a missed inventory write is
/// store-specific, and only the PRD store has a follow-up reminder, so both
/// are passed in.
pub fn writeStatusReply(
    out: *lib.Out,
    path: []const u8,
    label: []const u8,
    indexed: bool,
    note: []const u8,
    reminder: ?[]const u8,
) !void {
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("action");
    try s.write("status");
    try s.objectField("path");
    try s.write(path);
    try s.objectField("status");
    try s.write(label);
    try s.objectField("indexed");
    try s.write(indexed);
    if (!indexed) {
        try s.objectField("note");
        try s.write(note);
    }
    if (reminder) |r| {
        try s.objectField("reminder");
        try s.write(r);
    }
    try s.endObject();
    lib.commit(out, &w);
}

// -------------------------------------------------------------------- rename

/// Move a record to a new filename inside its own store, for the four stores
/// that share this half: `research` (flat) and `rfc`/`adr`/`prd` (numbered).
///
/// The store never changes -- the slug is a name, not a destination -- and in
/// a numbered store the record's `NNNN-` prefix is kept rather than renamed.
/// `record_rename.zig` carries that decision and the reasoning behind it, and
/// is where `zig build test` checks the arithmetic; everything here is the
/// host calls around it: the move, the compare-and-swap rewrite of the
/// inventory link, and the scan for references the caller now has to fix.
///
/// A reference scan is a filename grep over this store's own directory, which
/// is all the descriptor grants. It cannot see mentions elsewhere in the tree,
/// and in a numbered store it cannot see a citation written as "ADR 0031"
/// either, so the reply says both rather than letting an empty list read as
/// "nothing else names it".
///
/// `reports` keeps its own copy of this, because its rename spans two stores
/// (`docs/reports/` and `docs/runbooks/`) and re-applies the
/// `missing-clanker-tool-` marker; folding the two together is a later change.
pub fn renameRecord(
    out: *lib.Out,
    obj: std.json.Value,
    dir: []const u8,
    index_path: []const u8,
    numbered: bool,
    noun: []const u8,
) !void {
    const path = lib.str(obj, "path") catch
        return lib.fail(out, try std.fmt.allocPrint(lib.alloc, "rename needs the current path of {s}", .{noun}));
    if (!doc.isPathIn(dir, path))
        return lib.fail(out, try std.fmt.allocPrint(lib.alloc, "path must be a markdown file directly below {s}/", .{dir}));
    const slug = lib.str(obj, "slug") catch
        return lib.fail(out, "rename needs the new filename stem in slug");
    if (!doc.isSlug(slug))
        return lib.fail(out, "a slug is lowercase letters, digits and single hyphens, and never starts or ends with one");

    const plan = record_rename.plan(lib.alloc, path, slug, numbered) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| return lib.fail(out, record_rename.reason(e)),
    };

    if (lib.fsRead(plan.new_path)) |_| {
        return lib.fail(out, "a record already exists at the new name");
    } else |_| {}
    _ = lib.fsRead(path) catch |err| return lib.failErr(out, err, "opening the record before rename");
    lib.fsRename(path, plan.new_path) catch |err| return lib.failErr(out, err, "renaming the record");

    // The inventory link is the second copy of the name; rewrite it under CAS
    // like every other index edit. Links in these four stores are the bare
    // filename, one directory level with a `.md` suffix, so a global replace
    // cannot reach a different record's link as a substring. In a numbered
    // store the link *text* ("ADR 0048 -- <title>") carries the number, and
    // keeping the number is exactly what leaves that text still correct.
    const indexed = renameInventoryLink(index_path, plan.old_stem, plan.new_stem) catch false;

    var refs: std.ArrayList([]const u8) = .empty;
    var refs_ok = true;
    collectRenameReferences(&refs, dir, index_path, plan.old_stem) catch {
        refs_ok = false;
    };

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("action");
    try s.write("rename");
    try s.objectField("from");
    try s.write(path);
    try s.objectField("to");
    try s.write(plan.new_path);
    try s.objectField("indexed");
    try s.write(indexed);
    if (!indexed) {
        try s.objectField("note");
        try s.write("the record was renamed, but its inventory line could not be rewritten (missing link or a concurrent edit); fix the README link by hand");
    }
    try s.objectField("references");
    try s.beginArray();
    for (refs.items) |r| try s.write(r);
    try s.endArray();
    try s.objectField("references_note");
    try s.write(if (!refs_ok)
        try std.fmt.allocPrint(lib.alloc, "the reference scan failed, so this list is incomplete -- search {s}/ and the rest of the tree for the old name by hand", .{dir})
    else if (numbered)
        try std.fmt.allocPrint(lib.alloc, "files inside {s}/ still naming the old filename; mentions elsewhere in the tree are outside this tool's grants, and a citation written as a bare number is not a filename and is never listed here -- the number did not change, so those citations still resolve", .{dir})
    else
        try std.fmt.allocPrint(lib.alloc, "files inside {s}/ still naming the old record; mentions elsewhere in the tree are outside this tool's grants -- search for the old name there too", .{dir}));
    try s.endObject();
    lib.commit(out, &w);
}

/// Rewrite every inventory occurrence of `<old_stem>.md` to `<new_stem>.md` in
/// one compare-and-swap write. False means the link is absent or the index
/// changed concurrently, which leaves a renamed record with a stale index line
/// rather than failing the move that already happened.
fn renameInventoryLink(index_path: []const u8, old_stem: []const u8, new_stem: []const u8) !bool {
    const old_link = try std.fmt.allocPrint(lib.alloc, "{s}.md", .{old_stem});
    const new_link = try std.fmt.allocPrint(lib.alloc, "{s}.md", .{new_stem});
    const idx = try readIndex(index_path);
    if (std.mem.find(u8, idx.text, old_link) == null) return false;
    const size = std.mem.replacementSize(u8, idx.text, old_link, new_link);
    const updated = try lib.alloc.alloc(u8, size);
    _ = std.mem.replace(u8, idx.text, old_link, new_link, updated);
    return writeIndex(index_path, idx, updated);
}

/// Append to `refs` each file under `dir` still containing `needle`, skipping
/// the inventory index (already rewritten) and duplicates. An unreadable store
/// is no references; an unparsable grep result is an error, so a broken scan
/// never reads as a clean one.
///
/// `ck_fs_grep` reports each hit's `file` relative to the *sandbox root*, not
/// to the directory it was asked to search (`fsGrepRecurse` seeds its prefix
/// with the requested path), so a hit already reads `docs/research/x.md` and
/// prefixing the store onto it again produces `docs/research/docs/research/…`.
///
/// Shared with `reports`, which had its own copy of this walk with the join and
/// no guard: every leftover reference it printed named
/// `docs/reports/docs/reports/…`, a path that cannot be opened, and that list
/// is the only reason to run `rename` rather than `git mv`. One copy now, so
/// the two cannot disagree again — and the containment test is `doc.isUnder`
/// rather than `doc.isPathIn`, because `docs/reports` is the one store whose
/// records nest a level down and the strict predicate answered no for exactly
/// the caller that needed a yes.
pub fn collectRenameReferences(
    refs: *std.ArrayList([]const u8),
    dir: []const u8,
    index_path: []const u8,
    needle: []const u8,
) !void {
    const raw = lib.fsGrep(dir, needle) catch |err| switch (err) {
        error.NotFound => return,
        else => return err,
    };
    const hits = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{}) catch return error.UnparsableGrepResult;
    if (hits != .array) return error.UnparsableGrepResult;
    for (hits.array.items) |hit| {
        if (hit != .object) continue;
        const file = hit.object.get("file") orelse continue;
        if (file != .string) continue;
        // Defensive: take the path as given when it is already store-rooted,
        // and join only if some future host ever reports it store-relative.
        const full = if (doc.isUnder(dir, file.string))
            try lib.alloc.dupe(u8, file.string)
        else
            try std.fmt.allocPrint(lib.alloc, "{s}/{s}", .{ dir, file.string });
        if (std.mem.eql(u8, full, index_path)) continue;
        var seen = false;
        for (refs.items) |r| {
            if (std.mem.eql(u8, r, full)) {
                seen = true;
                break;
            }
        }
        if (!seen) try refs.append(lib.alloc, full);
    }
}
