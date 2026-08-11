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
    /// Instruction budget (wasm fuel) for one call of this tool. 0 means the
    /// sandbox default; a positive value is clamped to that default as a
    /// ceiling in runtime.zig, so a descriptor can tighten its own budget
    /// but never raise it.
    fuel: u64 = 0,
    /// If true, the tool is loaded and runnable but hidden from the LLM catalog.
    internal: bool = false,
    /// Machine-local on/off switch from `state/plugins.json`. Disabled tools
    /// stay loadable (the REPL still lists them) but are withheld from the LLM
    /// catalog and refused at execution.
    enabled: bool = true,
    /// May call the model through `ck_llm`. Costs tokens, so it is opt-in per
    /// descriptor and forces the tool onto the sequential execution path.
    llm: bool = false,
    /// Never runs on the parallel worker pool (host-shared state, e.g. the
    /// chatroom log): each tool call waits its turn on the main thread.
    sequential: bool = false,
    /// Contributes a segment to the REPL status line. Pair with
    /// `"internal": true` so the model never calls it.
    statusline: bool = false,
    /// Runs once after each REPL turn (empty input) and may print a line
    /// into the transcript — a general REPL-behavior plugin, as opposed to
    /// `statusline`'s fixed one-line segment. Pair with `"internal": true`
    /// so the model never calls it.
    turn_hook: bool = false,
    /// Free-form per-plugin settings from the descriptor's `config` object,
    /// handed to the guest verbatim via `ck_config`. The harness only reads the
    /// `provider` / `model` / `max_tokens` keys, to aim `ck_llm` at a specific
    /// backend; everything else is the plugin's own business.
    config: json.Value = .{ .object = .{} },
    /// `config`, pre-serialized once at registry load. `config` never changes
    /// after `Registry.load` returns (see `applyConfigOverrides`), so
    /// re-serializing it on every `sandboxFor` call — previously once per
    /// tool invocation, transform run, and worker spawn — redid the same
    /// work every time instead of once.
    config_json: []const u8 = "{}",
    /// Which `config` keys may be changed at runtime, from the descriptor's
    /// `config_editable` array. Empty means the plugin exposes no settings:
    /// the rest of `config` is the tool's own structure, not a control panel.
    config_editable: []const []const u8 = &.{},
    /// Set when this tool rewrites another tool's input or output.
    transform: ?Transform = null,
    /// This tool answers pass/fail about something (a gate, an eval, a lint).
    /// Its verdict is recorded in the run graph as a check, because a run that
    /// turned on one reads as unmotivated without it.
    check: bool = false,
    /// `"peers"` or `"providers"`: the harness adds those configured hosts to
    /// `network_allow` at load, because a descriptor cannot know them.
    network_from_config: []const u8 = "",
    /// Commands this tool may run through `ck_exec`. Empty means the harness
    /// default set; a non-empty list replaces it, so a tool that needs one
    /// binary does not also get git and zig.
    exec_allow: []const []const u8 = &.{},
    /// Environment variables this tool may read. Empty means the safe defaults
    /// in host.zig, never the whole process environment: that is where the API
    /// keys are.
    env_allow: []const []const u8 = &.{},
    /// Ask the human before running this tool, when a confirm channel is
    /// installed (agent.confirm_writes). Unset, the answer is derived from
    /// what the descriptor grants: anything with exec or filesystem access —
    /// fs_prefixes carry write access, there is no read-only grant — is a
    /// write in a viewer's eyes. Read-only tools opt out with
    /// `"confirm": false` so reads keep running free; a tool whose risk its
    /// grants understate (delegation, say) opts in with `"confirm": true`.
    confirm: ?bool = null,

    /// Core tools (the `cmd_*` slash commands, the web UI, the formatter) back
    /// the harness itself and stay on. A transform is hidden from the model
    /// like an internal tool, but switching it off is the whole point of it.
    pub fn toggleable(self: Tool) bool {
        return !self.internal or self.transform != null;
    }

    /// Whether a human channel, when one is installed, must approve a call
    /// to this tool before it runs (see the `confirm` field for the default).
    pub fn needsConfirm(self: *const Tool) bool {
        return self.confirm orelse (self.exec_allow.len > 0 or self.fs_prefixes.len > 0);
    }

    /// True when `key` is one the descriptor opted in to runtime editing.
    pub fn configKeyEditable(self: *const Tool, key: []const u8) bool {
        for (self.config_editable) |k| {
            if (std.mem.eql(u8, k, key)) return true;
        }
        return false;
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

/// Machine-local overrides of per-plugin settings:
/// `{"rlm": {"max_depth": 5}}`. Layered over the descriptor's `config` at load
/// so the committed manifest keeps holding the project default and a local
/// change stays local, the same split `plugins.json` makes for on/off.
pub const plugin_config_state_path = "state/plugin_config.json";

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
            const tool = parseDescriptor(arena, raw) catch |err| {
                log.log(.warn, "invalid tool descriptor '{s}': {s}", .{ entry.name, @errorName(err) });
                continue;
            };
            try reg.tools.put(arena, tool.name, tool);
        }
        reg.applyToggles(io, arena, base);
        reg.applyConfigOverrides(io, arena, base);
        var vals = reg.tools.iterator();
        while (vals.next()) |entry| {
            entry.value_ptr.config_json = try std.fmt.allocPrint(arena, "{f}", .{json.fmt(entry.value_ptr.config, .{})});
        }
        return reg;
    }

    /// Layers `state/plugin_config.json` over each descriptor's `config`.
    ///
    /// Only keys the descriptor lists in `config_editable` are applied. A
    /// plugin's config is otherwise free-form and some of it is structural,
    /// not tunable: the four chat_* descriptors share one wasm binary and
    /// select their behaviour with `"op"`, so letting an override reach that
    /// key would turn chat_send into chat_rooms. Editability is opt-in per
    /// key, declared by the tool that knows which of its settings are safe.
    fn applyConfigOverrides(self: *Registry, io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir) void {
        const raw = base.readFileAlloc(io, plugin_config_state_path, arena, .limited(256 * 1024)) catch return;
        const parsed = json.parseFromSliceLeaky(json.Value, arena, raw, .{ .ignore_unknown_fields = true }) catch {
            log.log(.warn, "invalid {s}; leaving every plugin at its descriptor config", .{plugin_config_state_path});
            return;
        };
        if (parsed != .object) return;

        var it = parsed.object.iterator();
        while (it.next()) |entry| {
            const t = self.tools.getPtr(entry.key_ptr.*) orelse continue;
            const overrides = switch (entry.value_ptr.*) {
                .object => |o| o,
                else => continue,
            };
            if (t.config != .object) continue;
            var merged = t.config.object.clone(arena) catch continue;
            var ov = overrides.iterator();
            while (ov.next()) |o| {
                if (!t.configKeyEditable(o.key_ptr.*)) continue;
                merged.put(arena, o.key_ptr.*, o.value_ptr.*) catch continue;
            }
            t.config = .{ .object = merged };
        }
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

    /// Returns all enabled tools that have `statusline: true`. These are
    /// invoked with empty input after each turn to contribute segments to
    /// the REPL status bar. The caller owns the returned slice via `arena`.
    pub fn statuslineTools(self: *const Registry, arena: std.mem.Allocator) ![]const *const Tool {
        var out: std.ArrayList(*const Tool) = .empty;
        var it = self.tools.iterator();
        while (it.next()) |kv| {
            const t = kv.value_ptr;
            if (t.statusline and t.enabled) try out.append(arena, t);
        }
        std.mem.sort(*const Tool, out.items, {}, toolNameLt);
        return out.toOwnedSlice(arena);
    }

    /// Returns all enabled tools that have `turn_hook: true`. Same cadence
    /// as `statuslineTools` (invoked with empty input once after each turn),
    /// but the caller treats a non-empty result as a line to print into the
    /// transcript rather than a status-bar segment — for plugins that react
    /// to what just happened instead of only decorating the status line.
    pub fn turnHookTools(self: *const Registry, arena: std.mem.Allocator) ![]const *const Tool {
        var out: std.ArrayList(*const Tool) = .empty;
        var it = self.tools.iterator();
        while (it.next()) |kv| {
            const t = kv.value_ptr;
            if (t.turn_hook and t.enabled) try out.append(arena, t);
        }
        std.mem.sort(*const Tool, out.items, {}, toolNameLt);
        return out.toOwnedSlice(arena);
    }

    fn toolNameLt(_: void, a: *const Tool, b: *const Tool) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }

    /// Converts registry tools into LLM ToolDefs (in the given arena).
    /// Name of the tool that hands out schemas on demand. Defined here
    /// because both the registry (which advertises it) and the agent (which
    /// answers it) have to agree on the spelling.
    pub const load_tool_name = "load_tools";

    /// The schema the model needs to ask for other schemas.
    pub fn loadToolDef(arena: std.mem.Allocator) !types.ToolDef {
        var names_schema: json.ObjectMap = .empty;
        try names_schema.put(arena, "type", .{ .string = "array" });
        var item: json.ObjectMap = .empty;
        try item.put(arena, "type", .{ .string = "string" });
        try names_schema.put(arena, "items", .{ .object = item });

        var props: json.ObjectMap = .empty;
        try props.put(arena, "names", .{ .object = names_schema });

        var required = json.Array.init(arena);
        try required.append(.{ .string = "names" });

        var schema: json.ObjectMap = .empty;
        try schema.put(arena, "type", .{ .string = "object" });
        try schema.put(arena, "properties", .{ .object = props });
        try schema.put(arena, "required", .{ .array = required });

        return .{
            .name = load_tool_name,
            .description = "Load the full input schemas for tools listed in the tool catalog, so they can be called. " ++
                "Pass the exact names from the catalog. The tools stay available for the rest of this run.",
            .input_schema = .{ .object = schema },
        };
    }

    /// One line per tool: what exists, and enough of what it does to decide
    /// whether to ask for its schema. This is what the system prompt carries
    /// instead of every schema, which for this repo is the difference between
    /// roughly 6,600 tokens and roughly 1,000 in every single request.
    pub fn catalogText(self: *const Registry, arena: std.mem.Allocator, revealed: *const std.StringArrayHashMapUnmanaged(void)) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        // Not "names": Registry.names is a method on this same type, and a
        // local of that name shadows it and does not compile.
        var listed: std.ArrayList([]const u8) = .empty;
        var it = self.tools.iterator();
        while (it.next()) |kv| {
            const t = kv.value_ptr.*;
            if (t.internal or !t.enabled) continue;
            try listed.append(arena, t.name);
        }
        std.mem.sort([]const u8, listed.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        for (listed.items) |name| {
            const t = self.get(name).?;
            // A tool whose schema is already loaded is marked, so the model
            // does not spend a call asking for what it can already call.
            const mark: []const u8 = if (revealed.contains(name)) "* " else "  ";
            try out.writer.print("{s}{s}: {s}\n", .{ mark, name, firstLine(t.description) });
        }
        return out.written();
    }

    fn firstLine(s: []const u8) []const u8 {
        const line = s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
        // Long enough to choose by, short enough that forty of them stay cheap.
        return if (line.len > 160) line[0..160] else line;
    }

    test firstLine {
        try std.testing.expectEqualStrings("one", firstLine("one\ntwo"));
        try std.testing.expectEqualStrings("short", firstLine("short"));
        try std.testing.expectEqual(@as(usize, 160), firstLine("x" ** 400).len);
    }

    /// The tool definitions to send with a request: the always-available core,
    /// everything revealed so far, and `load_tools` itself. The rest of the
    /// registry is reachable through the catalog, not through this list.
    pub fn lazyToolDefs(
        self: *const Registry,
        arena: std.mem.Allocator,
        core: []const []const u8,
        revealed: *const std.StringArrayHashMapUnmanaged(void),
    ) ![]types.ToolDef {
        var out: std.ArrayList(types.ToolDef) = .empty;
        try out.append(arena, try loadToolDef(arena));
        var it = self.tools.iterator();
        while (it.next()) |kv| {
            const t = kv.value_ptr.*;
            if (t.internal or !t.enabled) continue;
            const in_core = for (core) |c| {
                if (std.mem.eql(u8, c, t.name)) break true;
            } else false;
            if (!in_core and !revealed.contains(t.name)) continue;
            try out.append(arena, .{
                .name = t.name,
                .description = t.description,
                .input_schema = t.input_schema,
                .internal = t.internal,
            });
        }
        return out.toOwnedSlice(arena);
    }

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

    /// A tool's JSON Schema, with the shape providers insist on filled in.
    ///
    /// Anthropic rejects a request whose tool list contains a schema with no
    /// "type" — and it rejects the *entire* request, so one manifest written
    /// with OpenAI's "parameters" key, or with the type omitted, silently
    /// breaks every tool call for every tool. Accept both spellings here and
    /// default the type rather than shipping a request no provider will take.
    fn normalizedSchema(arena: std.mem.Allocator, obj: json.ObjectMap) !json.Value {
        const raw = obj.get("input_schema") orelse obj.get("parameters") orelse json.Value{ .object = .empty };
        const src = switch (raw) {
            .object => |o| o,
            // A non-object schema is not something a provider can use.
            else => return json.Value{ .object = .empty },
        };
        if (src.get("type") != null) return raw;

        var out: json.ObjectMap = .empty;
        var it = src.iterator();
        while (it.next()) |kv| try out.put(arena, kv.key_ptr.*, kv.value_ptr.*);
        try out.put(arena, "type", json.Value{ .string = "object" });
        return json.Value{ .object = out };
    }

    fn parseDescriptor(arena: std.mem.Allocator, raw: []const u8) !Tool {
        const v = try json.parseFromSliceLeaky(json.Value, arena, raw, .{ .ignore_unknown_fields = true });
        const obj = switch (v) {
            .object => |o| o,
            else => return error.DescriptorNotObject,
        };
        var t = Tool{
            .name = try strField(obj, "name"),
            .description = try strField(obj, "description"),
            .wasm = try strField(obj, "wasm"),
            // A schema without a "type" is rejected by the provider, and it
            // rejects the *whole* request: one malformed manifest takes every
            // tool call down with it. Normalize here instead — an object
            // schema is what every tool in this registry has.
            .input_schema = normalizedSchema(arena, obj) catch .{ .object = .empty },
        };
        if (obj.get("check")) |c| {
            if (c == .bool) t.check = c.bool;
        }
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
        if (obj.get("fuel")) |fv| {
            // Anything but a positive integer keeps the default: a fuel of 0
            // or a typo'd string must not turn into an unrunnable tool.
            if (fv == .integer and fv.integer > 0) t.fuel = @intCast(fv.integer);
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
        if (obj.get("network_from_config")) |nv| {
            if (nv == .string) t.network_from_config = nv.string;
        }
        if (obj.get("exec_allow")) |ev| {
            switch (ev) {
                .array => |arr| t.exec_allow = try strArray(arena, arr),
                else => {},
            }
        }
        if (obj.get("env_allow")) |ev| {
            switch (ev) {
                .array => |arr| t.env_allow = try strArray(arena, arr),
                else => {},
            }
        }
        if (obj.get("llm")) |lv| {
            switch (lv) {
                .bool => |b| t.llm = b,
                else => {},
            }
        }
        if (obj.get("confirm")) |cv| {
            switch (cv) {
                .bool => |b| t.confirm = b,
                else => {},
            }
        }
        if (obj.get("sequential")) |sv| {
            switch (sv) {
                .bool => |b| t.sequential = b,
                else => {},
            }
        }
        if (obj.get("statusline")) |sv| {
            switch (sv) {
                .bool => |b| t.statusline = b,
                else => {},
            }
        }
        if (obj.get("turn_hook")) |sv| {
            switch (sv) {
                .bool => |b| t.turn_hook = b,
                else => {},
            }
        }
        if (obj.get("config_editable")) |ev| {
            if (ev == .array) {
                var keys: std.ArrayList([]const u8) = .empty;
                for (ev.array.items) |k| {
                    if (k == .string) keys.append(arena, k.string) catch continue;
                }
                t.config_editable = keys.items;
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
    try std.testing.expectEqual(@as(u64, 0), tool.fuel); // unset: sandbox default
}

test "a descriptor's fuel budget is parsed, and junk values keep the default" {
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
        .sub_path = "tools/thrifty.tool.json",
        .data =
        \\{ "name": "thrifty", "description": "d", "wasm": "t.wasm", "input_schema": {}, "fuel": 250000000 }
        ,
    });
    try dir.writeFile(io, .{
        .sub_path = "tools/sloppy.tool.json",
        .data =
        \\{ "name": "sloppy", "description": "d", "wasm": "s.wasm", "input_schema": {}, "fuel": "lots" }
        ,
    });

    const reg = try Registry.load(io, arena, tmp.dir, "tools");
    try std.testing.expectEqual(@as(u64, 250_000_000), reg.get("thrifty").?.fuel);
    try std.testing.expectEqual(@as(u64, 0), reg.get("sloppy").?.fuel);
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

test "config overrides apply only to keys the descriptor opted in" {
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
    // `max_depth` is offered for tuning; `secret` is not.
    try dir.writeFile(io, .{
        .sub_path = "tools/rlm.tool.json",
        .data =
        \\{ "name": "rlm", "description": "r", "wasm": "rlm.wasm", "input_schema": {},
        \\  "config": { "max_depth": 3, "secret": "keep" }, "config_editable": ["max_depth"] }
        ,
    });
    // Shares a binary with its siblings and selects behaviour with "op",
    // which is exactly why it opts nothing in.
    try dir.writeFile(io, .{
        .sub_path = "tools/chat_send.tool.json",
        .data =
        \\{ "name": "chat_send", "description": "c", "wasm": "chat.wasm", "input_schema": {},
        \\  "config": { "op": "send" } }
        ,
    });
    try dir.createDirPath(io, "state");
    try dir.writeFile(io, .{
        .sub_path = plugin_config_state_path,
        .data =
        \\{ "rlm": { "max_depth": 6, "secret": "stolen" }, "chat_send": { "op": "rooms" } }
        ,
    });

    const reg = try Registry.load(io, arena, tmp.dir, "tools");

    const rlm = reg.get("rlm").?;
    try std.testing.expectEqual(@as(i64, 6), rlm.config.object.get("max_depth").?.integer);
    // Not listed, so the descriptor value stands.
    try std.testing.expectEqualStrings("keep", rlm.config.object.get("secret").?.string);

    // No config_editable at all: the dispatch key is untouchable, so
    // chat_send cannot be turned into chat_rooms from state/.
    const chat = reg.get("chat_send").?;
    try std.testing.expectEqualStrings("send", chat.config.object.get("op").?.string);

    // config_json is precomputed once at load, after overrides apply: it must
    // reflect the overridden value, not the raw descriptor.
    try std.testing.expect(std.mem.indexOf(u8, rlm.config_json, "\"max_depth\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, rlm.config_json, "\"secret\":\"keep\"") != null);
}

test "a descriptor schema always reaches the provider with a type" {
    // Anthropic rejects the whole request — every tool, not just the bad one —
    // when any tool's input_schema has no "type". A manifest written with
    // OpenAI's "parameters" key, or with the type left out, used to do exactly
    // that and broke every run until the file was found by hand.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const openai_style =
        \\{ "name": "read_file", "description": "read", "wasm": "read_file.wasm",
        \\  "parameters": { "properties": { "path": { "type": "string" } }, "required": ["path"] } }
    ;
    const t = try Registry.parseDescriptor(arena, openai_style);
    try std.testing.expectEqualStrings("object", t.input_schema.object.get("type").?.string);
    // The rest of the schema survives the normalization.
    try std.testing.expect(t.input_schema.object.get("properties") != null);
    try std.testing.expectEqualStrings("path", t.input_schema.object.get("required").?.array.items[0].string);

    // A descriptor with no schema at all still yields something sendable.
    const bare =
        \\{ "name": "noargs", "description": "d", "wasm": "n.wasm" }
    ;
    const b = try Registry.parseDescriptor(arena, bare);
    try std.testing.expect(b.input_schema == .object);
}

test "every shipped manifest carries a schema the provider accepts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(io, "tools/manifests", .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".tool.json")) continue;
        const raw = try dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20));
        const t = Registry.parseDescriptor(arena, raw) catch |err| {
            std.debug.print("manifest {s}: {s}\n", .{ entry.name, @errorName(err) });
            return err;
        };
        if (t.input_schema != .object or t.input_schema.object.get("type") == null) {
            std.debug.print("manifest {s} has no usable input_schema type\n", .{entry.name});
            return error.SchemaMissingType;
        }
    }
}

