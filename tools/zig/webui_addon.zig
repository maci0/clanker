//! webui_addon: create and toggle ad-hoc web UI views under ui/plugins/.
//!
//! The page discovers those directories at request time, so a chat that
//! writes plugin.json + app.js can add a view without rebuilding clanker.
//! Enable writes state/webui_plugins.json; the browser picks the new script
//! up on System → Web UI plugins Refresh, or a reload.

const std = @import("std");
const lib = @import("lib.zig");
const logic = @import("webui_addon_logic.zig");

pub const input_scratch_cap = 512 * 1024;

const plugins_dir = "ui/plugins";
const state_path = "state/webui_plugins.json";

const State = struct {
    enabled: []const []const u8 = &.{},
    disabled: []const []const u8 = &.{},
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const obj = try lib.object(input);
    const action = lib.optStr(obj, "action") orelse "list";
    if (std.mem.eql(u8, action, "list")) return actionList(out);
    if (std.mem.eql(u8, action, "create")) return actionCreate(obj, out);
    if (std.mem.eql(u8, action, "put")) return actionPut(obj, out);
    if (std.mem.eql(u8, action, "show")) return actionShow(obj, out);
    if (std.mem.eql(u8, action, "enable")) return actionToggle(obj, out, true);
    if (std.mem.eql(u8, action, "disable")) return actionToggle(obj, out, false);
    try lib.fail(out, "unknown action (list, create, put, show, enable, disable)");
}

fn actionList(out: *lib.Out) !void {
    const state = loadState();
    const raw = lib.fsList(plugins_dir) catch {
        return writeList(out, &.{}, state);
    };
    const names = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{}) catch {
        return writeList(out, &.{}, state);
    };
    var addons: std.ArrayList(Listed) = .empty;
    if (names == .array) {
        for (names.array.items) |item| {
            if (item != .string) continue;
            var name = item.string;
            if (name.len > 0 and name[name.len - 1] == '/') name = name[0 .. name.len - 1];
            if (!logic.validName(name)) continue;
            const manifest_path = try std.fmt.allocPrint(lib.alloc, "{s}/{s}/plugin.json", .{ plugins_dir, name });
            const raw_m = lib.fsRead(manifest_path) catch continue;
            const m = std.json.parseFromSliceLeaky(Manifest, lib.alloc, raw_m, .{ .ignore_unknown_fields = true }) catch |err| {
                // Surface the broken manifest instead of silently dropping it:
                // an addon whose plugin.json does not parse is listed with a
                // diagnostic description so its owner can see why it vanished.
                const diag = std.fmt.allocPrint(lib.alloc, "plugin.json failed to parse ({s})", .{@errorName(err)}) catch continue;
                try addons.append(lib.alloc, .{
                    .name = name,
                    .title = name,
                    .description = diag,
                    .group = "Watch",
                    .enabled = logic.addonEnabled(state.enabled, state.disabled, name),
                    .has_css = hasCss(name),
                });
                continue;
            };
            if (logic.capabilitiesRejected(m.capabilities)) |_| continue;
            try addons.append(lib.alloc, .{
                .name = name,
                .title = if (m.title.len > 0) m.title else name,
                .description = m.description,
                .group = if (m.group.len > 0) m.group else "Watch",
                .enabled = logic.addonEnabled(state.enabled, state.disabled, name),
                .has_css = hasCss(name),
                .capabilities = m.capabilities,
                .eager = m.eager,
                .module = m.module,
            });
        }
    }
    return writeList(out, addons.items, state);
}

const Listed = struct {
    name: []const u8,
    title: []const u8,
    description: []const u8,
    group: []const u8,
    enabled: bool,
    has_css: bool,
    capabilities: []const []const u8 = &.{},
    eager: bool = false,
    module: bool = false,
};

fn hasCss(name: []const u8) bool {
    const css_path = std.fmt.allocPrint(lib.alloc, "{s}/{s}/app.css", .{ plugins_dir, name }) catch return false;
    if (lib.fsStat(css_path)) |_| return true else |_| return false;
}

