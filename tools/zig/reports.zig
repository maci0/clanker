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
//!           kinds: bug, investigation, missing-tool (a basic verb clanker
//!           lacks; the tool inserts `missing-clanker-tool-` into the slug
//!           itself so the record is findable by name), runbook
//!          "title":"...", "summary":"..."}
//!         {"action":"append", "path":"docs/reports/investigations/foo.md",
//!          "content":"\n## New evidence\n\n...\n"}
//!           a block headed by a section the record already carries *empty*
//!           fills that section rather than adding a second copy of its heading
//!         {"action":"update", "path":"docs/runbooks/foo.md",
//!          "old":"old text", "new":"new text", "all":false}
//!           all:true rewrites every copy instead of refusing a repeated match,
//!           which is what a `status` note (written into the TL;DR and the
//!           Status section alike) needs
//!         {"action":"status", "path":"docs/reports/bugs/foo.md",
//!          "status":"resolved", "note":"Fixed in <commit>."}
//!         {"action":"rename", "path":"docs/reports/bugs/foo.md", "slug":"2026-08-15-topic"}
//! Output: {"ok":true, ...}

const std = @import("std");
const lib = @import("lib.zig");
const doc = @import("doc_scaffold.zig");
const records_grep = @import("records_grep.zig");

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
    if (std.mem.eql(u8, action, "rename")) return rename(obj, out);
    return lib.fail(out, "action must be search, list, open, create, append, update, status, or rename");
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

    // grepAll parses each host response before issuing the next call: they
    // share the host arena. The parsed values are allocated in the guest and
    // remain valid through response formatting.
    const reports = if (want_reports)
        records_grep.grepAll(reports_dir, query) catch |err| switch (err) {
            error.NotFound => emptyMatches(),
            error.IoError => return lib.fail(out, "could not parse the reports search result"),
            else => return lib.failErr(out, err, "searching docs/reports"),
        }
    else
        emptyMatches();
    const runbooks = if (want_runbooks)
        records_grep.grepAll(runbooks_dir, query) catch |err| switch (err) {
            error.NotFound => emptyMatches(),
            error.IoError => return lib.fail(out, "could not parse the runbooks search result"),
            else => return lib.failErr(out, err, "searching docs/runbooks"),
        }
    else
        emptyMatches();

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
        return lib.fail(out, "create needs kind: bug, investigation, missing-tool, or runbook");
    const title = lib.str(obj, "title") catch
        return lib.fail(out, "create needs a non-empty title");
    const summary = lib.str(obj, "summary") catch
        return lib.fail(out, "create needs a non-empty TL;DR summary");
    const slug = lib.str(obj, "slug") catch
        return lib.fail(out, "create needs a filename stem in slug");
    if (title.len > 180) return lib.fail(out, "title is too long (maximum 180 bytes)");
    if (summary.len > 500) return lib.fail(out, "summary is too long (maximum 500 bytes)");
    // The scaffold's `# ` line and the inventory link are both `<label> —
    // <title>`, so a caller who wrote the label into the title got
    // `# Bug — Bug — ...` and an inventory line that was the only one in the
    // index carrying a label. Stripped here rather than trusted from the
    // caller, the same way `markMissingToolSlug` enforces the slug marker.
    const title_text = doc.stripLabelPrefix(kindLabel(kind), title);
    if (title_text.len == 0) return lib.fail(out, "create needs a title that says more than the record's kind");

    const target = targetFor(kind, slug) orelse
        return lib.fail(out, "kind must be bug, investigation, missing-tool, or runbook; report slugs start YYYY-MM-DD-, runbook slugs use lowercase letters, digits, and hyphens");

    // Two clocks decide one record: the store stamps UTC (`doc.isoDate`, and
    // `status` will stamp the same way) while the caller types the slug from
    // whatever its own shell said. Every report slug carries a date, so this is
    // the store with the exposure — the class recurred in four independent
    // sessions in one day, which is where "the caller should know better" stops
    // being a workable contract. Warn and create: backdating a record about an
    // older event is a real need, so a refusal would only be worked around.
    var date_buf: [16]u8 = undefined;
    const today = doc.isoDate(@trunc(lib.nowSeconds()), &date_buf);
    const date_warning: ?[]const u8 = if (doc.slugDateConflict(slug, today)) |dated|
        try doc.slugDateWarning(lib.alloc, dated, today)
    else
        null;
    var rendered: std.Io.Writer.Allocating = .init(lib.alloc);
    defer rendered.deinit();
    try renderScaffold(&rendered.writer, kind, title_text, summary);

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
    // A missing-tool record lives in the investigations store and inventory;
    // its own kind exists to enforce the filename marker and its scaffold.
    const inventory_kind = if (std.mem.eql(u8, kind, "missing-tool")) "investigation" else kind;
    const indexed = addToInventory(inventory_kind, target, title_text) catch false;
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
    if (date_warning) |warning| {
        try s.objectField("date_warning");
        try s.write(warning);
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
    // A block headed by a section the scaffold left empty fills that section
    // instead of landing at the end as a second copy of its heading. See
    // `doc.appendOrFill`: that duplication is why 33 records in this store
    // carry two `## Root cause` headings, one of them blank.
    const placement = try doc.appendOrFill(&updated.writer, text, content);
    lib.fsWriteIf(path, expected, updated.written()) catch |err| switch (err) {
        error.Mismatch => return lib.fail(out, "the record changed while appending; open it again and retry against the current text"),
        else => return lib.failErr(out, err, "appending to the report or runbook"),
    };
    return records_grep.appendResult(out, path, placement);
}

