//! reports: search, open, and maintain the project's operational reports and runbooks.
//!
//! Reports preserve evidence and the history of a diagnosis; runbooks preserve
//! the current recovery procedure. Every mutation uses a compare-and-swap
//! write, so a concurrent documentation edit is never overwritten.
//!
//! Input:  {"action":"search", "query":"file_hash", "kind":"all"}
//!         {"action":"list"}
//!         {"action":"open", "path":"docs/reports/investigations/foo.md"}
//!         {"action":"create", "kind":"investigation", "slug":"2026-08-14-topic",
//!          "title":"...", "summary":"..."}
//!         {"action":"append", "path":"docs/reports/investigations/foo.md",
//!          "content":"\n## New evidence\n\n...\n"}
//!         {"action":"update", "path":"docs/runbooks/foo.md",
//!          "old":"old text", "new":"new text"}
//!         {"action":"status", "path":"docs/reports/bugs/foo.md",
//!          "status":"resolved", "note":"Fixed in <commit>."}
//! Output: {"ok":true, ...}

const std = @import("std");
const lib = @import("lib.zig");
const doc = @import("doc_scaffold.zig");

const reports_dir = "docs/reports";
const runbooks_dir = "docs/runbooks";

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const obj = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    const action = lib.optStr(obj, "action") orelse "search";

    if (std.mem.eql(u8, action, "list")) return list(out);
    if (std.mem.eql(u8, action, "search")) return search(obj, out);
    if (std.mem.eql(u8, action, "open")) return open(obj, out);
    if (std.mem.eql(u8, action, "create")) return create(obj, out);
    if (std.mem.eql(u8, action, "append")) return append(obj, out);
    if (std.mem.eql(u8, action, "update")) return update(obj, out);
    if (std.mem.eql(u8, action, "status")) return status(obj, out);
    return lib.fail(out, "action must be search, list, open, create, append, update, or status");
}

/// Return both indexes so the caller learns the available report/runbook kinds
/// before searching. An absent directory is a normal fresh-checkout state.
fn list(out: *lib.Out) !void {
    const reports = lib.fsRead(reports_dir ++ "/README.md") catch "";
    const runbooks = lib.fsRead(runbooks_dir ++ "/README.md") catch "";

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("reports_index");
    try s.write(reports);
    try s.objectField("runbooks_index");
    try s.write(runbooks);
    try s.endObject();
    lib.commit(out, &w);
}

fn search(obj: std.json.Value, out: *lib.Out) !void {
    const query = lib.str(obj, "query") catch
        return lib.fail(out, "search needs a non-empty query: use the error text, command, subsystem, or symptom");
    if (query.len > 240) return lib.fail(out, "query is too long (maximum 240 bytes)");
    const kind = lib.optStr(obj, "kind") orelse "all";
    const want_reports = std.mem.eql(u8, kind, "all") or std.mem.eql(u8, kind, "report");
    const want_runbooks = std.mem.eql(u8, kind, "all") or std.mem.eql(u8, kind, "runbook");
    if (!want_reports and !want_runbooks) return lib.fail(out, "kind must be all, report, or runbook");

    // Each host response uses the shared host arena, so parse it before making
    // the next call. The parsed values are allocated in the guest and remain
    // valid through response formatting.
    const reports = if (want_reports) blk: {
        const raw = lib.fsGrep(reports_dir, query) catch |err| switch (err) {
            error.NotFound => break :blk emptyMatches(),
            else => return lib.failErr(out, err, "searching docs/reports"),
        };
        break :blk std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{}) catch
            return lib.fail(out, "could not parse the reports search result");
    } else emptyMatches();
    const runbooks = if (want_runbooks) blk: {
        const raw = lib.fsGrep(runbooks_dir, query) catch |err| switch (err) {
            error.NotFound => break :blk emptyMatches(),
            else => return lib.failErr(out, err, "searching docs/runbooks"),
        };
        break :blk std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{}) catch
            return lib.fail(out, "could not parse the runbooks search result");
    } else emptyMatches();

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("query");
    try s.write(query);
    try s.objectField("reports");
    try s.write(reports);
    try s.objectField("runbooks");
    try s.write(runbooks);
    try s.endObject();
    lib.commit(out, &w);
}

