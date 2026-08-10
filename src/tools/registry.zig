//! Tool registry: loads `*.tool.json` descriptors from the tools directory.
//! Descriptors are the agent-editable metadata (name, description, JSON
//! schema, sandbox policy); the WASM module itself implements behavior.

const std = @import("std");
const json = std.json;
const types = @import("../llm/types.zig");
const log = @import("../util/log.zig");

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// Wasm file name relative to the tools directory.
    wasm: []const u8,
    input_schema: json.Value,
    /// Hosts this tool may reach via ck_http (empty = no network).
    network_allow: []const []const u8 = &.{},
    /// Directory prefixes (relative to the sandbox root) the tool may access
    /// via ck_fs_*; empty = filesystem denied.
    fs_prefixes: []const []const u8 = &.{},
    /// If true, the tool is loaded and runnable but hidden from the LLM catalog.
    internal: bool = false,
    /// Machine-local on/off switch from `state/plugins.json`. Disabled tools
    /// stay loadable (the REPL still lists them) but are withheld from the LLM
    /// catalog and refused at execution.
    enabled: bool = true,
    /// May call the model through `ck_llm`. Costs tokens, so it is opt-in per
    /// descriptor and forces the tool onto the sequential execution path.
    llm: bool = false,
    /// Free-form per-plugin settings from the descriptor's `config` object,
    /// handed to the guest verbatim via `ck_config`. The harness only reads the
    /// `provider` / `model` / `max_tokens` keys, to aim `ck_llm` at a specific
    /// backend; everything else is the plugin's own business.
    config: json.Value = .{ .object = .{} },
    /// Set when this tool rewrites another tool's input or output.
    transform: ?Transform = null,

    /// Core tools (the `cmd_*` slash commands, the web UI, the formatter) back
    /// the harness itself and stay on. A transform is hidden from the model
    /// like an internal tool, but switching it off is the whole point of it.
    pub fn toggleable(self: Tool) bool {
        return !self.internal or self.transform != null;
    }
};

/// A transform plugin sits in the chain around other tools: `before` rewrites
/// the arguments going in, `after` rewrites the result coming out. Lower
/// `order` runs first, and `tools` may name specific tools or `*` for all.
pub const Transform = struct {
    pub const Phase = enum { before, after };

    phase: Phase,
    tools: []const []const u8 = &.{"*"},
    order: i64 = 0,

    pub fn appliesTo(self: Transform, tool_name: []const u8) bool {
        for (self.tools) |t| {
            if (std.mem.eql(u8, t, "*") or std.mem.eql(u8, t, tool_name)) return true;
        }
        return false;
    }
};

/// Machine-local plugin toggles: `{"disabled": ["web_search"]}`. Lives under
/// state/ because it is per-checkout runtime state, not project configuration.
pub const plugins_state_path = "state/plugins.json";

