//! workflows: list and inspect reusable prompt templates stored as markdown files.
//!
//! Input:  {}                          → list every workflow (name, arg_hint, description, rel_path)
//!         {"name":"plan"}             → show that workflow's full body + metadata
//!         {"name":"plan","args":"..."} → expand it with args substituted, returning the prompt
//! Output: {"ok":true,"workflows":[...]} | {"ok":true,"workflow":{...}} | {"ok":true,"prompt":"..."} | {"ok":false,...}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{ .ignore_unknown_fields = true }) catch
        return lib.fail(out, "expected a JSON object");

    if (parsed != .object) return lib.fail(out, "expected a JSON object");
    const name = lib.optStr(parsed, "name");
    const args = lib.optStr(parsed, "args") orelse lib.optStr(parsed, "arguments") orelse "";
    const wants_chain = lib.optStr(parsed, "chain") != null;

    // Read workflows_dir from harness config so the tool tracks config.toml, not a stale descriptor value.
    // This mirrors how config_view resolves paths — from the loaded config.
    var workflows_dir: []const u8 = "workflows";
    {
        const cfg_raw = lib.harnessConfig();
        if (cfg_raw.len > 4) {
            const cfg = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, cfg_raw, .{ .ignore_unknown_fields = true }) catch null;
            if (cfg) |c| {
                if (c == .object) {
                    if (c.object.get("agent")) |ag| if (ag == .object) {
                        if (ag.object.get("workflows_dir")) |wd| if (wd == .string) {
                            workflows_dir = wd.string;
                        };
                    };
                }
            }
        }
    }
    if (workflows_dir.len == 0) return lib.fail(out, "workflows are disabled (agent.workflows_dir is empty)");

    var catalog: std.ArrayList(FileWorkflow) = .empty;
    const fallback_dir = ".cursor/workflows";
    const dirs: [2][]const u8 = .{ workflows_dir, fallback_dir };
    for (dirs, 0..) |dir, idx| {
        if (dir.len == 0) continue;
        if (idx == 1 and std.mem.eql(u8, dir, workflows_dir)) continue;
        const names_json = listMarkdownFiles(dir) catch continue;
        const names_val = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, names_json, .{}) catch continue;
        if (names_val != .array) continue;
        for (names_val.array.items) |item| {
            if (item != .string) continue;
            const fname = item.string;
            const fpath = std.fmt.allocPrint(lib.alloc, "{s}/{s}", .{ dir, fname }) catch continue;
            const raw = lib.fsRead(fpath) catch continue;
            const stem = if (fname.len > 3) fname[0 .. fname.len - 3] else continue;
            const wf = parseWorkflow(lib.alloc, stem, fname, raw) catch continue;
            if (std.mem.trim(u8, wf.body, " \t\r\n").len == 0) continue;
            var is_dup = false;
            for (catalog.items) |existing| if (std.mem.eql(u8, existing.name, wf.name)) {
                is_dup = true;
                break;
            };
            if (is_dup) continue;
            catalog.append(lib.alloc, wf) catch continue;
        }
    }
    std.mem.sort(FileWorkflow, catalog.items, {}, struct {
        fn lt(_: void, a: FileWorkflow, b: FileWorkflow) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    if (name == null) {
        return writeList(out, catalog.items);
    }

    const want = name.?;
    if (want.len == 0) return lib.fail(out, "workflow name must not be empty");
    var found: ?FileWorkflow = null;
    for (catalog.items) |wf| {
        if (std.mem.eql(u8, wf.name, want)) {
            found = wf;
            break;
        }
    }
    const wf = found orelse return lib.fail(out, "no workflow named with that id");
    // Unified surface: a workflow can also carry a chain pipeline (frontmatter `chain:`).
    // When the caller asks with {"name":"x","chain":""} or simply inspects, surface it.
    if (wants_chain) {
        const c = extractChainFrontmatter(lib.alloc, wf.body) catch null;
        if (c) |cj| {
            const chain_field = lib.optStr(parsed, "chain") orelse "";
            if (chain_field.len == 0) return writeOneWithChain(out, wf, cj) else return writeOneWithChain(out, wf, cj);
        }
    }
    if (args.len > 0) {
        const expanded = instantiate(lib.alloc, wf.body, args) catch return lib.fail(out, "could not expand workflow");
        return writePrompt(out, wf.name, expanded);
    }
    return writeOne(out, wf);
}

const FileWorkflow = struct {
    name: []const u8,
    description: []const u8,
    arg_hint: []const u8,
    body: []const u8,
    rel_path: []const u8,
};

fn listMarkdownFiles(dir: []const u8) ![]const u8 {
    return try lib.fsList(dir);
}

fn parseWorkflow(alloc: std.mem.Allocator, stem: []const u8, rel_path: []const u8, raw: []const u8) !FileWorkflow {
    var name = try alloc.dupe(u8, stem);
    var description: []const u8 = "";
    var arg_hint: []const u8 = "";
    var body: []const u8 = raw;
    if (std.mem.startsWith(u8, raw, "---")) {
        const first_nl = std.mem.indexOfScalar(u8, raw, '\n') orelse raw.len;
        const first_line = std.mem.trim(u8, raw[0..first_nl], " \t\r");
        if (std.mem.eql(u8, first_line, "---")) {
            if (std.mem.indexOf(u8, raw[first_nl + 1 ..], "\n---")) |rel| {
                const fm_start = first_nl + 1;
                const fm_end = fm_start + rel;
                const fm = raw[fm_start..fm_end];
                const after = raw[fm_end + "\n---".len ..];
                body = if (after.len > 0 and after[0] == '\n') after[1..] else if (after.len > 0 and after[0] == '\r' and after.len > 1 and after[1] == '\n') after[2..] else after;
                var lines = std.mem.splitScalar(u8, fm, '\n');
                while (lines.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    if (trimmed.len == 0 or trimmed[0] == '#') continue;
                    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
                    const key = std.mem.trim(u8, trimmed[0..colon], " \t");
                    var val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                    if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or (val[0] == '\'' and val[val.len - 1] == '\''))) {
                        val = val[1 .. val.len - 1];
                    }
                    if (std.ascii.eqlIgnoreCase(key, "name") and val.len > 0) {
                        name = try alloc.dupe(u8, val);
                    } else if (std.ascii.eqlIgnoreCase(key, "description") and val.len > 0) {
                        description = try alloc.dupe(u8, val);
                    } else if ((std.ascii.eqlIgnoreCase(key, "argument-hint") or std.ascii.eqlIgnoreCase(key, "arg_hint") or std.ascii.eqlIgnoreCase(key, "args_hint")) and val.len > 0) {
                        arg_hint = try alloc.dupe(u8, val);
                    }
                }
            }
        }
    }
    body = std.mem.trim(u8, body, " \r\n");
    if (description.len == 0) description = try alloc.dupe(u8, inferDescription(body));
    if (description.len == 0) description = try alloc.dupe(u8, "no description");
    return .{ .name = name, .description = description, .arg_hint = arg_hint, .body = try alloc.dupe(u8, body), .rel_path = try alloc.dupe(u8, rel_path) };
}

