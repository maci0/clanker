//! rfc: open, maintain, and close out requests for comment under `docs/rfcs/`.
//!
//! An RFC is the step before a decision: the options, what each implies over
//! time, and a recommendation carrying a confidence score. The ADR that
//! follows records what was chosen; this record is why the alternatives lost.
//!
//! The tool deliberately does not research anything. It numbers the document,
//! renders the template, keeps the index true, and enforces the two things an
//! RFC is worthless without — a real option set and a bounded confidence — so
//! that the searching, the reading, and the judgement stay where they can
//! actually be done. When a research note exists, `create` links it and lifts
//! its option headings in as stubs marked unverified: a research note is one
//! agent's earlier reading, not a source, and its claims are re-checked here
//! before they become an RFC's.
//!
//! Input:  {"action":"list"}
//!         {"action":"checklist", "topic":"..."}
//!         {"action":"create", "title":"...", "overview":"...", "research":"docs/research/x.md"}
//!         {"action":"open",   "path":"docs/rfcs/0001-x.md"}
//!         {"action":"search", "query":"..."}
//!         {"action":"append", "path":"...", "content":"..."}
//!         {"action":"update", "path":"...", "old":"...", "new":"..."}
//!         {"action":"recommend", "path":"...", "recommendation":"...", "confidence":7,
//!          "rationale":"...", "reversibility":"...", "moves_confidence":"..."}
//!         {"action":"status", "path":"...", "status":"decided", "note":"See ADR 0014."}
//! Output: {"ok":true, ...}

const std = @import("std");
const lib = @import("lib.zig");
const doc = @import("doc_scaffold.zig");
const records_grep = @import("records_grep.zig");

/// `list` reads every RFC to report its real status rather than trusting the
/// index, and each read is bump-allocated out of the host arena for the whole
/// call. Two megabytes covers a few hundred RFCs; past that, `list` skips the
/// reads it cannot afford and says so.
pub const host_arena_cap = 2 * 1024 * 1024;

const dir = "docs/rfcs";
const adr_dir = "docs/adrs";
const research_dir = "docs/research";
const index_path = dir ++ "/README.md";
const template_path = dir ++ "/TEMPLATE.md";
const inventory_start = "<!-- inventory:rfc:start -->";
const inventory_end = "<!-- inventory:rfc:end -->";

/// The statuses an RFC carries, stated once: `labelFor` renders from this and
/// `list`/`open` read a Status line against it. All one word, but read through
/// `doc.statusFrom` all the same, because `statusWord` cuts at the first
/// separator and would read `**Decided.**` as `**Decided`.
const statuses = [_][]const u8{ "Draft", "Discussion", "Decided", "Deferred", "Withdrawn", "Superseded" };

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const obj = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    const action = lib.optStr(obj, "action") orelse "list";

    if (std.mem.eql(u8, action, "list")) return list(out);
    if (std.mem.eql(u8, action, "checklist")) return checklist(obj, out);
    if (std.mem.eql(u8, action, "create")) return create(obj, out);
    if (std.mem.eql(u8, action, "open")) return open(obj, out);
    if (std.mem.eql(u8, action, "search")) return search(obj, out);
    if (std.mem.eql(u8, action, "append")) return append(obj, out);
    if (std.mem.eql(u8, action, "update")) return update(obj, out);
    if (std.mem.eql(u8, action, "recommend")) return recommend(obj, out);
    if (std.mem.eql(u8, action, "status")) return status(obj, out);
    return lib.fail(out, "action must be list, checklist, create, open, search, append, update, recommend, or status");
}

// ---------------------------------------------------------------- checklist

const Item = struct { needs: []const u8, why: []const u8, ask: []const u8 };