test "a tool that calls the model says so in its descriptor" {
    // The descriptor is what keeps a model-calling tool off the parallel
    // worker threads. subagent, rlm and translate all called the model with
    // nothing declared, so two of them in one turn ran side by side and raced
    // the shared access-token cache: one thread freeing a token the other had
    // just been handed. Reading the guests is the only way to catch the next
    // one, since nothing else connects a source file to its manifest.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var src_dir = std.Io.Dir.cwd().openDir(io, "tools/zig", .{ .iterate = true }) catch return error.SkipZigTest;
    defer src_dir.close(io);
    var man_dir = std.Io.Dir.cwd().openDir(io, "tools/manifests", .{}) catch return error.SkipZigTest;
    defer man_dir.close(io);

    const calls = [_][]const u8{ "lib.llm(", "lib.llmWith(", "lib.subagent(", "lib.subagentBriefed(" };

    var it = src_dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const body = src_dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20)) catch continue;

        var calls_model = false;
        for (calls) |c| {
            if (std.mem.indexOf(u8, body, c) != null) calls_model = true;
        }
        if (!calls_model) continue;

        const stem = entry.name[0 .. entry.name.len - ".zig".len];
        const manifest = try std.fmt.allocPrint(arena, "{s}.tool.json", .{stem});
        const raw = man_dir.readFileAlloc(io, manifest, arena, .limited(1 << 20)) catch continue;
        const t = try Registry.parseDescriptor(arena, raw);
        if (!t.llm and !t.sequential) {
            std.debug.print("{s} calls the model but its descriptor sets neither llm nor sequential\n", .{manifest});
            return error.ModelCallerNotDeclared;
        }
    }
}