/// Replace one exact piece of a report or runbook. Requiring a unique old value
/// prevents an agent from changing the wrong repeated heading or status line.
///
/// `"all":true` opts out of that uniqueness check and rewrites every copy. It
/// exists because `status` writes its note into the TL;DR `Resolution` bullet
/// and the `## Status` section byte-identically, which made the sentence the
/// store had just written the one piece of a record `update` could not address
/// by its own words. Those two are one fact written twice, so an edit that
/// matches both is meant for both.
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
    const all = lib.optBool(obj, "all", false);
    const raw = lib.fsRead(path) catch |err| return lib.failErr(out, err, "opening the report or runbook before update");
    const text = try lib.alloc.dupe(u8, raw);
    const start = std.mem.find(u8, text, old) orelse
        return lib.fail(out, "old text was not found; open the current record and copy the exact text");
    if (!all and std.mem.findPos(u8, text, start + old.len, old) != null)
        return lib.fail(out, "old text appears more than once; include more surrounding text so the update is unambiguous, or ask for every copy with \"all\":true (`--replace-all` from the CLI), which is what editing a status note takes: that sentence is written into both the TL;DR bullet and the Status section");
    const expected = try lib.alloc.dupe(u8, try lib.hash(text));

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    const replaced = if (all)
        doc.spliceReplaceAll(&updated.writer, text, old, new) catch |err| switch (err) {
            error.NotFound => return lib.fail(out, "old text was not found; open the current record and copy the exact text"),
            else => |e| return e,
        }
    else blk: {
        try updated.writer.writeAll(text[0..start]);
        try updated.writer.writeAll(new);
        try updated.writer.writeAll(text[start + old.len ..]);
        break :blk 1;
    };
    lib.fsWriteIf(path, expected, updated.written()) catch |err| switch (err) {
        error.Mismatch => return lib.fail(out, "the record changed while updating; open it again and retry against the current text"),
        else => return lib.failErr(out, err, "updating the report or runbook"),
    };
    return records_grep.updateResult(out, path, replaced);
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

    // The third copy of the same fact. `create` writes a TL;DR `Resolution`
    // bullet, and leaving it at `Open.` on a resolved record is worse than
    // leaving the inventory stale: CLAUDE.md tells a reader to start at the
    // TL;DR. Not fatal — a record whose summary was reshaped by hand is still
    // worth a status change — so the reply reports it instead.
    var summarized: std.Io.Writer.Allocating = .init(lib.alloc);
    defer summarized.deinit();
    const tldr = try doc.replaceTldrField(&summarized.writer, updated.written(), "Resolution", line);
    var body = if (tldr) summarized.written() else updated.written();

    // An investigation's TL;DR carries a second state bullet. `Finding` starts
    // as the scaffold's `Investigating.` and later holds the actual finding,
    // so it is rewritten only while it is still that placeholder — overwriting
    // a real finding to record a status change would lose the answer the
    // record exists for.
    var found: std.Io.Writer.Allocating = .init(lib.alloc);
    defer found.deinit();
    if (doc.tldrField(body, "Finding")) |current| {
        if (std.mem.eql(u8, current, "Investigating.")) {
            if (try doc.replaceTldrField(&found.writer, body, "Finding", line)) body = found.written();
        }
    }

    lib.fsWriteIf(path, expected, body) catch |err| switch (err) {
        error.Mismatch => return lib.fail(out, "the record changed while setting its status; open it again and retry"),
        else => return lib.failErr(out, err, "setting the record status"),
    };

    // Record and index are separate files, so this is not one atomic write. A
    // CAS miss leaves the record correct and says which line to reconcile.
    const indexed = setInventoryStatus(kind, path[reports_dir.len + 1 ..], label) catch false;

    try records_grep.writeStatusReply(out, path, label, indexed, "the record's status changed, but its docs/reports/README.md inventory line could not be updated (missing entry or markers, or a concurrent edit); set that line's status by hand so the index does not disagree with the record", null);
}