fn writeList(out: *lib.Out, addons: []const Listed, state: State) !void {
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("hint");
    try s.write("Turn an addon on with action=enable. The page loads new scripts from System → Web UI plugins (Refresh) or a reload.");
    try s.objectField("addons");
    try s.beginArray();
    for (addons) |a| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(a.name);
        try s.objectField("title");
        try s.write(a.title);
        try s.objectField("description");
        try s.write(a.description);
        try s.objectField("group");
        try s.write(a.group);
        try s.objectField("enabled");
        try s.write(a.enabled);
        try s.objectField("has_css");
        try s.write(a.has_css);
        try s.objectField("capabilities");
        try s.beginArray();
        for (a.capabilities) |c| try s.write(c);
        try s.endArray();
        try s.objectField("eager");
        try s.write(a.eager);
        try s.objectField("module");
        try s.write(a.module);
        try s.objectField("path");
        try s.write(try std.fmt.allocPrint(lib.alloc, "ui/plugins/{s}/", .{a.name}));
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("enabled");
    try s.beginArray();
    for (state.enabled) |e| try s.write(e);
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

const Manifest = struct {
    name: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
    group: []const u8 = "Watch",
    capabilities: []const []const u8 = &.{},
    /// True when the addon does work outside its own view (a persistent dock,
    /// a live subscription) and so must run at page load. The default is false
    /// because a view-only addon's `app.js` is dead weight until its tab is
    /// opened: the page registers its tab from this manifest and fetches the
    /// script on first open. Nine shipped addons at ~200 KB of script and CSS
    /// used to load on every visit, chat-only ones included.
    eager: bool = false,
    /// True when the addon is not a view at all: its `app.js` is an ES module
    /// loaded by a core view that needs it (arena3d), so the page must not
    /// build a tab for it or fetch it as a classic script. The System →
    /// Web UI plugins checkbox still gates its assets.
    module: bool = false,
};

fn actionCreate(obj: std.json.Value, out: *lib.Out) !void {
    const name = lib.optStr(obj, "name") orelse return lib.fail(out, "create needs name");
    if (!logic.validName(name)) return lib.fail(out, "name must be 1-64 letters, digits, '-' or '_'");
    const title = lib.optStr(obj, "title") orelse name;
    if (title.len == 0 or title.len > logic.max_title_len) return lib.fail(out, "title must be 1-64 characters");
    const description = lib.optStr(obj, "description") orelse "";
    if (description.len > logic.max_desc_len) return lib.fail(out, "description is too long");
    const group = lib.optStr(obj, "group") orelse "Watch";
    if (!logic.validGroup(group)) return lib.fail(out, "group must be Work, Watch, or Set up");
    const js = lib.optStr(obj, "js") orelse return lib.fail(out, "create needs js (the app.js source)");
    if (logic.jsRejected(js)) |why| return lib.fail(out, why);
    const css = lib.optStr(obj, "css") orelse "";
    if (logic.cssRejected(css)) |why| return lib.fail(out, why);
    const overwrite = lib.optBool(obj, "overwrite", false);
    const enable = lib.optBool(obj, "enable", true);
    const eager = lib.optBool(obj, "eager", false);
    const is_module = lib.optBool(obj, "module", false);
    if (eager and is_module) return lib.fail(out, "eager and module are mutually exclusive: an addon cannot both run at page load and be a non-view module");

    const dir = try std.fmt.allocPrint(lib.alloc, "{s}/{s}", .{ plugins_dir, name });
    const manifest_path = try std.fmt.allocPrint(lib.alloc, "{s}/plugin.json", .{dir});
    if (!overwrite) {
        if (lib.fsStat(manifest_path)) |_| {
            return lib.fail(out, "addon already exists; pass overwrite:true to replace it");
        } else |_| {}
    }
    lib.fsMkdir(plugins_dir) catch {};
    lib.fsMkdir(dir) catch |err| {
        return lib.failErr(out, err, "creating the addon directory");
    };

    const manifest = try writeManifestJson(name, title, description, group, eager, is_module);
    lib.fsWrite(manifest_path, manifest) catch |err| return lib.failErr(out, err, "writing plugin.json");
    const js_path = try std.fmt.allocPrint(lib.alloc, "{s}/app.js", .{dir});
    lib.fsWrite(js_path, js) catch |err| return lib.failErr(out, err, "writing app.js");
    if (css.len > 0) {
        const css_path = try std.fmt.allocPrint(lib.alloc, "{s}/app.css", .{dir});
        lib.fsWrite(css_path, css) catch |err| return lib.failErr(out, err, "writing app.css");
    }
    if (enable) setEnabled(name, true) catch |err| return lib.failErr(out, err, "enabling the addon");

    return writeOk(out, name, enable);
}

fn actionPut(obj: std.json.Value, out: *lib.Out) !void {
    const name = lib.optStr(obj, "name") orelse return lib.fail(out, "put needs name");
    if (!logic.validName(name)) return lib.fail(out, "bad addon name");
    const file = lib.optStr(obj, "file") orelse return lib.fail(out, "put needs file (app.js, app.css, or plugin.json)");
    if (!logic.validFile(file)) return lib.fail(out, "file must be app.js, app.css, or plugin.json");
    const content = lib.optStr(obj, "content") orelse return lib.fail(out, "put needs content");
    if (content.len > 1024 * 1024) return lib.fail(out, "content exceeds the 1 MiB limit for a single put call");
    if (std.mem.eql(u8, file, "app.js")) {
        if (logic.jsRejected(content)) |why| return lib.fail(out, why);
    } else if (std.mem.eql(u8, file, "app.css")) {
        if (logic.cssRejected(content)) |why| return lib.fail(out, why);
    } else {
        const m = std.json.parseFromSliceLeaky(Manifest, lib.alloc, content, .{ .ignore_unknown_fields = true }) catch
            return lib.fail(out, "plugin.json is not valid JSON");
        if (logic.capabilitiesRejected(m.capabilities)) |why| return lib.fail(out, why);
        if (!std.mem.eql(u8, m.name, name)) return lib.fail(out, "plugin.json name must match the addon directory");
        if (m.title.len == 0 or m.title.len > logic.max_title_len) return lib.fail(out, "title must be 1-64 characters");
        if (m.description.len > logic.max_desc_len) return lib.fail(out, "description is too long");
        if (!logic.validGroup(m.group)) return lib.fail(out, "group must be Work, Watch, or Set up");
        if (m.eager and m.module) return lib.fail(out, "plugin.json: eager and module are mutually exclusive; an addon cannot both run at page load and be a non-view module");
    }
    const dir = try std.fmt.allocPrint(lib.alloc, "{s}/{s}", .{ plugins_dir, name });
    if (lib.fsStat(dir)) |_| {} else |_| return lib.fail(out, "no such addon (create it first)");
    const path = try std.fmt.allocPrint(lib.alloc, "{s}/{s}", .{ dir, file });
    lib.fsWrite(path, content) catch |err| return lib.failErr(out, err, "writing the file");
    const st = loadState();
    return writeOk(out, name, logic.addonEnabled(st.enabled, st.disabled, name));
}

fn actionShow(obj: std.json.Value, out: *lib.Out) !void {
    const name = lib.optStr(obj, "name") orelse return lib.fail(out, "show needs name");
    if (!logic.validName(name)) return lib.fail(out, "bad addon name");
    const dir = try std.fmt.allocPrint(lib.alloc, "{s}/{s}", .{ plugins_dir, name });
    const manifest_path = try std.fmt.allocPrint(lib.alloc, "{s}/plugin.json", .{dir});
    const js_path = try std.fmt.allocPrint(lib.alloc, "{s}/app.js", .{dir});
    const css_path = try std.fmt.allocPrint(lib.alloc, "{s}/app.css", .{dir});
    const manifest = lib.fsRead(manifest_path) catch return lib.fail(out, "no such addon");
    const js = lib.fsRead(js_path) catch "";
    const css = lib.fsRead(css_path) catch "";
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("name");
    try s.write(name);
    try s.objectField("enabled");
    const st = loadState();
    try s.write(logic.addonEnabled(st.enabled, st.disabled, name));
    try s.objectField("plugin_json");
    try s.write(manifest);
    try s.objectField("js");
    try s.write(js);
    try s.objectField("css");
    try s.write(css);
    try s.endObject();
    lib.commit(out, &w);
}

fn actionToggle(obj: std.json.Value, out: *lib.Out, on: bool) !void {
    const name = lib.optStr(obj, "name") orelse return lib.fail(out, "needs name");
    if (!logic.validName(name)) return lib.fail(out, "bad addon name");
    const manifest_path = try std.fmt.allocPrint(lib.alloc, "{s}/{s}/plugin.json", .{ plugins_dir, name });
    if (lib.fsStat(manifest_path)) |_| {} else |_| return lib.fail(out, "no such addon");
    setEnabled(name, on) catch |err| return lib.failErr(out, err, "updating plugin state");
    return writeOk(out, name, on);
}

fn writeOk(out: *lib.Out, name: []const u8, enabled: bool) !void {
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("name");
    try s.write(name);
    try s.objectField("enabled");
    try s.write(enabled);
    try s.objectField("path");
    try s.write(try std.fmt.allocPrint(lib.alloc, "ui/plugins/{s}/", .{name}));
    try s.objectField("next");
    try s.write("The addon is on disk. If this page is already open, System → Web UI plugins → Refresh (or reload) loads the new script.");
    try s.endObject();
    lib.commit(out, &w);
}

fn writeManifestJson(name: []const u8, title: []const u8, description: []const u8, group: []const u8, eager: bool, is_module: bool) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(lib.alloc);
    var s = std.json.Stringify{ .writer = &buf.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("name");
    try s.write(name);
    try s.objectField("title");
    try s.write(title);
    try s.objectField("description");
    try s.write(description);
    try s.objectField("group");
    try s.write(group);
    if (eager) {
        try s.objectField("eager");
        try s.write(true);
    }
    if (is_module) {
        try s.objectField("module");
        try s.write(true);
    }
    try s.endObject();
    try buf.writer.writeByte('\n');
    return buf.written();
}

fn loadState() State {
    const raw = lib.fsRead(state_path) catch |err| {
        // Fresh checkout: the state file has never been written. The native
        // HTTP handler used to seed the same defaults here, and the two
        // disagreeing copies were the bug: on a fresh checkout the page showed
        // files+music on while the guest saw them off, and the first enable
        // then wrote a list without them. One owner, one seed.
        if (err == error.NotFound) return .{ .enabled = &logic.default_enabled };
        warnBadState("could not be read", err);
        return .{};
    };
    return std.json.parseFromSliceLeaky(State, lib.alloc, raw, .{ .ignore_unknown_fields = true }) catch |err| {
        // A corrupt file must not pass for "every plugin off": that reads as
        // a deliberate setting and gets debugged in the browser. Falling back
        // to empty is still right — the next successful toggle rewrites a
        // clean file — but the fallback has to be announced.
        warnBadState("failed to parse", err);
        return .{};
    };
}

fn warnBadState(what: []const u8, err: anyerror) void {
    var buf: [192]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "{s} {s} ({s}); treating it as an empty enabled-list until the next toggle rewrites it",
        .{ state_path, what, @errorName(err) },
    ) catch state_path;
    lib.log(2, msg);
}

fn setEnabled(name: []const u8, on: bool) !void {
    const state = loadState();
    const next_on = try logic.mergeEnabled(lib.alloc, state.enabled, name, on);
    const next_off = try logic.mergeEnabled(lib.alloc, state.disabled, name, !on);
    var buf: std.Io.Writer.Allocating = .init(lib.alloc);
    var s = std.json.Stringify{ .writer = &buf.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("enabled");
    try s.beginArray();
    for (next_on) |e| try s.write(e);
    try s.endArray();
    try s.objectField("disabled");
    try s.beginArray();
    for (next_off) |e| try s.write(e);
    try s.endArray();
    try s.endObject();
    try lib.fsWrite(state_path, buf.written());
}
