//! skills: list, show, search, and enable/disable markdown skills.
//!
//! Input:  {}                          → list (name, title, description, bytes, enabled)
//!         {"name":"research"}         → show that skill's full body + metadata
//!         {"query":"facts"}           → list skills whose name/title/body match
//!         {"action":"set_enabled","name":"research","enabled":false}
//! Output: {"ok":true,"skills":[...]} | {"ok":true,"skill":{...}} | {"ok":false,...}
//!
//! Same discovery the system prompt uses (*.md, no SYSTEM.md, >= 20 bytes,
//! sorted, frontmatter + sidecar enable). The HTTP `/api/skills` route
//! relays list and set_enabled.

const std = @import("std");
const lib = @import("lib.zig");
const logic = @import("skills_logic.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

const Listed = struct {
    name: []const u8,
    title: []const u8,
    description: []const u8,
    bytes: usize,
    body: []const u8,
    enabled: bool,
    frontmatter_enabled: bool,
};

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{ .ignore_unknown_fields = true }) catch
        return lib.fail(out, "expected a JSON object");
    if (parsed != .object) return lib.fail(out, "expected a JSON object");

    const action = lib.optStr(parsed, "action") orelse "";
    const name = lib.optStr(parsed, "name");
    const query = lib.optStr(parsed, "query") orelse "";
    if (name) |n| {
        if (!logic.validSkillName(n)) return lib.fail(out, "skill name must not be empty or a path");
    }

    const skills_dir = resolveSkillsDir();
    if (skills_dir.len == 0) return lib.fail(out, "skills are disabled (agent.skills_dir is empty)");

    if (std.mem.eql(u8, action, "set_enabled")) {
        const n = name orelse return lib.fail(out, "set_enabled needs a name");
        if (parsed.object.get("enabled") == null) return lib.fail(out, "set_enabled needs enabled");
        return setEnabled(n, lib.optBool(parsed, "enabled", false), skills_dir, out);
    }
    if (action.len > 0 and !std.mem.eql(u8, action, "list") and !std.mem.eql(u8, action, "show") and !std.mem.eql(u8, action, "search"))
        return lib.fail(out, "action must be list, show, search, or set_enabled");

    var catalog: std.ArrayList(Listed) = .empty;
    const disabled = loadDisabled();
    const names_json = lib.fsList(skills_dir) catch |err| switch (err) {
        error.NotFound => {
            if (name != null) return lib.fail(out, "no such skill");
            return writeList(out, &.{});
        },
        else => return lib.failErr(out, err, "listing skills"),
    };
    const names_val = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, names_json, .{}) catch
        return writeList(out, &.{});
    if (names_val == .array) {
        for (names_val.array.items) |item| {
            if (item != .string) continue;
            const fname = item.string;
            if (!logic.isSkillFile(fname)) continue;
            const fpath = std.fmt.allocPrint(lib.alloc, "{s}/{s}", .{ skills_dir, fname }) catch continue;
            const raw = lib.fsRead(fpath) catch continue;
            const meta = logic.parseMeta(raw) orelse continue;
            catalog.append(lib.alloc, .{
                .name = fname,
                .title = meta.title,
                .description = meta.description,
                .bytes = raw.len,
                .body = raw,
                .enabled = logic.isEnabled(meta, fname, disabled),
                .frontmatter_enabled = meta.enabled,
            }) catch continue;
        }
    }
    std.mem.sort(Listed, catalog.items, {}, struct {
        fn lt(_: void, a: Listed, b: Listed) bool {
            return logic.nameLessThan({}, a.name, b.name);
        }
    }.lt);

    if (name) |want| {
        for (catalog.items) |sk| {
            if (logic.nameMatches(sk.name, want)) return writeOne(out, sk);
        }
        return lib.fail(out, "no such skill");
    }

    if (query.len == 0) return writeList(out, catalog.items);

    var hits: std.ArrayList(Listed) = .empty;
    for (catalog.items) |sk| {
        if (logic.matchesQuery(query, sk.name, sk.title, sk.description, sk.body)) {
            hits.append(lib.alloc, sk) catch continue;
        }
    }
    return writeList(out, hits.items);
}

fn resolveSkillsDir() []const u8 {
    var skills_dir: []const u8 = "skills";
    const cfg_raw = lib.harnessConfig();
    if (cfg_raw.len > 4) {
        const cfg = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, cfg_raw, .{ .ignore_unknown_fields = true }) catch null;
        if (cfg) |c| {
            if (c == .object) {
                if (c.object.get("agent")) |ag| if (ag == .object) {
                    if (ag.object.get("skills_dir")) |sd| if (sd == .string) {
                        skills_dir = sd.string;
                    };
                };
            }
        }
    }
    return skills_dir;
}

fn writeList(out: *lib.Out, skills: []const Listed) !void {
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("skills");
    try s.beginArray();
    for (skills) |sk| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(sk.name);
        try s.objectField("title");
        try s.write(sk.title);
        try s.objectField("description");
        try s.write(sk.description);
        try s.objectField("bytes");
        try s.write(sk.bytes);
        try s.objectField("enabled");
        try s.write(sk.enabled);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

fn writeOne(out: *lib.Out, sk: Listed) !void {
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("skill");
    try s.beginObject();
    try s.objectField("name");
    try s.write(sk.name);
    try s.objectField("title");
    try s.write(sk.title);
    try s.objectField("description");
    try s.write(sk.description);
    try s.objectField("bytes");
    try s.write(sk.bytes);
    try s.objectField("enabled");
    try s.write(sk.enabled);
    try s.objectField("body");
    try s.write(sk.body);
    try s.endObject();
    try s.endObject();
    lib.commit(out, &w);
}

fn loadDisabled() []const []const u8 {
    const raw = lib.fsRead(logic.overrides_path) catch return &.{};
    return logic.parseOverrides(lib.alloc, raw).disabled;
}

fn setEnabled(name: []const u8, on: bool, skills_dir: []const u8, out: *lib.Out) !void {
    const fname = resolveExisting(skills_dir, name) orelse return lib.fail(out, "no such skill");
    const fpath = std.fmt.allocPrint(lib.alloc, "{s}/{s}", .{ skills_dir, fname }) catch
        return lib.fail(out, "no such skill");
    const raw = lib.fsRead(fpath) catch return lib.fail(out, "no such skill");
    const meta = logic.parseMeta(raw) orelse return lib.fail(out, "no such skill");
    if (!meta.enabled and on)
        return lib.fail(out, "skill is disabled in its frontmatter");
    const next = try logic.mergeDisabled(lib.alloc, loadDisabled(), fname, on);
    const json = try logic.writeDisabledJson(lib.alloc, next);
    lib.fsWrite(logic.overrides_path, json) catch |err| return lib.failErr(out, err, "writing skills overrides");
    const listed = Listed{
        .name = fname,
        .title = meta.title,
        .description = meta.description,
        .bytes = raw.len,
        .body = raw,
        .enabled = on,
        .frontmatter_enabled = meta.enabled,
    };
    return writeOne(out, listed);
}

fn resolveExisting(skills_dir: []const u8, want: []const u8) ?[]const u8 {
    const names_json = lib.fsList(skills_dir) catch return null;
    const names_val = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, names_json, .{}) catch return null;
    if (names_val != .array) return null;
    for (names_val.array.items) |item| {
        if (item != .string) continue;
        if (!logic.isSkillFile(item.string)) continue;
        if (logic.nameMatches(item.string, want)) return item.string;
    }
    return null;
}
