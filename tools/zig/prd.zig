//! prd: write and maintain product requirement docs under `docs/prds/`.
//!
//! A PRD is what a feature is *meant to be*: the problem, the goals, the
//! mechanism, and the acceptance criteria it is checked against. It is not a
//! decision record — `docs/README.md` puts decisions in `docs/adrs/` and open
//! questions in `docs/rfcs/` — and it is not the narrative of what shipped,
//! which is `docs/ROADMAP.md`.
//!
//! Two things make this store different from the RFC and ADR ones, and both
//! are why it is a separate guest rather than a parameter:
//!
//! - Its inventory is a Markdown **table** with a Notes column, so it uses
//!   `doc_scaffold`'s row helpers rather than the list ones.
//! - Its statuses are phrases ("In progress"), which `statusWord` would cut at
//!   the space, so listing reads them through `statusFrom` against a fixed
//!   vocabulary.
//!
//! `docs/prds/README.md` states the bar a Draft has to clear before it counts
//! as planned: dependencies named, blocking questions settled in Design rather
//! than parked, and implementation phases that are checkable. `checklist`
//! returns exactly that, because the failure mode here is not a missing
//! document but a Draft that reads finished and cannot be started from.
//!
//! Input:  {"action":"list"}
//!         {"action":"checklist"}
//!         {"action":"create", "title":"...", "problem":"...", "goals":"...",
//!          "status":"draft", "slug":"...", "notes":"..."}
//!         {"action":"open",   "path":"docs/prds/0001-x.md"}
//!         {"action":"search", "query":"..."}
//!         {"action":"append", "path":"...", "content":"..."}
//!         {"action":"update", "path":"...", "old":"...", "new":"..."}
//!         {"action":"status", "path":"...", "status":"shipped", "note":"..."}
//!         {"action":"rename", "path":"docs/prds/0001-x.md", "slug":"new-name"}
//! Output: {"ok":true, ...}

const std = @import("std");
const lib = @import("lib.zig");
const doc = @import("doc_scaffold.zig");
const records_grep = @import("records_grep.zig");

/// `list` reads every PRD to report its real status rather than trusting the
/// index. PRDs are the longest documents in the tree, so the per-read cap
/// below matters more here than it does for an RFC or an ADR.
pub const host_arena_cap = 2 * 1024 * 1024;

const dir = "docs/prds";
const adr_dir = "docs/adrs";
const index_path = dir ++ "/README.md";
const template_path = dir ++ "/TEMPLATE.md";
const inventory_start = "<!-- inventory:prd:start -->";
const inventory_end = "<!-- inventory:prd:end -->";

/// The statuses a PRD carries, longest phrase first so a line containing "In
/// progress" is not matched as something shorter that happens to sit inside
/// it. `docs/prds/README.md` documents the first three; the rest are wordings
/// already in the tree that a reader should still see reported truthfully.
const statuses = [_][]const u8{ "In progress", "Shipped", "Draft" };

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const obj = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    const action = lib.optStr(obj, "action") orelse "list";

    if (std.mem.eql(u8, action, "list")) return list(out);
    if (std.mem.eql(u8, action, "checklist")) return checklist(out);
    if (std.mem.eql(u8, action, "create")) return create(obj, out);
    if (std.mem.eql(u8, action, "open")) return open(obj, out);
    if (std.mem.eql(u8, action, "search")) return search(obj, out);
    if (std.mem.eql(u8, action, "append")) return append(obj, out);
    if (std.mem.eql(u8, action, "update")) return update(obj, out);
    if (std.mem.eql(u8, action, "status")) return status(obj, out);
    if (std.mem.eql(u8, action, "rename")) return rename(obj, out);
    return lib.fail(out, "action must be list, checklist, create, open, search, append, update, status, or rename");
}

// ---------------------------------------------------------------- checklist

const Item = struct { needs: []const u8, why: []const u8, ask: []const u8 };

/// What separates a Draft that can be built from one that only looks finished.
/// Taken from the editing rules in `docs/prds/README.md` and the Draft bar in
/// `TEMPLATE.md`, so the tool and the store agree on what "planned" means.
const requirements = [_]Item{
    .{
        .needs = "The problem, stated from the situation, not the solution",
        .why = "A problem written as 'we need X' has already picked X, and the design is then decoration",
        .ask = "What breaks or is impossible today, and what real constraint shaped the answer?",
    },
    .{
        .needs = "Numbered goals, each checkable",
        .why = "Goals and acceptance criteria have to cover each other; a goal with no matching checkbox is either wrong or untested",
        .ask = "What must be true for this to be done, as a numbered list?",
    },
    .{
        .needs = "Non-goals, with why leaving each out is a feature",
        .why = "An unmarked omission gets 'fixed' by the next reader",
        .ask = "What is this deliberately not doing, and why is that the right call?",
    },
    .{
        .needs = "Dependencies: PRDs, ADRs and code this rides on",
        .why = "A Draft that does not name its blockers cannot be scheduled, only started",
        .ask = "What has to exist first, and which of those are hard blockers?",
    },
    .{
        .needs = "Implementation phases with file paths",
        .why = "Phases that name files are checkable; phases that name intentions are not",
        .ask = "What are the numbered phases, and which files does each create or edit?",
    },
    .{
        .needs = "Failure modes as condition -> behaviour",
        .why = "Otherwise every 'what happens when X goes wrong' answer costs a source read",
        .ask = "What goes wrong, and what does the system do when it does?",
    },
    .{
        .needs = "Acceptance criteria, honestly unchecked",
        .why = "A checked box that is aspirational is worse than an unchecked one that names the gap",
        .ask = "Which criteria are true today, and which are not yet?",
    },
};