/// What an RFC cannot be written without. `ask` is the question to put to the
/// operator (with `ask_user`) when the request does not already answer it —
/// inventing a scope is how an RFC ends up arguing about the wrong decision.
const requirements = [_]Item{
    .{
        .needs = "The decision, as a question",
        .why = "An RFC that opens with a preferred answer collects agreement, not comment",
        .ask = "What exactly has to be decided here — phrased as a question with more than one defensible answer?",
    },
    .{
        .needs = "Why now",
        .why = "Whether this is urgent decides how much evidence is worth gathering",
        .ask = "What is blocked, costing, or breaking until this is decided?",
    },
    .{
        .needs = "Constraints that disqualify an option",
        .why = "Without them every option looks acceptable and the comparison is decoration",
        .ask = "Which constraints must any acceptable answer satisfy (toolchain, dependencies, licence, sandbox, cost, who maintains it)?",
    },
    .{
        .needs = "The status quo",
        .why = "Doing nothing is always an option and is usually the one being compared against implicitly",
        .ask = "What happens today instead, and what does that cost?",
    },
    .{
        .needs = "Scope boundary",
        .why = "An unbounded RFC turns into a redesign and never gets decided",
        .ask = "What is explicitly out of scope for this decision?",
    },
    .{
        .needs = "Reversibility and horizon",
        .why = "A one-way door deserves more evidence than a choice that can be undone in an afternoon",
        .ask = "How hard would this be to undo in six months, and when does the decision stop being reversible?",
    },
    .{
        .needs = "Who decides, and by when",
        .why = "An RFC with no audience and no deadline stays a draft forever",
        .ask = "Who is being asked to comment, and when does this need to be settled?",
    },
};