fn open(obj: std.json.Value, out: *lib.Out) !void {
    const path = lib.str(obj, "path") catch
        return lib.fail(out, "open needs a report or runbook path");
    if (!isAllowedPath(path)) return lib.fail(out, "path must be a markdown file below docs/reports/ or docs/runbooks/");
    const text = lib.fsRead(path) catch |err| return lib.failErr(out, err, "opening the report or runbook");

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("path");
    try s.write(path);
    try s.objectField("text");
    try s.write(text);
    try s.endObject();
    lib.commit(out, &w);
}

fn create(obj: std.json.Value, out: *lib.Out) !void {
    const kind = lib.str(obj, "kind") catch
        return lib.fail(out, "create needs kind: bug, investigation, or runbook");
    const title = lib.str(obj, "title") catch
        return lib.fail(out, "create needs a non-empty title");
    const summary = lib.str(obj, "summary") catch
        return lib.fail(out, "create needs a non-empty TL;DR summary");
    const slug = lib.str(obj, "slug") catch
        return lib.fail(out, "create needs a filename stem in slug");
    if (title.len > 180) return lib.fail(out, "title is too long (maximum 180 bytes)");
    if (summary.len > 500) return lib.fail(out, "summary is too long (maximum 500 bytes)");

    const target = targetFor(kind, slug) orelse
        return lib.fail(out, "kind must be bug, investigation, or runbook; report slugs start YYYY-MM-DD-, runbook slugs use lowercase letters, digits, and hyphens");
    var rendered: std.Io.Writer.Allocating = .init(lib.alloc);
    defer rendered.deinit();
    try renderScaffold(&rendered.writer, kind, title, summary);

    // Empty expected hash means "file must not exist"; this prevents a second
    // run from replacing an authored report with another generated scaffold.
    lib.fsWriteIf(target.path, "", rendered.written()) catch |err| switch (err) {
        error.Mismatch => return lib.fail(out, "a report or runbook already exists at that path"),
        else => return lib.failErr(out, err, "creating the report or runbook"),
    };

    // File creation and index insertion are separate files, so they cannot be
    // one atomic operation. A CAS miss leaves the new record intact and tells
    // the caller exactly what to reconcile instead of overwriting a concurrent
    // documentation edit.
    const indexed = addToInventory(kind, target, title) catch false;
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("created");
    try s.write(true);
    try s.objectField("path");
    try s.write(target.path);
    try s.objectField("indexed");
    try s.write(indexed);
    if (!indexed) {
        try s.objectField("note");
        try s.write("the record was created, but the inventory changed concurrently or could not be updated; read the index and add the link without replacing another edit");
    }
    try s.endObject();
    lib.commit(out, &w);
}

/// Append evidence or a newly verified procedure without replacing the record.
/// A concurrent change refuses the write; the caller must re-open and decide
/// where its new material belongs in the changed document.
fn append(obj: std.json.Value, out: *lib.Out) !void {
    const path = lib.str(obj, "path") catch
        return lib.fail(out, "append needs a report or runbook path");
    if (!isAllowedPath(path)) return lib.fail(out, "path must be a markdown file below docs/reports/ or docs/runbooks/");
    const content = lib.str(obj, "content") catch
        return lib.fail(out, "append needs non-empty content");
    // The next host call (`hash`) reuses the shared response arena, so keep
    // the text in guest memory before asking the host for its CAS hash.
    const raw = lib.fsRead(path) catch |err| return lib.failErr(out, err, "opening the report or runbook before append");
    const text = try lib.alloc.dupe(u8, raw);
    const expected = try lib.alloc.dupe(u8, try lib.hash(text));

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    try updated.writer.writeAll(text);
    if (text.len > 0 and text[text.len - 1] != '\n') try updated.writer.writeByte('\n');
    try updated.writer.writeAll(content);
    lib.fsWriteIf(path, expected, updated.written()) catch |err| switch (err) {
        error.Mismatch => return lib.fail(out, "the record changed while appending; open it again and retry against the current text"),
        else => return lib.failErr(out, err, "appending to the report or runbook"),
    };
    return mutationResult(out, "append", path);
}

