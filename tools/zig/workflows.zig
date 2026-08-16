//! workflows: list and inspect reusable prompt templates stored as markdown files.
//!
//! Input:  {}                          → list every workflow (name, arg_hint, description, rel_path)
//!         {"name":"plan"}             → show that workflow's full body + metadata
//!         {"name":"plan","args":"..."} → expand it with args substituted, returning the prompt
//! Output: {"ok":true,"workflows":[...]} | {"ok":true,"workflow":{...}} | {"ok":true,"prompt":"..."} | {"ok":false,...}

const std = @import("std");
const lib = @import("lib.zig");
const logic = @import("workflows_logic.zig");

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

    var catalog: std.ArrayList(logic.Workflow) = .empty;
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
            const wf = logic.parseWorkflow(lib.alloc, stem, fname, raw) catch continue;
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
    std.mem.sort(logic.Workflow, catalog.items, {}, struct {
        fn lt(_: void, a: logic.Workflow, b: logic.Workflow) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    if (name == null) {
        return writeList(out, catalog.items);
    }

    const want = name.?;
    if (want.len == 0) return lib.fail(out, "workflow name must not be empty");
    var found: ?logic.Workflow = null;
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
        const c = logic.extractChainFrontmatter(lib.alloc, wf.body) catch null;
        if (c) |cj| return writeOneWithChain(out, wf, cj);
    }
    if (args.len > 0) {
        const expanded = logic.instantiate(lib.alloc, wf.body, args) catch return lib.fail(out, "could not expand workflow");
        return writePrompt(out, wf.name, expanded);
    }
    return writeOne(out, wf);
}

fn listMarkdownFiles(dir: []const u8) ![]const u8 {
    return try lib.fsList(dir);
}

fn writeList(out: *lib.Out, wfs: []const logic.Workflow) !void {
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
        try s.objectField("tags");
        try s.beginArray();
        for (wf.tags) |t| try s.write(t);
        try s.endArray();
        try s.objectField("chain");
        try s.write(wf.chain_json != null);
        try s.objectField("rel_path");
        try s.write(wf.rel_path);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

fn writeOne(out: *lib.Out, wf: logic.Workflow) !void {
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

fn writeOneWithChain(out: *lib.Out, wf: logic.Workflow, chain_json: []const u8) !void {
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