fn inferDescription(body: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        var t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        while (t.len > 0 and t[0] == '#') t = std.mem.trim(u8, t[1..], " \t");
        if (t.len == 0) continue;
        const end = @min(t.len, 120);
        if (std.mem.indexOfScalar(u8, t[0..end], '.')) |dot| {
            if (dot >= 20) return t[0 .. dot + 1];
        }
        return t[0..end];
    }
    return "";
}

fn instantiate(alloc: std.mem.Allocator, body: []const u8, args: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, body, "{{") == null and std.mem.indexOf(u8, body, "$ARGUMENTS") == null) {
        if (args.len == 0) return body;
        return try std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ body, args });
    }
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < body.len) {
        if (std.mem.startsWith(u8, body[i..], "{{args}}")) {
            try out.appendSlice(alloc, args);
            i += "{{args}}".len;
        } else if (std.mem.startsWith(u8, body[i..], "{{arguments}}")) {
            try out.appendSlice(alloc, args);
            i += "{{arguments}}".len;
        } else if (std.mem.startsWith(u8, body[i..], "{{$args}}")) {
            try out.appendSlice(alloc, args);
            i += "{{$args}}".len;
        } else if (std.mem.startsWith(u8, body[i..], "$ARGUMENTS")) {
            try out.appendSlice(alloc, args);
            i += "$ARGUMENTS".len;
        } else {
            try out.append(alloc, body[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

fn writeList(out: *lib.Out, wfs: []const FileWorkflow) !void {
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("workflows");
    try s.beginArray();
    for (wfs) |wf| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(wf.name);
        try s.objectField("description");
        try s.write(wf.description);
        try s.objectField("arg_hint");
        try s.write(wf.arg_hint);
        try s.objectField("rel_path");
        try s.write(wf.rel_path);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

fn writeOne(out: *lib.Out, wf: FileWorkflow) !void {
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("workflow");
    try s.beginObject();
    try s.objectField("name");
    try s.write(wf.name);
    try s.objectField("description");
    try s.write(wf.description);
    try s.objectField("arg_hint");
    try s.write(wf.arg_hint);
    try s.objectField("rel_path");
    try s.write(wf.rel_path);
    try s.objectField("body");
    try s.write(wf.body);
    try s.endObject();
    try s.endObject();
    lib.commit(out, &w);
}

fn writeOneWithChain(out: *lib.Out, wf: FileWorkflow, chain_json: []const u8) !void {
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("workflow");
    try s.beginObject();
    try s.objectField("name");
    try s.write(wf.name);
    try s.objectField("description");
    try s.write(wf.description);
    try s.objectField("arg_hint");
    try s.write(wf.arg_hint);
    try s.objectField("rel_path");
    try s.write(wf.rel_path);
    try s.objectField("body");
    try s.write(wf.body);
    try s.objectField("chain");
    try s.write(chain_json);
    try s.endObject();
    try s.endObject();
    lib.commit(out, &w);
}

fn extractChainFrontmatter(alloc: std.mem.Allocator, body: []const u8) !?[]const u8 {
    // Very small frontmatter chain extraction: look for `chain:` line in leading `---` block.
    if (!std.mem.startsWith(u8, body, "---")) return null;
    const first_nl = std.mem.indexOfScalar(u8, body, '\n') orelse return null;
    const first_line = std.mem.trim(u8, body[0..first_nl], " \t\r");
    if (!std.mem.eql(u8, first_line, "---")) return null;
    const rel = std.mem.indexOf(u8, body[first_nl + 1 ..], "\n---") orelse return null;
    const fm = body[first_nl + 1 .. first_nl + 1 + rel];
    var lines = std.mem.splitScalar(u8, fm, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "chain")) continue;
        var val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or (val[0] == '\'' and val[val.len - 1] == '\''))) {
            val = val[1 .. val.len - 1];
        }
        if (val.len > 0) return try alloc.dupe(u8, val);
    }
    return null;
}

fn writePrompt(out: *lib.Out, name: []const u8, prompt: []const u8) !void {
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("name");
    try s.write(name);
    try s.objectField("prompt");
    try s.write(prompt);
    try s.endObject();
    lib.commit(out, &w);
}