test "confirm derives from exec/fs grants and the descriptor overrides it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // No grants: nothing a viewer would call a write, so no confirm.
    const inert = try Registry.parseDescriptor(arena,
        \\{ "name": "calc", "description": "d", "wasm": "c.wasm" }
    );
    try std.testing.expect(!inert.needsConfirm());

    // An exec grant is a write in a viewer's eyes.
    const execs = try Registry.parseDescriptor(arena,
        \\{ "name": "git", "description": "d", "wasm": "g.wasm", "exec_allow": ["git"] }
    );
    try std.testing.expect(execs.needsConfirm());

    // So is any fs prefix: prefixes carry write access, never read-only.
    const writes = try Registry.parseDescriptor(arena,
        \\{ "name": "edit", "description": "d", "wasm": "e.wasm", "fs_prefixes": ["src"] }
    );
    try std.testing.expect(writes.needsConfirm());

    // A read-only tool opts out despite its grants, and an explicit opt-in
    // wins despite having none.
    const reader = try Registry.parseDescriptor(arena,
        \\{ "name": "read", "description": "d", "wasm": "r.wasm", "fs_prefixes": ["."], "confirm": false }
    );
    try std.testing.expect(!reader.needsConfirm());
    const delegator = try Registry.parseDescriptor(arena,
        \\{ "name": "sub", "description": "d", "wasm": "s.wasm", "confirm": true }
    );
    try std.testing.expect(delegator.needsConfirm());
}