pub const Registry = struct {
    tools: std.StringArrayHashMapUnmanaged(Tool) = .empty,

    pub fn load(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir, tools_dir: []const u8) !Registry {
        var reg = Registry{};

        var dir = base.openDir(io, tools_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                log.log(.warn, "tools dir '{s}' not found; run `zig build tools`", .{tools_dir});
                return reg;
            },
            else => return err,
        };
        defer dir.close(io);

        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".tool.json")) continue;
            const raw = dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20)) catch |err| {
                log.log(.warn, "cannot read tool descriptor '{s}': {s}", .{ entry.name, @errorName(err) });
                continue;
            };
            const tool = parseDescriptor(arena, raw, tools_dir) catch |err| {
                log.log(.warn, "invalid tool descriptor '{s}': {s}", .{ entry.name, @errorName(err) });
                continue;
            };
            try reg.tools.put(arena, tool.name, tool);
        }
        reg.applyToggles(io, arena, base);
        return reg;
    }

    /// Marks tools listed in `state/plugins.json` as disabled. Internal tools
    /// are skipped: they back the REPL slash commands and the HTTP routes, so
    /// switching one off would break the harness rather than a plugin.
    fn applyToggles(self: *Registry, io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir) void {
        const raw = base.readFileAlloc(io, plugins_state_path, arena, .limited(64 * 1024)) catch return;
        const parsed = json.parseFromSliceLeaky(json.Value, arena, raw, .{ .ignore_unknown_fields = true }) catch {
            log.log(.warn, "invalid {s}; leaving every plugin at its descriptor default", .{plugins_state_path});
            return;
        };
        if (parsed != .object) return;
        self.applyToggleList(parsed.object.get("disabled"), false);
        self.applyToggleList(parsed.object.get("enabled"), true);
    }

    fn applyToggleList(self: *Registry, list: ?json.Value, value: bool) void {
        const arr = switch (list orelse return) {
            .array => |a| a,
            else => return,
        };
        for (arr.items) |v| {
            if (v != .string) continue;
            const t = self.tools.getPtr(v.string) orelse continue;
            if (!t.toggleable()) continue;
            t.enabled = value;
        }
    }

    pub fn get(self: *const Registry, name: []const u8) ?*const Tool {
        return self.tools.getPtr(name);
    }

    pub fn names(self: *const Registry, arena: std.mem.Allocator) ![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var it = self.tools.iterator();
        while (it.next()) |kv| try out.append(arena, kv.key_ptr.*);
        return out.toOwnedSlice(arena);
    }

    /// Converts registry tools into LLM ToolDefs (in the given arena).
    pub fn toToolDefs(self: *const Registry, arena: std.mem.Allocator) ![]types.ToolDef {
        var out: std.ArrayList(types.ToolDef) = .empty;
        var it = self.tools.iterator();
        while (it.next()) |kv| {
            const t = kv.value_ptr.*;
            if (t.internal or !t.enabled) continue;
            try out.append(arena, .{
                .name = t.name,
                .description = t.description,
                .input_schema = t.input_schema,
                .internal = t.internal,
            });
        }
        return out.toOwnedSlice(arena);
    }

    fn parseDescriptor(arena: std.mem.Allocator, raw: []const u8, tools_dir: []const u8) !Tool {
        const v = try json.parseFromSliceLeaky(json.Value, arena, raw, .{ .ignore_unknown_fields = true });
        const obj = switch (v) {
            .object => |o| o,
            else => return error.DescriptorNotObject,
        };
        var t = Tool{
            .name = try strField(obj, "name"),
            .description = try strField(obj, "description"),
            .wasm = try strField(obj, "wasm"),
            .input_schema = obj.get("input_schema") orelse .{ .object = .empty },
        };
        _ = tools_dir;
        if (obj.get("network_allow")) |na| {
            switch (na) {
                .array => |arr| t.network_allow = try strArray(arena, arr),
                else => {},
            }
        }
        if (obj.get("fs_prefixes")) |fp| {
            switch (fp) {
                .array => |arr| t.fs_prefixes = try strArray(arena, arr),
                else => {},
            }
        }
        if (obj.get("internal")) |iv| {
            switch (iv) {
                .bool => |b| t.internal = b,
                else => {},
            }
        }
        // A descriptor may ship switched off: a transform that spends tokens on
        // every tool call has to be opted into, not opted out of.
        if (obj.get("enabled")) |ev| {
            switch (ev) {
                .bool => |b| t.enabled = b,
                else => {},
            }
        }
        if (obj.get("llm")) |lv| {
            switch (lv) {
                .bool => |b| t.llm = b,
                else => {},
            }
        }
        if (obj.get("config")) |cv| {
            if (cv == .object) t.config = cv;
        }
        if (obj.get("transform")) |tv| {
            if (tv == .object) t.transform = try parseTransform(arena, tv.object);
        }
        return t;
    }

    fn parseTransform(arena: std.mem.Allocator, obj: json.ObjectMap) !Transform {
        const phase_str = switch (obj.get("phase") orelse return error.TransformPhaseMissing) {
            .string => |s| s,
            else => return error.TransformPhaseMissing,
        };
        var tr = Transform{
            .phase = if (std.mem.eql(u8, phase_str, "before"))
                .before
            else if (std.mem.eql(u8, phase_str, "after"))
                .after
            else
                return error.TransformPhaseInvalid,
        };
        if (obj.get("tools")) |tv| {
            switch (tv) {
                .array => |arr| tr.tools = try strArray(arena, arr),
                else => {},
            }
        }
        if (obj.get("order")) |ov| {
            switch (ov) {
                .integer => |i| tr.order = i,
                else => {},
            }
        }
        return tr;
    }

    /// Enabled transform plugins that wrap `tool_name` in `phase`, ordered.
    /// A transform never wraps itself or another transform.
    pub fn transformsFor(
        self: *const Registry,
        arena: std.mem.Allocator,
        tool_name: []const u8,
        phase: Transform.Phase,
    ) ![]const *const Tool {
        var out: std.ArrayList(*const Tool) = .empty;
        var it = self.tools.iterator();
        while (it.next()) |kv| {
            const t = kv.value_ptr;
            const tr = t.transform orelse continue;
            if (!t.enabled or tr.phase != phase) continue;
            if (std.mem.eql(u8, t.name, tool_name)) continue;
            if (!tr.appliesTo(tool_name)) continue;
            try out.append(arena, t);
        }
        std.mem.sort(*const Tool, out.items, {}, struct {
            fn lt(_: void, a: *const Tool, b: *const Tool) bool {
                return a.transform.?.order < b.transform.?.order;
            }
        }.lt);
        return out.items;
    }

    fn strArray(arena: std.mem.Allocator, arr: json.Array) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (arr.items) |item| {
            switch (item) {
                .string => |s| try out.append(arena, s),
                else => {},
            }
        }
        return out.toOwnedSlice(arena);
    }

    fn strField(obj: json.ObjectMap, key: []const u8) ![]const u8 {
        const v = obj.get(key) orelse return error.MissingField;
        return switch (v) {
            .string => |s| s,
            else => error.FieldNotString,
        };
    }
};

