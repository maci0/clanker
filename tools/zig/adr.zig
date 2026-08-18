//! adr: record and maintain architecture decisions under `docs/adrs/`.
//!
//! An ADR is the decision *after* it is made. The [RFC](rfc.zig) that may
//! precede it argues the alternatives; this record states what was chosen and
//! what that costs. The two stores are searched together for that reason —
//! `docs/README.md` calls an ADR "a decision that has been made", and finding
//! one is the answer that should stop a question from being re-opened.
//!
//! An RFC is not required for an ADR and an ADR is not required for an RFC.
//! `create` therefore takes an optional `rfc`: when one is passed it is linked
//! from Status and the RFC's own recommendation is lifted in as the starting
//! Decision, because a decision that contradicts the RFC it came from is worth
//! seeing side by side rather than writing from memory.
//!
//! The tool does not decide anything. It allocates the number, renders
//! `docs/adrs/TEMPLATE.md`, keeps `docs/adrs/README.md` true, and refuses the
//! two shapes an ADR is worthless in: a decision with no consequences written
//! down, and a supersede that does not say what replaced it.
//!
//! Input:  {"action":"list"}
//!         {"action":"create", "title":"...", "context":"...", "decision":"...",
//!          "consequences":"...", "rfc":"docs/rfcs/0001-x.md", "slug":"..."}
//!         {"action":"open",   "path":"docs/adrs/0001-x.md"}
//!         {"action":"search", "query":"..."}
//!         {"action":"append", "path":"...", "content":"..."}
//!         {"action":"update", "path":"...", "old":"...", "new":"..."}
//!         {"action":"status", "path":"...", "status":"superseded",
//!          "note":"Superseded by ADR 0021."}
//! Output: {"ok":true, ...}

const std = @import("std");
const lib = @import("lib.zig");
const doc = @import("doc_scaffold.zig");
const records_grep = @import("records_grep.zig");

/// `list` reads every ADR to report its real status rather than trusting the
/// index, and each read is bump-allocated out of the host arena for the whole
/// call — the same bound, and the same reason, as `rfc.zig`.
pub const host_arena_cap = 2 * 1024 * 1024;

const dir = "docs/adrs";
const rfc_dir = "docs/rfcs";
const prd_dir = "docs/prds";
const index_path = dir ++ "/README.md";
const template_path = dir ++ "/TEMPLATE.md";
const inventory_start = "<!-- inventory:adr:start -->";
const inventory_end = "<!-- inventory:adr:end -->";

/// The statuses an ADR carries. One word each, unlike a PRD's, but read
/// through `doc.statusFrom` all the same: `statusWord` cuts at the first
/// separator, so a Status line written `**Accepted.**` reads as `**Accepted`.
/// Matching the vocabulary makes the decoration irrelevant.
const statuses = [_][]const u8{ "Accepted", "Superseded", "Deprecated", "Proposed" };

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const obj = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    const action = lib.optStr(obj, "action") orelse "list";

    if (std.mem.eql(u8, action, "list")) return list(out);
    if (std.mem.eql(u8, action, "create")) return create(obj, out);
    if (std.mem.eql(u8, action, "open")) return open(obj, out);
    if (std.mem.eql(u8, action, "search")) return search(obj, out);
    if (std.mem.eql(u8, action, "append")) return append(obj, out);
    if (std.mem.eql(u8, action, "update")) return update(obj, out);
    if (std.mem.eql(u8, action, "status")) return status(obj, out);
    return lib.fail(out, "action must be list, create, open, search, append, update, or status");
}

// ------------------------------------------------------------------- create