/// Replace one exact piece of a report or runbook. Requiring a unique old value
/// prevents an agent from changing the wrong repeated heading or status line.
fn update(obj: std.json.Value, out: *lib.Out) !void {
    const path = lib.str(obj, "path") catch
        return lib.fail(out, "update needs a report or runbook path");
    if (!isAllowedPath(path)) return lib.fail(out, "path must be a markdown file below docs/reports/ or docs/runbooks/");
    const old = lib.str(obj, "old") catch
        return lib.fail(out, "update needs the exact non-empty old text from an open result");
    const new = lib.optStr(obj, "new") orelse
        return lib.fail(out, "update needs replacement text in new (it may be empty to remove old)");
    // `hash` overwrites the shared host response arena; all later slicing has
    // to use this guest-owned copy rather than the fsRead response.
    const raw = lib.fsRead(path) catch |err| return lib.failErr(out, err, "opening the report or runbook before update");
    const text = try lib.alloc.dupe(u8, raw);
    const start = std.mem.find(u8, text, old) orelse
        return lib.fail(out, "old text was not found; open the current record and copy the exact text");
    if (std.mem.findPos(u8, text, start + old.len, old) != null)
        return lib.fail(out, "old text appears more than once; include more surrounding text so the update is unambiguous");
    const expected = try lib.alloc.dupe(u8, try lib.hash(text));

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    try updated.writer.writeAll(text[0..start]);
    try updated.writer.writeAll(new);
    try updated.writer.writeAll(text[start + old.len ..]);
    lib.fsWriteIf(path, expected, updated.written()) catch |err| switch (err) {
        error.Mismatch => return lib.fail(out, "the record changed while updating; open it again and retry against the current text"),
        else => return lib.failErr(out, err, "updating the report or runbook"),
    };
    return mutationResult(out, "update", path);
}

/// Moves a record through its lifecycle: the `## Status` line and the index
/// entry, in one call.
///
/// Those are two copies of one fact, and before this action only `create` ever
/// wrote the index one. Every record therefore stayed `Open`/`Investigating`
/// in the inventory no matter what its own body said, and the inventory is
/// what a reader skims first — a resolved bug still listed as open is a
/// standing invitation to re-diagnose finished work.
fn status(obj: std.json.Value, out: *lib.Out) !void {
    const path = lib.str(obj, "path") catch
        return lib.fail(out, "status needs the path of a bug report or investigation");
    const kind = reportKindOf(path) orelse
        return lib.fail(out, "status applies to docs/reports/bugs/ and docs/reports/investigations/ records; a runbook is current or superseded by its own text, and its inventory line carries a summary rather than a status");
    const wanted = lib.str(obj, "status") catch
        return lib.fail(out, "status needs one of open, investigating, resolved, reopened, or closed");
    const label = labelFor(wanted) orelse
        return lib.fail(out, "status must be open, investigating, resolved, reopened, or closed");
    const note = lib.optStr(obj, "note") orelse "";
    if (note.len > 500) return lib.fail(out, "note is too long (maximum 500 bytes)");
    if (std.mem.eql(u8, label, "Resolved") and note.len == 0)
        return lib.fail(out, "a resolved record needs a note naming the fix and what verified it; put the evidence in the Resolution and Verification sections with append or update first");

    // `hash` reuses the shared host response arena, so keep a guest-owned copy
    // of the text before asking for its CAS hash.
    const raw = lib.fsRead(path) catch |err| return lib.failErr(out, err, "opening the record before a status change");
    const text = try lib.alloc.dupe(u8, raw);
    const expected = try lib.alloc.dupe(u8, try lib.hash(text));

    var date_buf: [16]u8 = undefined;
    const date = doc.isoDate(@trunc(lib.nowSeconds()), &date_buf);
    const line = if (note.len > 0)
        try std.fmt.allocPrint(lib.alloc, "{s} on {s}. {s}", .{ label, date, note })
    else
        try std.fmt.allocPrint(lib.alloc, "{s} on {s}.", .{ label, date });

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    if (!try doc.replaceFirstLine(&updated.writer, text, "## Status", line))
        return lib.fail(out, "the record has no '## Status' section; add one or edit it with update");
    lib.fsWriteIf(path, expected, updated.written()) catch |err| switch (err) {
        error.Mismatch => return lib.fail(out, "the record changed while setting its status; open it again and retry"),
        else => return lib.failErr(out, err, "setting the record status"),
    };

    // Record and index are separate files, so this is not one atomic write. A
    // CAS miss leaves the record correct and says which line to reconcile.
    const indexed = setInventoryStatus(kind, path[reports_dir.len + 1 ..], label) catch false;

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
        try s.write("the record's status changed, but its docs/reports/README.md inventory line could not be updated (missing entry or markers, or a concurrent edit); set that line's status by hand so the index does not disagree with the record");
    }
    try s.endObject();
    lib.commit(out, &w);
}