// ------------------------------------------------------------------- tests --

test "registry loads descriptors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try dir.createDirPath(io, "tools");
    try dir.writeFile(io, .{
        .sub_path = "tools/calculator.tool.json",
        .data =
        \\{
        \\  "name": "calculator",
        \\  "description": "arith",
        \\  "wasm": "calculator.wasm",
        \\  "input_schema": { "type": "object" },
        \\  "network_allow": ["api.example.com"]
        \\}
        ,
    });

    const reg = try Registry.load(io, arena, tmp.dir, "tools");
    const tool = reg.get("calculator").?;
    try std.testing.expectEqualStrings("calculator", tool.name);
    try std.testing.expectEqualStrings("calculator.wasm", tool.wasm);
    try std.testing.expectEqual(@as(usize, 1), tool.network_allow.len);
    try std.testing.expectEqualStrings("api.example.com", tool.network_allow[0]);
}

test "plugin toggles disable optional tools but never core ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try dir.createDirPath(io, "tools");
    try dir.writeFile(io, .{
        .sub_path = "tools/web_search.tool.json",
        .data =
        \\{ "name": "web_search", "description": "search", "wasm": "web_search.wasm", "input_schema": {} }
        ,
    });
    try dir.writeFile(io, .{
        .sub_path = "tools/cmd_help.tool.json",
        .data =
        \\{ "name": "cmd_help", "description": "help", "wasm": "cmd_help.wasm", "input_schema": {}, "internal": true }
        ,
    });
    try dir.createDirPath(io, "state");
    try dir.writeFile(io, .{
        .sub_path = plugins_state_path,
        .data = "{\"disabled\":[\"web_search\",\"cmd_help\"]}",
    });

    const reg = try Registry.load(io, arena, tmp.dir, "tools");
    try std.testing.expect(!reg.get("web_search").?.enabled);
    try std.testing.expect(reg.get("cmd_help").?.enabled); // core: toggle ignored

    // A disabled plugin leaves the catalog the model sees.
    const defs = try reg.toToolDefs(arena);
    try std.testing.expectEqual(@as(usize, 0), defs.len);
}