fn create(obj: std.json.Value, out: *lib.Out) !void {
    const title = lib.str(obj, "title") catch
        return lib.fail(out, "create needs a title phrased as the choice made, e.g. 'Providers are a native vtable, not WASM'");
    if (title.len > 180) return lib.fail(out, "title is too long (maximum 180 bytes)");
    const context = lib.str(obj, "context") catch
        return lib.fail(out, "create needs a context: the constraint that forced a choice, and what the alternative was");
    if (context.len > 6000) return lib.fail(out, "context is too long (maximum 6000 bytes); the detail belongs in the document body");
    const decision = lib.str(obj, "decision") catch
        return lib.fail(out, "create needs the decision itself, stated plainly in one or two sentences");
    if (decision.len > 4000) return lib.fail(out, "decision is too long (maximum 4000 bytes); an ADR states the choice, not its implementation");

    // An ADR without consequences is a press release. The template says to
    // include the honest downside; requiring the section to be non-empty is
    // the only part of that a tool can actually hold to.
    const consequences = lib.str(obj, "consequences") catch
        return lib.fail(out, "create needs consequences: what this makes easy, what it forecloses, and the honest downside. An ADR that only argues for the decision is useless to whoever later asks whether to revisit it");
    if (consequences.len > 6000) return lib.fail(out, "consequences is too long (maximum 6000 bytes)");

    const rfc_path = lib.optStr(obj, "rfc") orelse "";
    if (rfc_path.len > 0 and !doc.isPathIn(rfc_dir, rfc_path))
        return lib.fail(out, "rfc must be a markdown file directly below docs/rfcs/");

    var slug_buf: [96]u8 = undefined;
    const slug = if (lib.optStr(obj, "slug")) |given| given else doc.slugify(title, &slug_buf, 60);
    if (!doc.isSlug(slug))
        return lib.fail(out, "slug must be lowercase letters, digits and hyphens (no leading or trailing hyphen)");

    // Read the RFC first: every later host call reuses the same arena, so its
    // text has to be copied into guest memory before then.
    var rfc_title: []const u8 = "";
    var rfc_recommendation: []const u8 = "";
    if (rfc_path.len > 0) {
        const raw = lib.fsRead(rfc_path) catch |err| switch (err) {
            error.NotFound => return lib.fail(out, "no RFC at that path; run the rfc tool's list action to see what exists"),
            else => return lib.failErr(out, err, "reading the RFC"),
        };
        const text = try lib.alloc.dupe(u8, raw);
        rfc_title = doc.documentTitle(text);
        rfc_recommendation = doc.firstLineOf(text, "## Recommendation");
    }

    const next = try records_grep.nextRecord(out, dir, slug) orelse return;

    const raw_template = lib.fsRead(template_path) catch |err| switch (err) {
        error.NotFound => return lib.fail(out, "docs/adrs/TEMPLATE.md is missing; restore it before creating an ADR"),
        else => return lib.failErr(out, err, "reading the ADR template"),
    };
    const template = try lib.alloc.dupe(u8, raw_template);

    var date_buf: [16]u8 = undefined;
    const date = try lib.alloc.dupe(u8, doc.isoDate(@trunc(lib.nowSeconds()), &date_buf));

    const status_line = if (rfc_path.len > 0)
        try std.fmt.allocPrint(
            lib.alloc,
            "Accepted — {s}. Records the decision opened in [{s}](../rfcs/{s}).",
            .{ date, if (rfc_title.len > 0) rfc_title else rfc_path, rfc_path[rfc_dir.len + 1 ..] },
        )
    else
        try std.fmt.allocPrint(lib.alloc, "Accepted — {s}.", .{date});

    // The RFC's recommendation is carried in as a quoted line under the
    // decision rather than replacing it: an ADR that merely restates its RFC
    // has not recorded a decision, and seeing the two together is what makes a
    // divergence obvious while it is still being written.
    const decision_body = if (rfc_recommendation.len > 0)
        try std.fmt.allocPrint(
            lib.alloc,
            "{s}\n\n> The RFC recommended: {s}\n",
            .{ decision, rfc_recommendation },
        )
    else
        decision;

    var rendered: std.Io.Writer.Allocating = .init(lib.alloc);
    defer rendered.deinit();
    try doc.fillTemplate(&rendered.writer, template, &.{
        .{ .name = "number", .value = next.number_text },
        .{ .name = "title", .value = title },
        .{ .name = "date", .value = date },
        .{ .name = "status", .value = status_line },
        .{ .name = "context", .value = context },
        .{ .name = "decision", .value = decision_body },
        .{ .name = "consequences", .value = consequences },
    });

    lib.fsWriteIf(next.path, "", rendered.written()) catch |err| switch (err) {
        error.Mismatch => return lib.fail(out, "an ADR already exists at that path; list first and open it instead"),
        else => return lib.failErr(out, err, "creating the ADR"),
    };

    const entry = try std.fmt.allocPrint(
        lib.alloc,
        "- [ADR {s} — {s}]({s}-{s}.md) — Accepted",
        .{ next.number_text, title, next.number_text, slug },
    );
    const indexed = addToInventory(entry) catch false;

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
    try s.objectField("indexed");
    try s.write(indexed);
    if (rfc_path.len > 0) {
        try s.objectField("rfc");
        try s.write(rfc_path);
    }
    if (!indexed) {
        try s.objectField("note");
        try s.write("the ADR was created but the inventory changed concurrently or lacks its markers; add the link to docs/adrs/README.md by hand");
    }
    try s.objectField("next");
    try s.beginArray();
    if (rfc_path.len > 0) {
        try s.write("Close the RFC out: {\"action\":\"status\",\"status\":\"decided\"} on the rfc tool, with a note naming this ADR.");
    } else {
        try s.write("If an RFC argued this decision, link it from Status; if none did, that is fine — an ADR does not require one.");
    }
    try s.write("Re-read Consequences as the person who will one day want to reverse this: it has to name what the decision forecloses, not only what it buys.");
    try s.write("A later reversal supersedes this ADR rather than editing it: {\"action\":\"status\",\"status\":\"superseded\",\"note\":\"Superseded by ADR NNNN.\"}");
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

// --------------------------------------------------------------- inventory

fn addToInventory(entry: []const u8) !bool {
    const idx = try records_grep.readIndex(index_path);

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    if (!try doc.insertInventory(&updated.writer, idx.text, inventory_start, inventory_end, entry)) return false;
    return records_grep.writeIndex(index_path, idx, updated.written());
}

/// The index carries its own copy of the status word, so every writer of the
/// record's status carries the index with it — an index only `create` writes
/// is wrong from the first status change onwards.
fn setInventoryStatus(link: []const u8, label: []const u8) !bool {
    const idx = try records_grep.readIndex(index_path);

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    if (!try doc.setInventoryStatus(&updated.writer, idx.text, inventory_start, inventory_end, link, label)) return false;
    return records_grep.writeIndex(index_path, idx, updated.written());
}

// -------------------------------------------------------------------- reads

fn list(out: *lib.Out) !void {
    return records_grep.listNumbered(out, dir, "adrs", "ADRs", &statuses);
}

fn open(obj: std.json.Value, out: *lib.Out) !void {
    return records_grep.openNumbered(out, obj, dir, &statuses, "an ADR");
}

/// Searches the ADRs, the RFCs, and the PRDs together. An ADR is the settled
/// answer, an RFC the open question over the same ground, and a PRD the
/// feature the decision constrains; which store a hit lands in is exactly the
/// information the searcher needs, so all three are reported separately.
fn search(obj: std.json.Value, out: *lib.Out) !void {
    const query = lib.str(obj, "query") catch
        return lib.fail(out, "search needs a non-empty query");
    if (query.len > 240) return lib.fail(out, "query is too long (maximum 240 bytes)");

    const adrs = try records_grep.grepRecords(dir, query);
    const rfcs = try records_grep.grepRecords(rfc_dir, query);
    const prds = try records_grep.grepRecords(prd_dir, query);

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("query");
    try s.write(query);
    try s.objectField("adrs");
    try s.write(adrs);
    try s.objectField("rfcs");
    try s.write(rfcs);
    try s.objectField("prds");
    try s.write(prds);
    try s.objectField("note");
    try s.write("An ADR match means the decision is already recorded; read it before opening an RFC that re-litigates it.");
    try s.endObject();
    lib.commit(out, &w);
}

// ---------------------------------------------------------------- mutations

fn append(obj: std.json.Value, out: *lib.Out) !void {
    const path = lib.str(obj, "path") catch
        return lib.fail(out, "append needs the path of an ADR");
    if (!doc.isPathIn(dir, path)) return lib.fail(out, "path must be a markdown file directly below docs/adrs/");
    const content = lib.str(obj, "content") catch
        return lib.fail(out, "append needs non-empty markdown content");
    const raw = lib.fsRead(path) catch |err| return lib.failErr(out, err, "opening the ADR before append");
    const text = try lib.alloc.dupe(u8, raw);
    const expected = try lib.alloc.dupe(u8, try lib.hash(text));

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    try doc.appendBlock(&updated.writer, text, content);
    lib.fsWriteIf(path, expected, updated.written()) catch |err| switch (err) {
        error.Mismatch => return lib.fail(out, "the ADR changed while appending; open it again and retry against the current text"),
        else => return lib.failErr(out, err, "appending to the ADR"),
    };
    return records_grep.mutationResult(out, "append", path);
}

fn update(obj: std.json.Value, out: *lib.Out) !void {
    const path = lib.str(obj, "path") catch
        return lib.fail(out, "update needs the path of an ADR");
    if (!doc.isPathIn(dir, path)) return lib.fail(out, "path must be a markdown file directly below docs/adrs/");
    const old = lib.str(obj, "old") catch
        return lib.fail(out, "update needs the exact non-empty old text from an open result");
    const new = lib.optStr(obj, "new") orelse
        return lib.fail(out, "update needs replacement text in new (it may be empty to remove old)");
    const raw = lib.fsRead(path) catch |err| return lib.failErr(out, err, "opening the ADR before update");
    const text = try lib.alloc.dupe(u8, raw);
    const expected = try lib.alloc.dupe(u8, try lib.hash(text));

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    doc.spliceReplace(&updated.writer, text, old, new) catch |err| switch (err) {
        doc.SpliceError.NotFound => return lib.fail(out, "old text was not found; open the current ADR and copy the exact text"),
        doc.SpliceError.Ambiguous => return lib.fail(out, "old text appears more than once; include more surrounding text so the update is unambiguous"),
        else => return err,
    };
    lib.fsWriteIf(path, expected, updated.written()) catch |err| switch (err) {
        error.Mismatch => return lib.fail(out, "the ADR changed while updating; open it again and retry against the current text"),
        else => return lib.failErr(out, err, "updating the ADR"),
    };
    return records_grep.mutationResult(out, "update", path);
}

fn status(obj: std.json.Value, out: *lib.Out) !void {
    const path = lib.str(obj, "path") catch
        return lib.fail(out, "status needs the path of an ADR");
    if (!doc.isPathIn(dir, path)) return lib.fail(out, "path must be a markdown file directly below docs/adrs/");
    const wanted = lib.str(obj, "status") catch
        return lib.fail(out, "status needs one of proposed, accepted, superseded, deprecated");
    const label = labelFor(wanted) orelse
        return lib.fail(out, "status must be proposed, accepted, superseded, or deprecated");
    const note = lib.optStr(obj, "note") orelse "";
    // A superseded ADR with no forward link is the failure this store exists
    // to prevent: the reasoning survives only if the reader can follow it to
    // whatever replaced it.
    if (std.mem.eql(u8, label, "Superseded") and note.len == 0)
        return lib.fail(out, "a superseded ADR needs a note naming what supersedes it, e.g. 'Superseded by ADR 0021.' — link forward rather than editing the history out of this one");
    if (std.mem.eql(u8, label, "Deprecated") and note.len == 0)
        return lib.fail(out, "a deprecated ADR needs a note saying what stopped being true");

    const raw = lib.fsRead(path) catch |err| return lib.failErr(out, err, "opening the ADR before a status change");
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
        return lib.fail(out, "the ADR has no '## Status' section; add one or edit it with update");
    lib.fsWriteIf(path, expected, updated.written()) catch |err| switch (err) {
        error.Mismatch => return lib.fail(out, "the ADR changed while setting its status; open it again and retry"),
        else => return lib.failErr(out, err, "setting the ADR status"),
    };

    // ADR and index are separate files, so this cannot be one atomic write. A
    // CAS miss leaves the ADR correct and names the line to reconcile.
    const indexed = setInventoryStatus(std.fs.path.basename(path), label) catch false;

    try records_grep.writeStatusReply(out, path, label, indexed, "the ADR's status changed, but its docs/adrs/README.md inventory line could not be updated (missing entry or markers, or a concurrent edit); set that line's status word by hand so the index does not disagree with the ADR", null);
}

/// Derived from `statuses`, so what `status` accepts and what `list` reads
/// back off a record cannot drift apart.
fn labelFor(wanted: []const u8) ?[]const u8 {
    return doc.labelFrom(wanted, &statuses);
}