/// The inventory kind a path belongs to, or null when the path is not a
/// status-carrying record.
fn reportKindOf(path: []const u8) ?[]const u8 {
    if (!isAllowedPath(path)) return null;
    if (std.mem.startsWith(u8, path, reports_dir ++ "/bugs/")) return "bug";
    if (std.mem.startsWith(u8, path, reports_dir ++ "/investigations/")) return "investigation";
    return null;
}

/// Written out rather than derived, so adding a status has to touch both the
/// accepted vocabulary and its display spelling, which is what keeps the two
/// in step.
fn labelFor(wanted: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(wanted, "open")) return "Open";
    if (std.ascii.eqlIgnoreCase(wanted, "investigating")) return "Investigating";
    if (std.ascii.eqlIgnoreCase(wanted, "resolved")) return "Resolved";
    if (std.ascii.eqlIgnoreCase(wanted, "reopened")) return "Reopened";
    if (std.ascii.eqlIgnoreCase(wanted, "closed")) return "Closed";
    return null;
}

fn setInventoryStatus(kind: []const u8, link: []const u8, label: []const u8) !bool {
    const raw = try lib.fsRead(reports_dir ++ "/README.md");
    const index = try lib.alloc.dupe(u8, raw);
    const expected = try lib.alloc.dupe(u8, try lib.hash(index));
    const start_marker = try std.fmt.allocPrint(lib.alloc, "<!-- inventory:{s}:start -->", .{kind});
    const end_marker = try std.fmt.allocPrint(lib.alloc, "<!-- inventory:{s}:end -->", .{kind});

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    if (!try doc.setInventoryStatus(&updated.writer, index, start_marker, end_marker, link, label)) return false;
    lib.fsWriteIf(reports_dir ++ "/README.md", expected, updated.written()) catch |err| switch (err) {
        error.Mismatch => return false,
        else => return err,
    };
    return true;
}