test "descriptor statusline flag parses and defaults off" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw =
        \\{ "name": "sl", "description": "d", "wasm": "sl.wasm", "input_schema": {}, "statusline": true, "internal": true }
    ;
    const t = try Registry.parseDescriptor(arena, raw);
    try std.testing.expect(t.statusline);
    try std.testing.expect(t.internal);

    // A descriptor without the flag defaults to off, and the tool stays a
    // normal LLM-visible tool.
    const bare =
        \\{ "name": "plain", "description": "d", "wasm": "p.wasm" }
    ;
    const b = try Registry.parseDescriptor(arena, bare);
    try std.testing.expect(!b.statusline);
    try std.testing.expect(!b.internal);
}

test "descriptor turn_hook flag parses and defaults off" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw =
        \\{ "name": "th", "description": "d", "wasm": "th.wasm", "input_schema": {}, "turn_hook": true, "internal": true }
    ;
    const t = try Registry.parseDescriptor(arena, raw);
    try std.testing.expect(t.turn_hook);

    const bare =
        \\{ "name": "plain2", "description": "d", "wasm": "p.wasm" }
    ;
    const b = try Registry.parseDescriptor(arena, bare);
    try std.testing.expect(!b.turn_hook);
}

test "turnHookTools returns only enabled turn_hook tools, sorted by name" {
    var reg = Registry{};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try reg.tools.put(arena, "z_hook", .{ .name = "z_hook", .description = "d", .wasm = "z.wasm", .input_schema = .{ .object = .{} }, .turn_hook = true, .internal = true });
    try reg.tools.put(arena, "a_hook", .{ .name = "a_hook", .description = "d", .wasm = "a.wasm", .input_schema = .{ .object = .{} }, .turn_hook = true, .internal = true });
    try reg.tools.put(arena, "disabled_hook", .{ .name = "disabled_hook", .description = "d", .wasm = "d.wasm", .input_schema = .{ .object = .{} }, .turn_hook = true, .internal = true, .enabled = false });
    try reg.tools.put(arena, "not_a_hook", .{ .name = "not_a_hook", .description = "d", .wasm = "n.wasm", .input_schema = .{ .object = .{} } });

    const hooks = try reg.turnHookTools(arena);
    try std.testing.expectEqual(@as(usize, 2), hooks.len);
    try std.testing.expectEqualStrings("a_hook", hooks[0].name);
    try std.testing.expectEqualStrings("z_hook", hooks[1].name);
}