/// Move a record to a new filename inside its own store. The store never
/// changes — the slug is a name, not a destination. The inventory link is
/// rewritten under compare-and-swap, and every other mention of the old
/// name that this tool can see (its two stores) is reported back so the
/// caller fixes references deliberately instead of discovering them broken.
/// A `missing-clanker-tool-` marker survives the rename: enforced here the
/// same way `create` enforces it, not trusted from the caller.
fn rename(obj: std.json.Value, out: *lib.Out) !void {
    const path = lib.str(obj, "path") catch
        return lib.fail(out, "rename needs the current path of a record");
    if (!isAllowedPath(path)) return lib.fail(out, "path must be a markdown file below docs/reports/ or docs/runbooks/");
    const slug_raw = lib.str(obj, "slug") catch
        return lib.fail(out, "rename needs the new filename stem in slug");
    const dir_end = std.mem.findScalarLast(u8, path, '/') orelse
        return lib.fail(out, "path has no directory");
    const dir = path[0..dir_end];
    const old_name = path[dir_end + 1 ..];
    const old_stem = old_name[0 .. old_name.len - ".md".len];
    const runbook = std.mem.startsWith(u8, path, runbooks_dir ++ "/");
    if (runbook) {
        if (!isSlug(slug_raw)) return lib.fail(out, "runbook slugs use lowercase letters, digits, and hyphens");
    } else if (!isDatedSlug(slug_raw))
        return lib.fail(out, "report slugs start YYYY-MM-DD-");
    const slug = if (!runbook and std.mem.find(u8, old_stem, doc.missing_tool_marker) != null)
        try doc.markMissingToolSlug(lib.alloc, slug_raw)
    else
        slug_raw;
    const new_path = try std.fmt.allocPrint(lib.alloc, "{s}/{s}.md", .{ dir, slug });
    if (std.mem.eql(u8, new_path, path)) return lib.fail(out, "the record already has that name");
    if (lib.fsRead(new_path)) |_| {
        return lib.fail(out, "a record already exists at the new name");
    } else |_| {}
    _ = lib.fsRead(path) catch |err| return lib.failErr(out, err, "opening the record before rename");
    lib.fsRename(path, new_path) catch |err| return lib.failErr(out, err, "renaming the record");

    // The inventory link is the second copy of the name; rewrite it under
    // CAS like every other index edit. The links are store-relative.
    const store_root = if (runbook) runbooks_dir else reports_dir;
    const old_link = path[store_root.len + 1 ..];
    const new_link = new_path[store_root.len + 1 ..];
    const index_path: []const u8 = if (runbook) runbooks_dir ++ "/README.md" else reports_dir ++ "/README.md";
    const indexed = renameInventoryLink(index_path, old_link, new_link) catch false;

    // Everything else that still says the old name, as far as this tool can
    // see: its grants cover only the two stores, so mentions elsewhere in
    // the tree have to be searched by the caller. A failed scan must not
    // read as "no references" — the reply says which it was.
    var refs: std.ArrayList([]const u8) = .empty;
    var refs_ok = true;
    // The shared walk, not a second copy: this store's own copy joined the
    // store root onto hits `ck_fs_grep` already reports repo-rooted, so every
    // path on this list read `docs/reports/docs/reports/…` and opened nothing.
    // Skipping each store's index by path also does what the old literal
    // `README.md` comparison only looked like it did.
    records_grep.collectRenameReferences(&refs, reports_dir, reports_dir ++ "/README.md", old_stem) catch {
        refs_ok = false;
    };
    records_grep.collectRenameReferences(&refs, runbooks_dir, runbooks_dir ++ "/README.md", old_stem) catch {
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
    try s.write(new_path);
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
    try s.write(if (refs_ok)
        "files inside docs/reports/ and docs/runbooks/ still naming the old record; mentions elsewhere in the tree are outside this tool's grants — search for the old name there too"
    else
        "the reference scan failed, so this list is incomplete — search both stores and the rest of the tree for the old name by hand");
    try s.endObject();
    lib.commit(out, &w);
}

/// Rewrite every inventory occurrence of `old_link` to `new_link` in one
/// compare-and-swap write. Returns false when the link is absent or the
/// index changed concurrently. The global replace cannot touch another
/// record's link: links are store-relative with one directory level and a
/// `.md` suffix, so no link is a substring of a different one.
fn renameInventoryLink(index_path: []const u8, old_link: []const u8, new_link: []const u8) !bool {
    const idx = try records_grep.readIndex(index_path);
    if (std.mem.find(u8, idx.text, old_link) == null) return false;
    const size = std.mem.replacementSize(u8, idx.text, old_link, new_link);
    const updated = try lib.alloc.alloc(u8, size);
    _ = std.mem.replace(u8, idx.text, old_link, new_link, updated);
    return records_grep.writeIndex(index_path, idx, updated);
}

/// The inventory kind a path belongs to, or null when the path is not a
/// status-carrying record.
fn reportKindOf(path: []const u8) ?[]const u8 {
    if (!isAllowedPath(path)) return null;
    if (std.mem.startsWith(u8, path, reports_dir ++ "/bugs/")) return "bug";
    if (std.mem.startsWith(u8, path, reports_dir ++ "/investigations/")) return "investigation";
    return null;
}

/// The lifecycle a bug report or investigation moves through, stated once:
/// `labelFor` renders from it and nothing else names these words.
const statuses = [_][]const u8{ "Open", "Investigating", "Resolved", "Reopened", "Closed" };

/// Derived from `statuses`, so the accepted vocabulary and its display
/// spelling cannot drift apart.
fn labelFor(wanted: []const u8) ?[]const u8 {
    return doc.labelFrom(wanted, &statuses);
}

fn setInventoryStatus(kind: []const u8, link: []const u8, label: []const u8) !bool {
    return records_grep.setIndexStatus(
        reports_dir ++ "/README.md",
        try std.fmt.allocPrint(lib.alloc, "<!-- inventory:{s}:start -->", .{kind}),
        try std.fmt.allocPrint(lib.alloc, "<!-- inventory:{s}:end -->", .{kind}),
        link,
        label,
    );
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
    if (std.mem.eql(u8, kind, "missing-tool")) {
        if (!isDatedSlug(slug)) return null;
        // The filename carries the `missing-clanker-tool-` marker whether or
        // not the caller wrote it: a record of absent tooling must be
        // findable by name, and that is enforced here, not trusted.
        const marked = doc.markMissingToolSlug(lib.alloc, slug) catch return null;
        return .{
            .path = std.fmt.allocPrint(lib.alloc, "{s}/investigations/{s}.md", .{ reports_dir, marked }) catch return null,
            .index_path = reports_dir ++ "/README.md",
            .index_link = std.fmt.allocPrint(lib.alloc, "investigations/{s}.md", .{marked}) catch return null,
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

/// The word the record's `# ` line and its inventory entry are prefixed with.
fn kindLabel(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "bug")) return "Bug";
    if (std.mem.eql(u8, kind, "investigation")) return "Investigation";
    if (std.mem.eql(u8, kind, "missing-tool")) return "Missing clanker tool";
    return "Runbook";
}

fn renderScaffold(w: *std.Io.Writer, kind: []const u8, title: []const u8, summary: []const u8) !void {
    const label = kindLabel(kind);
    try w.print("# {s} — {s}\n\n", .{ label, title });
    try w.writeAll("## TL;DR\n\n");
    if (std.mem.eql(u8, kind, "missing-tool")) {
        // Same `Finding`/`Resolution` bullets and `## Status` line as an
        // investigation, so the `status` action's lifecycle applies to this
        // record unchanged; the sections ask for what a missing-verb record
        // must pin down.
        try w.print("- **Missing tool:** {s}\n- **Finding:** Investigating.\n- **Resolution:** Pending.\n", .{summary});
        try w.writeAll("\n## Status\n\nInvestigating.\n\n## What is missing\n\n## Why it is basic\n\n## Ad-hoc fallback used\n\n## Proposed shape\n\n## References\n\n- Related record: none yet\n");
        return;
    }
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
    const idx = try records_grep.readIndex(target.index_path);
    const marker = try std.fmt.allocPrint(lib.alloc, "<!-- inventory:{s}:start -->", .{kind});
    const end_marker = try std.fmt.allocPrint(lib.alloc, "<!-- inventory:{s}:end -->", .{kind});
    const start = std.mem.find(u8, idx.text, marker) orelse return false;
    const content_start = start + marker.len;
    const rel_end = std.mem.find(u8, idx.text[content_start..], end_marker) orelse return false;
    const end = content_start + rel_end;
    const previous = std.mem.trim(u8, idx.text[content_start..end], " \t\r\n");
    const empty_marker = if (std.mem.eql(u8, kind, "runbook")) "No runbooks yet." else "No reports yet.";

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    try updated.writer.writeAll(idx.text[0..content_start]);
    try updated.writer.print("\n- [{s}]({s}) — {s}\n", .{ title, target.index_link, if (std.mem.eql(u8, kind, "investigation")) "Investigating" else if (std.mem.eql(u8, kind, "bug")) "Open" else "Current" });
    if (previous.len > 0 and !std.mem.startsWith(u8, previous, empty_marker)) {
        try updated.writer.writeByte('\n');
        try updated.writer.writeAll(previous);
        try updated.writer.writeByte('\n');
    }
    try updated.writer.writeAll(idx.text[end..]);
    return records_grep.writeIndex(target.index_path, idx, updated.written());
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

/// A dated slug is a `YYYY-MM-DD-` prefix with a name after it. The prefix is
/// read by `doc.slugDatePrefix`, the same parser `create` compares against the
/// stamped date, so what counts as dated cannot drift between the two.
fn isDatedSlug(slug: []const u8) bool {
    if (slug.len < 13) return false;
    if (doc.slugDatePrefix(slug) == null) return false;
    return isSlug(slug);
}

fn emptyMatches() std.json.Value {
    return .{ .array = std.json.Array.init(lib.alloc) };
}