fn mutationResult(out: *lib.Out, action: []const u8, path: []const u8) !void {
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

const Target = struct {
    path: []const u8,
    index_path: []const u8,
    index_link: []const u8,
};

fn targetFor(kind: []const u8, slug: []const u8) ?Target {
    if (std.mem.eql(u8, kind, "bug")) {
        if (!isDatedSlug(slug)) return null;
        return .{
            .path = std.fmt.allocPrint(lib.alloc, "{s}/bugs/{s}.md", .{ reports_dir, slug }) catch return null,
            .index_path = reports_dir ++ "/README.md",
            .index_link = std.fmt.allocPrint(lib.alloc, "bugs/{s}.md", .{slug}) catch return null,
        };
    }
    if (std.mem.eql(u8, kind, "investigation")) {
        if (!isDatedSlug(slug)) return null;
        return .{
            .path = std.fmt.allocPrint(lib.alloc, "{s}/investigations/{s}.md", .{ reports_dir, slug }) catch return null,
            .index_path = reports_dir ++ "/README.md",
            .index_link = std.fmt.allocPrint(lib.alloc, "investigations/{s}.md", .{slug}) catch return null,
        };
    }
    if (std.mem.eql(u8, kind, "runbook")) {
        if (!isSlug(slug)) return null;
        return .{
            .path = std.fmt.allocPrint(lib.alloc, "{s}/{s}.md", .{ runbooks_dir, slug }) catch return null,
            .index_path = runbooks_dir ++ "/README.md",
            .index_link = std.fmt.allocPrint(lib.alloc, "{s}.md", .{slug}) catch return null,
        };
    }
    return null;
}

fn renderScaffold(w: *std.Io.Writer, kind: []const u8, title: []const u8, summary: []const u8) !void {
    const label = if (std.mem.eql(u8, kind, "bug")) "Bug" else if (std.mem.eql(u8, kind, "investigation")) "Investigation" else "Runbook";
    try w.print("# {s} — {s}\n\n", .{ label, title });
    try w.writeAll("## TL;DR\n\n");
    if (std.mem.eql(u8, kind, "bug")) {
        try w.print("- **What failed:** {s}\n- **Impact:** To be confirmed.\n- **Resolution:** Open.\n", .{summary});
        try w.writeAll("\n## Status\n\nOpen.\n\n## Symptom and impact\n\n## Reproduction\n\n## Root cause\n\n## Resolution\n\n## Verification\n\n## Follow-up\n\n## References\n\n- Investigation: none yet\n");
    } else if (std.mem.eql(u8, kind, "investigation")) {
        try w.print("- **Question:** {s}\n- **Finding:** Investigating.\n- **Resolution:** Pending.\n", .{summary});
        try w.writeAll("\n## Status\n\nInvestigating.\n\n## Trigger and scope\n\n## Evidence\n\n## Hypotheses and tests\n\n## Finding\n\n## Resolution or handoff\n\n## References\n\n- Related bug: none yet\n");
    } else {
        try w.print("- **Use when:** {s}\n- **Recover by:** Determine the current verified procedure.\n- **Verify with:** The linked report's verification steps.\n", .{summary});
        try w.writeAll("\n## Scope and preconditions\n\n## Diagnose\n\n## Recover\n\n## Verify\n\n## Escalate or follow up\n\n## References\n\n- Report: none yet\n");
    }
}

fn addToInventory(kind: []const u8, target: Target, title: []const u8) !bool {
    const raw = try lib.fsRead(target.index_path);
    const index = try lib.alloc.dupe(u8, raw);
    const expected = try lib.alloc.dupe(u8, try lib.hash(index));
    const marker = try std.fmt.allocPrint(lib.alloc, "<!-- inventory:{s}:start -->", .{kind});
    const end_marker = try std.fmt.allocPrint(lib.alloc, "<!-- inventory:{s}:end -->", .{kind});
    const start = std.mem.find(u8, index, marker) orelse return false;
    const content_start = start + marker.len;
    const rel_end = std.mem.find(u8, index[content_start..], end_marker) orelse return false;
    const end = content_start + rel_end;
    const previous = std.mem.trim(u8, index[content_start..end], " \t\r\n");
    const empty_marker = if (std.mem.eql(u8, kind, "runbook")) "No runbooks yet." else "No reports yet.";

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    try updated.writer.writeAll(index[0..content_start]);
    try updated.writer.print("\n- [{s}]({s}) — {s}\n", .{ title, target.index_link, if (std.mem.eql(u8, kind, "investigation")) "Investigating" else if (std.mem.eql(u8, kind, "bug")) "Open" else "Current" });
    if (previous.len > 0 and !std.mem.startsWith(u8, previous, empty_marker)) {
        try updated.writer.writeByte('\n');
        try updated.writer.writeAll(previous);
        try updated.writer.writeByte('\n');
    }
    try updated.writer.writeAll(index[end..]);
    lib.fsWriteIf(target.index_path, expected, updated.written()) catch |err| switch (err) {
        error.Mismatch => return false,
        else => return err,
    };
    return true;
}

fn isAllowedPath(path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".md")) return false;
    if (!std.mem.startsWith(u8, path, reports_dir ++ "/") and !std.mem.startsWith(u8, path, runbooks_dir ++ "/")) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn isSlug(slug: []const u8) bool {
    if (slug.len == 0 or slug.len > 96) return false;
    for (slug) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    }
    return slug[0] != '-' and slug[slug.len - 1] != '-';
}

fn isDatedSlug(slug: []const u8) bool {
    if (slug.len < 13 or slug[4] != '-' or slug[7] != '-' or slug[10] != '-') return false;
    for (slug[0..10], 0..) |c, i| {
        if (i == 4 or i == 7) continue;
        if (!std.ascii.isDigit(c)) return false;
    }
    return isSlug(slug);
}

fn emptyMatches() std.json.Value {
    return .{ .array = std.json.Array.init(lib.alloc) };
}