fn checklist(obj: std.json.Value, out: *lib.Out) !void {
    const topic = lib.optStr(obj, "topic") orelse "";

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    if (topic.len > 0) {
        try s.objectField("topic");
        try s.write(topic);
    }
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
    try s.write("Answer each requirement from the request itself where you can; put the rest to the operator with ask_user rather than assuming.");
    try s.write("A technical choice needs evidence first: research sweep, then web_fetch on what looks promising. A direction question needs alternative perspectives and the strongest case against your own recommendation instead.");
    try s.write("Then {\"action\":\"create\"} with a title and an overview; pass research when a note exists.");
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

// ------------------------------------------------------------------- create

fn create(obj: std.json.Value, out: *lib.Out) !void {
    const title = lib.str(obj, "title") catch
        return lib.fail(out, "create needs a title naming the decision, e.g. 'HTTP client for the proxy'");
    if (title.len > 180) return lib.fail(out, "title is too long (maximum 180 bytes)");
    const overview = lib.str(obj, "overview") catch
        return lib.fail(out, "create needs an overview: what has to be decided and why now. Run {\"action\":\"checklist\"} if the request does not say");
    if (overview.len > 4000) return lib.fail(out, "overview is too long (maximum 4000 bytes); the detail belongs in the document body");

    const research_path = lib.optStr(obj, "research") orelse "";
    if (research_path.len > 0 and !doc.isPathIn(research_dir, research_path))
        return lib.fail(out, "research must be a markdown file directly below docs/research/");

    var slug_buf: [96]u8 = undefined;
    const slug = if (lib.optStr(obj, "slug")) |given| given else doc.slugify(title, &slug_buf, 60);
    if (!doc.isSlug(slug))
        return lib.fail(out, "slug must be lowercase letters, digits and hyphens (no leading or trailing hyphen)");

    // Read the research note first: every later host call reuses the same
    // arena, so its text has to be copied into guest memory before then.
    var research_title: []const u8 = "";
    var options: std.ArrayList([]const u8) = .empty;
    if (research_path.len > 0) {
        const raw = lib.fsRead(research_path) catch |err| switch (err) {
            error.NotFound => return lib.fail(out, "no research note at that path; run the research tool's list action to see what exists"),
            else => return lib.failErr(out, err, "reading the research note"),
        };
        const note = try lib.alloc.dupe(u8, raw);
        research_title = doc.documentTitle(note);
        var found = doc.subHeadings(note, "## Options found", "### ");
        while (found.next()) |heading| {
            if (options.items.len >= 12) break;
            try options.append(lib.alloc, heading);
        }
        var extra = doc.subHeadings(note, "## Out-of-the-box options", "### ");
        while (extra.next()) |heading| {
            if (options.items.len >= 16) break;
            try options.append(lib.alloc, heading);
        }
    }

    const next = try records_grep.nextRecord(out, dir, slug) orelse return;

    const raw_template = lib.fsRead(template_path) catch |err| switch (err) {
        error.NotFound => return lib.fail(out, "docs/rfcs/TEMPLATE.md is missing; restore it before creating an RFC"),
        else => return lib.failErr(out, err, "reading the RFC template"),
    };
    const template = try lib.alloc.dupe(u8, raw_template);

    var date_buf: [16]u8 = undefined;
    const date = try lib.alloc.dupe(u8, doc.isoDate(@trunc(lib.nowSeconds()), &date_buf));

    const references = if (research_path.len > 0)
        try std.fmt.allocPrint(
            lib.alloc,
            "- Research: [{s}](../research/{s}) — read {s}. Its claims are unverified here until each one is checked against its own source.\n",
            .{
                if (research_title.len > 0) research_title else research_path,
                research_path[research_dir.len + 1 ..],
                date,
            },
        )
    else
        "";

    var rendered: std.Io.Writer.Allocating = .init(lib.alloc);
    defer rendered.deinit();
    try doc.fillTemplate(&rendered.writer, template, &.{
        .{ .name = "number", .value = next.number_text },
        .{ .name = "title", .value = title },
        .{ .name = "date", .value = date },
        .{ .name = "status", .value = "Draft" },
        .{ .name = "overview", .value = overview },
        .{ .name = "confidence", .value = "?" },
        .{ .name = "references", .value = references },
    });

    // Seeding the option set from the note is the one place the two tools
    // touch, and it is deliberately one-way and optional: stubs, not content.
    const seeded = options.items.len > 0;
    const text = if (seeded) blk: {
        var body: std.Io.Writer.Allocating = .init(lib.alloc);
        defer body.deinit();
        try renderSeededOptions(&body.writer, options.items, research_path);
        var replaced: std.Io.Writer.Allocating = .init(lib.alloc);
        errdefer replaced.deinit();
        if (!try doc.replaceSection(&replaced.writer, rendered.written(), "## Options considered", body.written()))
            break :blk try lib.alloc.dupe(u8, rendered.written());
        break :blk try lib.alloc.dupe(u8, replaced.written());
    } else try lib.alloc.dupe(u8, rendered.written());

    lib.fsWriteIf(next.path, "", text) catch |err| switch (err) {
        error.Mismatch => return lib.fail(out, "an RFC already exists at that path; list first and open it instead"),
        else => return lib.failErr(out, err, "creating the RFC"),
    };

    const entry = try std.fmt.allocPrint(
        lib.alloc,
        "- [RFC {s} — {s}]({s}-{s}.md) — Draft",
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
    try s.objectField("options_seeded");
    try s.write(@as(u64, options.items.len));

    // An RFC created without `research` is the common way the link is lost:
    // the caller has to remember a note exists, and nothing here used to say
    // otherwise. Every RFC in this repository was written that way, so none of
    // them link a note. List what is there instead of failing — a decision may
    // legitimately have no research behind it, but it should not silently
    // ignore research that does exist.
    if (research_path.len == 0) {
        const unlinked = try researchNotes();
        if (unlinked.len > 0) {
            try s.objectField("research_available");
            try s.beginArray();
            for (unlinked) |n| try s.write(n);
            try s.endArray();
            try s.objectField("research_note");
            try s.write("this RFC links no research note, and docs/research/ has notes that may cover this decision; open the relevant one and, if it does, recreate the RFC with research set to its path (create links it and seeds its option headings as unverified stubs)");
        }
    }

    if (!indexed) {
        try s.objectField("note");
        try s.write("the RFC was created but the inventory changed concurrently or lacks its markers; add the link to docs/rfcs/README.md by hand");
    }
    try s.objectField("next");
    try s.beginArray();
    if (seeded) {
        try s.write("The seeded options are unverified stubs from the research note. Re-check each claim against its own source before writing it into the body, and delete the stubs that do not survive.");
    } else {
        try s.write("Fill the options: at least two real candidates, the status quo, and one out-of-the-box option (something already here, a primitive, or not doing it).");
    }
    try s.write("Write the short, medium, and long term implications per option; that section is usually where the decision actually turns.");
    try s.write("Close with {\"action\":\"recommend\"} — it records the confidence 0-10 and what would move it.");
    try s.write("When the decision is made, set {\"action\":\"status\",\"status\":\"decided\"} and write the ADR in docs/adrs/.");
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

fn renderSeededOptions(w: *std.Io.Writer, options: []const []const u8, research_path: []const u8) !void {
    try w.print(
        "\nSeeded from [{s}]({s}). Every line below is a claim carried over unverified:\ncheck it against its own source, then rewrite it in this RFC's terms or delete it.\n",
        .{ research_path, relativeToRfcs(research_path) },
    );
    for (options) |option| {
        try w.print(
            \\
            \\### {s}
            \\
            \\- **What it is:** _from the research note; verify._
            \\- **Maturity:** _unverified — check the repository, licence, and last release._
            \\- **How it would fit:** _not yet assessed against this decision's constraints._
            \\- **Pros:**
            \\- **Cons:**
            \\- **Cost to adopt:**
            \\- **Cost to leave:**
            \\- **Evidence:** _link the primary source, not the research note._
            \\
        , .{option});
    }
    try w.writeAll(
        \\
        \\### Status quo
        \\
        \\- **What it is:** keep doing what we do today.
        \\- **Pros:**
        \\- **Cons:**
        \\- **Cost to adopt:** zero now; state what it costs later.
        \\
        \\
    );
}

fn relativeToRfcs(path: []const u8) []const u8 {
    // docs/research/x.md → ../research/x.md, so the link works from docs/rfcs/.
    if (std.mem.startsWith(u8, path, "docs/")) return path["docs/".len..];
    return path;
}

// --------------------------------------------------------------- inventory

fn addToInventory(entry: []const u8) !bool {
    const idx = try records_grep.readIndex(index_path);

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    if (!try doc.insertInventory(&updated.writer, idx.text, inventory_start, inventory_end, entry)) return false;
    return records_grep.writeIndex(index_path, idx, updated.written());
}

/// The index carries its own copy of the status word. Only `create` used to
/// write it, so every RFC stayed `Draft` in the inventory however often its
/// own Status line moved; the status action carries the index with it.
fn setInventoryStatus(link: []const u8, label: []const u8) !bool {
    const idx = try records_grep.readIndex(index_path);

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    if (!try doc.setInventoryStatus(&updated.writer, idx.text, inventory_start, inventory_end, link, label)) return false;
    return records_grep.writeIndex(index_path, idx, updated.written());
}

/// Paths of every research note that exists, for a `create` that linked none.
/// An unreadable or absent directory is a normal state, not an error: the
/// answer is then simply "there are none".
fn researchNotes() ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    const raw = lib.fsList(research_dir) catch return paths.items;
    const listing = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{}) catch return paths.items;
    if (listing != .array) return paths.items;
    for (listing.array.items) |item| {
        if (item != .string) continue;
        if (!doc.isDocFile(item.string)) continue;
        try paths.append(lib.alloc, try std.fmt.allocPrint(lib.alloc, "{s}/{s}", .{ research_dir, item.string }));
    }
    return paths.items;
}

// -------------------------------------------------------------------- reads

fn list(out: *lib.Out) !void {
    return records_grep.listNumbered(out, dir, "rfcs", "RFCs", &statuses);
}

fn open(obj: std.json.Value, out: *lib.Out) !void {
    const path = lib.str(obj, "path") catch
        return lib.fail(out, "open needs the path of an RFC");
    if (!doc.isPathIn(dir, path)) return lib.fail(out, "path must be a markdown file directly below docs/rfcs/");
    const raw = lib.fsRead(path) catch |err| return lib.failErr(out, err, "opening the RFC");
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
    try s.write(doc.statusFrom(text, &statuses));
    try s.objectField("text");
    try s.write(text);
    try s.endObject();
    lib.commit(out, &w);
}

/// Searches the RFCs and the ADRs together. A decision that was already made
/// and recorded is the one thing that should stop an RFC from being written,
/// and it lives in the other directory.
fn search(obj: std.json.Value, out: *lib.Out) !void {
    const query = lib.str(obj, "query") catch
        return lib.fail(out, "search needs a non-empty query");
    if (query.len > 240) return lib.fail(out, "query is too long (maximum 240 bytes)");

    const rfcs = try records_grep.grepRecords(dir, query);
    const adrs = try records_grep.grepRecords(adr_dir, query);

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("query");
    try s.write(query);
    try s.objectField("rfcs");
    try s.write(rfcs);
    try s.objectField("adrs");
    try s.write(adrs);
    try s.objectField("note");
    try s.write("An ADR match means the decision may already be made; read it before opening an RFC that re-litigates it.");
    try s.endObject();
    lib.commit(out, &w);
}

// ---------------------------------------------------------------- mutations

fn append(obj: std.json.Value, out: *lib.Out) !void {
    const path = lib.str(obj, "path") catch
        return lib.fail(out, "append needs the path of an RFC");
    if (!doc.isPathIn(dir, path)) return lib.fail(out, "path must be a markdown file directly below docs/rfcs/");
    const content = lib.str(obj, "content") catch
        return lib.fail(out, "append needs non-empty markdown content");
    const raw = lib.fsRead(path) catch |err| return lib.failErr(out, err, "opening the RFC before append");
    const text = try lib.alloc.dupe(u8, raw);
    const expected = try lib.alloc.dupe(u8, try lib.hash(text));

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    try doc.appendBlock(&updated.writer, text, content);
    lib.fsWriteIf(path, expected, updated.written()) catch |err| switch (err) {
        error.Mismatch => return lib.fail(out, "the RFC changed while appending; open it again and retry against the current text"),
        else => return lib.failErr(out, err, "appending to the RFC"),
    };
    return mutationResult(out, "append", path);
}

fn update(obj: std.json.Value, out: *lib.Out) !void {
    const path = lib.str(obj, "path") catch
        return lib.fail(out, "update needs the path of an RFC");
    if (!doc.isPathIn(dir, path)) return lib.fail(out, "path must be a markdown file directly below docs/rfcs/");
    const old = lib.str(obj, "old") catch
        return lib.fail(out, "update needs the exact non-empty old text from an open result");
    const new = lib.optStr(obj, "new") orelse
        return lib.fail(out, "update needs replacement text in new (it may be empty to remove old)");
    const raw = lib.fsRead(path) catch |err| return lib.failErr(out, err, "opening the RFC before update");
    const text = try lib.alloc.dupe(u8, raw);
    const expected = try lib.alloc.dupe(u8, try lib.hash(text));

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    doc.spliceReplace(&updated.writer, text, old, new) catch |err| switch (err) {
        doc.SpliceError.NotFound => return lib.fail(out, "old text was not found; open the current RFC and copy the exact text"),
        doc.SpliceError.Ambiguous => return lib.fail(out, "old text appears more than once; include more surrounding text so the update is unambiguous"),
        else => return err,
    };
    lib.fsWriteIf(path, expected, updated.written()) catch |err| switch (err) {
        error.Mismatch => return lib.fail(out, "the RFC changed while updating; open it again and retry against the current text"),
        else => return lib.failErr(out, err, "updating the RFC"),
    };
    return mutationResult(out, "update", path);
}

/// Writes the Recommendation section as a whole. The confidence is a required,
/// bounded number rather than prose because "we should probably use X" is what
/// this section exists to stop: a reader has to be able to tell a considered
/// call from a guess without reading the whole document.
fn recommend(obj: std.json.Value, out: *lib.Out) !void {
    const path = lib.str(obj, "path") catch
        return lib.fail(out, "recommend needs the path of an RFC");
    if (!doc.isPathIn(dir, path)) return lib.fail(out, "path must be a markdown file directly below docs/rfcs/");
    const choice = lib.str(obj, "recommendation") catch
        return lib.fail(out, "recommend needs a recommendation naming the option (a phased path is fine: 'A now, revisit if X')");
    const confidence_raw = lib.optNum(obj, "confidence") orelse
        return lib.fail(out, "recommend needs a confidence from 0 to 10");
    if (confidence_raw < 0 or confidence_raw > 10)
        return lib.fail(out, "confidence must be between 0 and 10");
    const confidence: u8 = @round(confidence_raw);
    const rationale = lib.str(obj, "rationale") catch
        return lib.fail(out, "recommend needs a rationale: why this beats the runner-up against the stated constraints");
    const moves = lib.optStr(obj, "moves_confidence") orelse "";
    const reversibility = lib.optStr(obj, "reversibility") orelse "";

    const raw = lib.fsRead(path) catch |err| return lib.failErr(out, err, "opening the RFC before writing its recommendation");
    const text = try lib.alloc.dupe(u8, raw);
    const expected = try lib.alloc.dupe(u8, try lib.hash(text));

    var body: std.Io.Writer.Allocating = .init(lib.alloc);
    defer body.deinit();
    try body.writer.print("\n**Recommended option:** {s}\n\n**Confidence:** {d}/10\n\n", .{ choice, confidence });
    if (moves.len > 0) {
        try body.writer.print("**Why this confidence.** {s}\n\n", .{moves});
    } else {
        try body.writer.writeAll("**Why this confidence.** _State what evidence would raise it, and what finding would sink this recommendation._\n\n");
    }
    try body.writer.print("**Rationale.** {s}\n\n", .{rationale});
    if (reversibility.len > 0) {
        try body.writer.print("**Reversibility.** {s}\n\n", .{reversibility});
    } else {
        try body.writer.writeAll("**Reversibility.** _How hard is this to undo, and where is the point of no return?_\n\n");
    }

    var updated: std.Io.Writer.Allocating = .init(lib.alloc);
    defer updated.deinit();
    if (!try doc.replaceSection(&updated.writer, text, "## Recommendation", body.written()))
        return lib.fail(out, "the RFC has no '## Recommendation' section; add one or write it with append");
    lib.fsWriteIf(path, expected, updated.written()) catch |err| switch (err) {
        error.Mismatch => return lib.fail(out, "the RFC changed while writing its recommendation; open it again and retry"),
        else => return lib.failErr(out, err, "writing the RFC recommendation"),
    };

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("action");
    try s.write("recommend");
    try s.objectField("path");
    try s.write(path);
    try s.objectField("confidence");
    try s.write(@as(u64, confidence));
    if (confidence <= 4) {
        try s.objectField("note");
        try s.write("A confidence of 4 or below says the evidence is not there yet: name the search, spike, or benchmark that would raise it in Open questions, or set the status to deferred instead of asking for a decision.");
    }
    try s.endObject();
    lib.commit(out, &w);
}

fn status(obj: std.json.Value, out: *lib.Out) !void {
    const path = lib.str(obj, "path") catch
        return lib.fail(out, "status needs the path of an RFC");
    if (!doc.isPathIn(dir, path)) return lib.fail(out, "path must be a markdown file directly below docs/rfcs/");
    const wanted = lib.str(obj, "status") catch
        return lib.fail(out, "status needs one of draft, discussion, decided, deferred, withdrawn, superseded");
    const label = labelFor(wanted) orelse
        return lib.fail(out, "status must be draft, discussion, decided, deferred, withdrawn, or superseded");
    const note = lib.optStr(obj, "note") orelse "";
    if (std.mem.eql(u8, label, "Superseded") and note.len == 0)
        return lib.fail(out, "a superseded RFC needs a note naming what supersedes it");
    if (std.mem.eql(u8, label, "Decided") and note.len == 0)
        return lib.fail(out, "a decided RFC needs a note naming the decision and its ADR (write the ADR in docs/adrs/ if it does not exist yet)");

    const raw = lib.fsRead(path) catch |err| return lib.failErr(out, err, "opening the RFC before a status change");
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
        return lib.fail(out, "the RFC has no '## Status' section; add one or edit it with update");
    lib.fsWriteIf(path, expected, updated.written()) catch |err| switch (err) {
        error.Mismatch => return lib.fail(out, "the RFC changed while setting its status; open it again and retry"),
        else => return lib.failErr(out, err, "setting the RFC status"),
    };

    // RFC and index are separate files, so this cannot be one atomic write. A
    // CAS miss leaves the RFC correct and names the line to reconcile.
    const indexed = setInventoryStatus(std.fs.path.basename(path), label) catch false;

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
        try s.write("the RFC's status changed, but its docs/rfcs/README.md inventory line could not be updated (missing entry or markers, or a concurrent edit); set that line's status word by hand so the index does not disagree with the RFC");
    }
    try s.endObject();
    lib.commit(out, &w);
}

/// Derived from `statuses`, so what `status` accepts and what `list` reads
/// back off an RFC cannot drift apart.
fn labelFor(wanted: []const u8) ?[]const u8 {
    return doc.labelFrom(wanted, &statuses);
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