fn checklist(out: *lib.Out) !void {
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("requirements");
    try s.beginArray();
    for (requirements) |item| {
        try s.beginObject();
        try s.objectField("needs");
        try s.write(item.needs);
        try s.objectField("why");
        try s.write(item.why);
        try s.objectField("ask");
        try s.write(item.ask);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("next");
    try s.beginArray();
    try s.write("Answer each from the request where you can; put the rest to the operator with ask_user rather than inventing a scope.");
    try s.write("Decide the blocking questions in Design. Open questions is for follow-on work, not for choices that stop implementation from starting.");
    try s.write("A bug belongs in Known issues, never in Open questions — even when fixing it is future work.");
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

// ------------------------------------------------------------------- create

fn create(obj: std.json.Value, out: *lib.Out) !void {
    const title = lib.str(obj, "title") catch
        return lib.fail(out, "create needs a title naming the feature, e.g. 'Scheduled runs'");
    if (title.len > 180) return lib.fail(out, "title is too long (maximum 180 bytes)");
    const problem = lib.str(obj, "problem") catch
        return lib.fail(out, "create needs a problem: what breaks or is impossible without this, stated from the situation that forced it rather than from the solution. Run {\"action\":\"checklist\"} if the request does not say");
    if (problem.len > 6000) return lib.fail(out, "problem is too long (maximum 6000 bytes); the detail belongs in the document body");
    const goals = lib.str(obj, "goals") catch
        return lib.fail(out, "create needs goals: numbered and verifiable, each checkable against an acceptance criterion");
    if (goals.len > 6000) return lib.fail(out, "goals is too long (maximum 6000 bytes)");

    const wanted_status = lib.optStr(obj, "status") orelse "draft";
    const status_label = labelFor(wanted_status) orelse
        return lib.fail(out, "status must be draft, in_progress, or shipped");
    const notes = lib.optStr(obj, "notes") orelse "";
    if (notes.len > 200) return lib.fail(out, "notes is the inventory's Notes cell and has to stay short (maximum 200 bytes)");
    // A pipe would split the cell and silently shift every column after it.
    if (std.mem.find(u8, notes, "|") != null)
        return lib.fail(out, "notes cannot contain '|': it is written into a Markdown table cell");

    var slug_buf: [96]u8 = undefined;
    const slug = if (lib.optStr(obj, "slug")) |given| given else doc.slugify(title, &slug_buf, 60);
    if (!doc.isSlug(slug))
        return lib.fail(out, "slug must be lowercase letters, digits and hyphens (no leading or trailing hyphen)");

    const next = try records_grep.nextRecord(out, dir, slug) orelse return;

    const raw_template = lib.fsRead(template_path) catch |err| switch (err) {
        error.NotFound => return lib.fail(out, "docs/prds/TEMPLATE.md is missing; restore it before creating a PRD"),
        else => return lib.failErr(out, err, "reading the PRD template"),
    };
    const template = try lib.alloc.dupe(u8, raw_template);

    var date_buf: [16]u8 = undefined;
    const date = try lib.alloc.dupe(u8, doc.isoDate(@trunc(lib.nowSeconds()), &date_buf));

    const status_line = try std.fmt.allocPrint(
        lib.alloc,
        "{s} — opened {s}. Name the source files that are the single source of truth, and the surfaces that expose it.",
        .{ status_label, date },
    );

    var rendered: std.Io.Writer.Allocating = .init(lib.alloc);
    defer rendered.deinit();
    try doc.fillTemplate(&rendered.writer, template, &.{
        .{ .name = "number", .value = next.number_text },
        .{ .name = "title", .value = title },
        .{ .name = "date", .value = date },
        .{ .name = "status", .value = status_line },
        .{ .name = "problem", .value = problem },
        .{ .name = "goals", .value = goals },
    });

    lib.fsWriteIf(next.path, "", rendered.written()) catch |err| switch (err) {
        error.Mismatch => return lib.fail(out, "a PRD already exists at that path; list first and open it instead"),
        else => return lib.failErr(out, err, "creating the PRD"),
    };

    const row = try std.fmt.allocPrint(
        lib.alloc,
        "| [{s}]({s}-{s}.md) | {s} | {s} | {s} |",
        .{ next.number_text, next.number_text, slug, title, status_label, notes },
    );
    const indexed = addToInventory(row) catch false;

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("created");
    try s.write(true);
    try s.objectField("path");
    try s.write(next.path);
    try s.objectField("number");
    try s.write(@as(u64, next.number));
    try s.objectField("status");
    try s.write(status_label);
    try s.objectField("indexed");
    try s.write(indexed);
    if (!indexed) {
        try s.objectField("note");
        try s.write("the PRD was created but the inventory changed concurrently or lacks its markers; add the row to docs/prds/README.md by hand");
    }
    try s.objectField("next");
    try s.beginArray();
    try s.write("Fill Non-goals, Design, Failure modes and Acceptance criteria. Goals and acceptance criteria have to cover each other.");
    try s.write("A Draft is not planned until Dependencies are named and Implementation lists checkable file-level phases. Settle blocking questions in Design, not under Open questions.");
    try s.write("When the code drifts from this document, fix the PRD the same day: Status, Design, and Acceptance, not only Known issues.");
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

// --------------------------------------------------------------- inventory

/// The PRD index is a table, not a list, so the row helpers are the ones that
/// apply. A new row lands at the bottom: numbered documents read upwards.
fn addToInventory(row: []const u8) !bool {
    const idx = try records_grep.readIndex(index_path);

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    if (!try doc.insertInventoryRow(&updated.writer, idx.text, inventory_start, inventory_end, row)) return false;
    return records_grep.writeIndex(index_path, idx, updated.written());
}

/// Rewrites only the status cell, leaving the Notes column alone — the note is
/// a human's summary of where the PRD stands and a status change is not a
/// reason to lose it.
fn setInventoryStatus(link: []const u8, label: []const u8) !bool {
    const idx = try records_grep.readIndex(index_path);

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    if (!try doc.setInventoryRowStatus(&updated.writer, idx.text, inventory_start, inventory_end, link, label)) return false;
    return records_grep.writeIndex(index_path, idx, updated.written());
}

// -------------------------------------------------------------------- reads

fn list(out: *lib.Out) !void {
    return records_grep.listNumbered(out, dir, "prds", "PRDs", &statuses);
}

fn open(obj: std.json.Value, out: *lib.Out) !void {
    return records_grep.openNumbered(out, obj, dir, &statuses, "a PRD");
}

/// Searches the PRDs and the ADRs together: an ADR is what *constrains* a
/// feature's design, and a PRD proposing something an ADR already forecloses
/// is the mistake worth catching before it is written.
fn search(obj: std.json.Value, out: *lib.Out) !void {
    const query = lib.str(obj, "query") catch
        return lib.fail(out, "search needs a non-empty query");
    if (query.len > 240) return lib.fail(out, "query is too long (maximum 240 bytes)");

    const prds = try records_grep.grepRecords(dir, query);
    const adrs = try records_grep.grepRecords(adr_dir, query);

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("query");
    try s.write(query);
    try s.objectField("prds");
    try s.write(prds);
    try s.objectField("adrs");
    try s.write(adrs);
    try s.objectField("note");
    try s.write("An ADR match is a decision that constrains this feature's design; read it before specifying around it.");
    try s.endObject();
    lib.commit(out, &w);
}

// ---------------------------------------------------------------- mutations

fn append(obj: std.json.Value, out: *lib.Out) !void {
    const path = lib.str(obj, "path") catch
        return lib.fail(out, "append needs the path of a PRD");
    if (!doc.isPathIn(dir, path)) return lib.fail(out, "path must be a markdown file directly below docs/prds/");
    const content = lib.str(obj, "content") catch
        return lib.fail(out, "append needs non-empty markdown content");
    const raw = lib.fsRead(path) catch |err| return lib.failErr(out, err, "opening the PRD before append");
    const text = try lib.alloc.dupe(u8, raw);
    const expected = try lib.alloc.dupe(u8, try lib.hash(text));

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    try doc.appendBlock(&updated.writer, text, content);
    lib.fsWriteIf(path, expected, updated.written()) catch |err| switch (err) {
        error.Mismatch => return lib.fail(out, "the PRD changed while appending; open it again and retry against the current text"),
        else => return lib.failErr(out, err, "appending to the PRD"),
    };
    return records_grep.mutationResult(out, "append", path);
}

fn update(obj: std.json.Value, out: *lib.Out) !void {
    const path = lib.str(obj, "path") catch
        return lib.fail(out, "update needs the path of a PRD");
    if (!doc.isPathIn(dir, path)) return lib.fail(out, "path must be a markdown file directly below docs/prds/");
    const old = lib.str(obj, "old") catch
        return lib.fail(out, "update needs the exact non-empty old text from an open result");
    const new = lib.optStr(obj, "new") orelse
        return lib.fail(out, "update needs replacement text in new (it may be empty to remove old)");
    const raw = lib.fsRead(path) catch |err| return lib.failErr(out, err, "opening the PRD before update");
    const text = try lib.alloc.dupe(u8, raw);
    const expected = try lib.alloc.dupe(u8, try lib.hash(text));

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    doc.spliceReplace(&updated.writer, text, old, new) catch |err| switch (err) {
        doc.SpliceError.NotFound => return lib.fail(out, "old text was not found; open the current PRD and copy the exact text"),
        doc.SpliceError.Ambiguous => return lib.fail(out, "old text appears more than once; include more surrounding text so the update is unambiguous"),
        else => return err,
    };
    lib.fsWriteIf(path, expected, updated.written()) catch |err| switch (err) {
        error.Mismatch => return lib.fail(out, "the PRD changed while updating; open it again and retry against the current text"),
        else => return lib.failErr(out, err, "updating the PRD"),
    };
    return records_grep.mutationResult(out, "update", path);
}

fn status(obj: std.json.Value, out: *lib.Out) !void {
    const path = lib.str(obj, "path") catch
        return lib.fail(out, "status needs the path of a PRD");
    if (!doc.isPathIn(dir, path)) return lib.fail(out, "path must be a markdown file directly below docs/prds/");
    const wanted = lib.str(obj, "status") catch
        return lib.fail(out, "status needs one of draft, in_progress, shipped");
    const label = labelFor(wanted) orelse
        return lib.fail(out, "status must be draft, in_progress, or shipped");
    const note = lib.optStr(obj, "note") orelse "";
    // "Shipped" means the code is the source of truth. Naming it is what
    // makes the claim checkable by the next reader instead of taken on trust.
    if (std.mem.eql(u8, label, "Shipped") and note.len == 0)
        return lib.fail(out, "a shipped PRD needs a note naming the source files that are now the single source of truth, and the surfaces that expose it");

    const raw = lib.fsRead(path) catch |err| return lib.failErr(out, err, "opening the PRD before a status change");
    const text = try lib.alloc.dupe(u8, raw);
    const expected = try lib.alloc.dupe(u8, try lib.hash(text));

    var date_buf: [16]u8 = undefined;
    const date = doc.isoDate(@trunc(lib.nowSeconds()), &date_buf);
    const line = if (note.len > 0)
        try std.fmt.allocPrint(lib.alloc, "{s} — {s}. {s}", .{ label, date, note })
    else
        try std.fmt.allocPrint(lib.alloc, "{s} — {s}.", .{ label, date });

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    if (!try doc.replaceFirstLine(&updated.writer, text, "## Status", line))
        return lib.fail(out, "the PRD has no '## Status' section; add one or edit it with update");
    lib.fsWriteIf(path, expected, updated.written()) catch |err| switch (err) {
        error.Mismatch => return lib.fail(out, "the PRD changed while setting its status; open it again and retry"),
        else => return lib.failErr(out, err, "setting the PRD status"),
    };

    // PRD and index are separate files, so this cannot be one atomic write. A
    // CAS miss leaves the PRD correct and names the row to reconcile.
    const indexed = setInventoryStatus(std.fs.path.basename(path), label) catch false;

    try records_grep.writeStatusReply(out, path, label, indexed, "the PRD's status changed, but its docs/prds/README.md inventory row could not be updated (missing row or markers, or a concurrent edit); set that row's Status cell by hand so the index does not disagree with the PRD", if (std.mem.eql(u8, label, "Shipped")) "Re-verify the Acceptance criteria against the code, not only Design: a checked box that is aspirational is worse than an unchecked one that names the gap." else null);
}

/// Derived from `statuses`, so what `status` accepts and what `list` reads
/// back off a record cannot drift apart. `in_progress` is spelled with an
/// underscore on the wire and a space in the document; `labelFrom` reads both.
fn labelFor(wanted: []const u8) ?[]const u8 {
    return doc.labelFrom(wanted, &statuses);
}

/// Move the record to a new filename in this store. In a numbered store the
/// `NNNN-` prefix is the record's identity and is kept: records are cited by
/// number across the tree ("ADR 0031", "PRD 0021") and a filename scan cannot
/// find those citations, so a renumber would break references this tool could
/// not even list. `records_grep.renameRecord` is the shared half;
/// `record_rename.zig` carries the arithmetic and the full reasoning.
fn rename(obj: std.json.Value, out: *lib.Out) !void {
    return records_grep.renameRecord(out, obj, dir, index_path, true, "a PRD");
}
