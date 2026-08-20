//! The plugin manifest schema: what a `*.tool.json` descriptor may say, and
//! what it means. `registry.zig` is the loader, deliberately forgiving, since
//! one bad manifest must not take the other ninety down with it, so a typo'd
//! key, a fuel budget above the ceiling, or a `tool_allow` with no `tool_call`
//! all load without complaint and simply do nothing. This module is the other
//! half: a pure validator that says so, with the file and the offending key.
//!
//! Everything here is derived from what the loader and the sandbox actually
//! honor, not from what a manifest could plausibly contain. When a key is
//! added to `registry.zig`'s `parseDescriptor`, it belongs in `known_keys`
//! here too, or `clanker plugins validate` starts calling it unknown.
//!
//! No I/O and no dependency beyond `std`: the CLI reads the bytes, this
//! decides what is wrong with them, and both the unit tests and
//! `runtime.zig`'s fuel ceiling read their constants from here.

const std = @import("std");
const json = std.json;

/// The manifest schema version this build understands. A descriptor with no
/// `manifest_version` key is v1: every manifest written before the key existed
/// is a valid v1 manifest, which is the whole reason the default is not an
/// error.
pub const current_version: i64 = 1;

/// The oldest schema version still loadable.
pub const min_version: i64 = 1;

/// The sandbox's per-call instruction budget when a descriptor names none.
/// `runtime.zig` reads this and clamps a descriptor's `fuel` to it, so a
/// manifest can tighten its own budget and never raise it; the validator
/// rejects a value above it rather than letting the clamp silently disagree
/// with what the file says.
pub const default_fuel: u64 = 10_000_000_000;

/// Every top-level key some part of the harness reads. Anything else is
/// ignored at load, so the validator reports it rather than letting a typo
/// pass for a policy.
///
/// `parameters` is OpenAI's spelling of `input_schema`, accepted by
/// `Registry.normalizedSchema` for compatibility. `category` is read by the
/// `tools` and `plugins` guests (for grouping and the web UI's tool
/// panel), not by the registry, it is honored, just not by the loader.
pub const known_keys = [_][]const u8{
    "manifest_version",
    "name",
    "description",
    // The compressed, model-facing description. Optional: `parseDescriptor`
    // falls back to `description` when a manifest omits it, so an unmigrated
    // manifest is valid, just more expensive per turn.
    "llm_description",
    // Binding usage rules, injected into the system prompt's "## Tool
    // guidance" section and echoed by `load_tools`. Optional.
    "prompt_guidance",
    "wasm",
    "input_schema",
    "parameters",
    "category",
    "network_allow",
    "network_from_config",
    "fs_prefixes",
    "exec_allow",
    "env_allow",
    "fuel",
    "internal",
    "enabled",
    "llm",
    "session",
    "live_publish",
    "sequential",
    "statusline",
    "turn_hook",
    "check",
    "confirm",
    "tool_call",
    "tool_allow",
    "config",
    "config_editable",
    "transform",
};

/// Keys whose value must be an array of non-empty strings. The loader drops a
/// non-string element silently, which turns a typo into a missing grant.
const string_array_keys = [_][]const u8{
    "network_allow",
    "fs_prefixes",
    "exec_allow",
    "env_allow",
    "config_editable",
    "tool_allow",
};

/// Keys whose value must be a boolean. The loader ignores any other type, so
/// `"internal": "true"` reads as `false`.
const bool_keys = [_][]const u8{
    "internal",
    "enabled",
    "llm",
    "session",
    "live_publish",
    "sequential",
    "statusline",
    "turn_hook",
    "check",
    "confirm",
    "tool_call",
};

/// Guest helpers in `tools/zig/lib.zig` that reach a model. A tool that calls
/// one must declare `llm` (or at least `sequential`) in its descriptor, or it
/// runs on the parallel worker pool and races the shared access-token cache.
///
/// The list lives here rather than beside the test that enforces it because
/// two places now consult it: `registry.zig`'s conformance test, and
/// `clanker plugins validate` when a manifest has a sibling source file.
/// A helper added to `lib.zig` without a line here silently re-opens the hole.
pub const model_call_markers = [_][]const u8{
    "lib.llm(",
    "lib.llmWith(",
    "lib.llmSystem(",
    "lib.llmMany(",
    "lib.subagent(",
    "lib.subagentBriefed(",
};

/// True when guest source text calls the model through any known helper.
pub fn sourceCallsModel(source: []const u8) bool {
    for (model_call_markers) |marker| {
        if (std.mem.find(u8, source, marker) != null) return true;
    }
    return false;
}

pub const Severity = enum {
    /// The manifest is wrong: the loader will refuse it, or accept it and do
    /// something other than what it says.
    err,
    /// The manifest loads, but a key does nothing, or the combination is not
    /// what the author meant.
    warn,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warn => "warning",
        };
    }
};

pub const Finding = struct {
    severity: Severity,
    /// The offending key, dotted for a nested one (`transform.phase`). Empty
    /// only for a whole-file problem: unparseable JSON, or a root that is not
    /// an object.
    key: []const u8,
    message: []const u8,
};

pub const Report = struct {
    /// Whatever the caller called the source: a path for `validate`, a label
    /// for a test. Reported verbatim so an error names a file a reader can open.
    file: []const u8,
    findings: []const Finding,

    pub fn errorCount(self: Report) usize {
        var n: usize = 0;
        for (self.findings) |f| {
            if (f.severity == .err) n += 1;
        }
        return n;
    }

    pub fn warningCount(self: Report) usize {
        return self.findings.len - self.errorCount();
    }

    /// No errors. Warnings do not make a manifest invalid; they make it
    /// suspicious.
    pub fn ok(self: Report) bool {
        return self.errorCount() == 0;
    }

    /// One line per finding: `path: error: key: message`. The file and the key
    /// come first because that is the pair a reader needs to open the right
    /// place, and a bare "invalid tool descriptor" is what this exists to
    /// replace.
    pub fn render(self: Report, arena: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        for (self.findings) |f| {
            if (f.key.len == 0) {
                try out.writer.print("{s}: {s}: {s}\n", .{ self.file, f.severity.label(), f.message });
            } else {
                try out.writer.print("{s}: {s}: {s}: {s}\n", .{ self.file, f.severity.label(), f.key, f.message });
            }
        }
        return out.written();
    }
};

const Validator = struct {
    arena: std.mem.Allocator,
    findings: std.ArrayList(Finding) = .empty,

    fn add(self: *Validator, severity: Severity, key: []const u8, message: []const u8) !void {
        try self.findings.append(self.arena, .{ .severity = severity, .key = key, .message = message });
    }

    fn addFmt(
        self: *Validator,
        severity: Severity,
        key: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.add(severity, key, try std.fmt.allocPrint(self.arena, fmt, args));
    }
};

/// Validate one manifest's raw bytes. `file` is only ever echoed back in the
/// report, so a caller with no path (a test, a piped document) may pass any
/// label. Never fails on a bad manifest, a malformed document is a finding,
/// not an error return; the error set is allocation only.
pub fn validate(arena: std.mem.Allocator, file: []const u8, raw: []const u8) !Report {
    var v = Validator{ .arena = arena };

    const parsed = json.parseFromSliceLeaky(json.Value, arena, raw, .{}) catch |err| {
        try v.addFmt(.err, "", "not valid JSON: {s}", .{@errorName(err)});
        return .{ .file = file, .findings = v.findings.items };
    };
    const obj = switch (parsed) {
        .object => |o| o,
        else => {
            try v.add(.err, "", "a manifest must be a JSON object");
            return .{ .file = file, .findings = v.findings.items };
        },
    };

    try checkVersion(&v, obj);
    try checkUnknownKeys(&v, obj);
    try checkIdentity(&v, obj);
    try checkSchema(&v, obj);
    try checkTypes(&v, obj);
    try checkPolicy(&v, obj);
    try checkTransform(&v, obj);
    try checkCoherence(&v, obj);

    return .{ .file = file, .findings = v.findings.items };
}

fn checkVersion(v: *Validator, obj: json.ObjectMap) !void {
    const raw = obj.get("manifest_version") orelse return; // absent means v1
    if (raw != .integer) {
        try v.add(.err, "manifest_version", "must be an integer");
        return;
    }
    if (raw.integer < min_version or raw.integer > current_version) {
        try v.addFmt(
            .err,
            "manifest_version",
            "unsupported version {d}; this build understands {d}..{d}",
            .{ raw.integer, min_version, current_version },
        );
    }
}

fn checkUnknownKeys(v: *Validator, obj: json.ObjectMap) !void {
    var it = obj.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const known = for (known_keys) |k| {
            if (std.mem.eql(u8, k, key)) break true;
        } else false;
        if (!known) {
            try v.add(.warn, key, "unknown key; the loader ignores it, so it grants and configures nothing");
        }
    }
}

fn checkIdentity(v: *Validator, obj: json.ObjectMap) !void {
    for ([_][]const u8{ "name", "description", "wasm" }) |key| {
        const val = obj.get(key) orelse {
            try v.add(.err, key, "required, and missing");
            continue;
        };
        if (val != .string) {
            try v.add(.err, key, "must be a string");
            continue;
        }
        if (val.string.len == 0) try v.add(.err, key, "must not be empty");
    }

    if (obj.get("name")) |n| {
        if (n == .string and n.string.len > 0 and !isToolName(n.string)) {
            try v.add(.err, "name", "lowercase letters, digits and underscores only: it is what the model types to call the tool");
        }
    }

    if (obj.get("wasm")) |w| {
        if (w == .string and w.string.len > 0) {
            const path = w.string;
            if (!std.mem.endsWith(u8, path, ".wasm"))
                try v.add(.err, "wasm", "must name a .wasm module");
            if (path[0] == '/')
                try v.add(.err, "wasm", "must be a relative path: an absolute one only resolves on the machine that wrote it");
            if (std.mem.find(u8, path, "..") != null)
                try v.add(.err, "wasm", "must not traverse upwards");
        }
    }
}

/// A tool name is what a model writes into a tool call, so it stays in the
/// character set every provider accepts without escaping.
fn isToolName(name: []const u8) bool {
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
    }
    return true;
}

fn checkSchema(v: *Validator, obj: json.ObjectMap) !void {
    const has_params = obj.get("parameters") != null;
    if (has_params) {
        if (obj.get("input_schema") != null) {
            try v.add(.warn, "parameters", "ignored: input_schema is present and wins");
        } else {
            try v.add(.warn, "parameters", "OpenAI's spelling; accepted, but input_schema is this format's name for it");
        }
    }

    const raw = obj.get("input_schema") orelse obj.get("parameters") orelse {
        try v.add(.warn, "input_schema", "absent: the model is told this tool takes no arguments");
        return;
    };
    if (raw != .object) {
        try v.add(.err, "input_schema", "must be a JSON Schema object; a non-object schema is dropped and the tool loses its arguments");
        return;
    }
    if (raw.object.get("type")) |t| {
        if (t != .string or !std.mem.eql(u8, t.string, "object")) {
            try v.add(.err, "input_schema.type", "must be \"object\": a tool's arguments are always an object");
        }
    }
    if (raw.object.get("properties")) |p| {
        if (p != .object) try v.add(.err, "input_schema.properties", "must be an object");
    }
    if (raw.object.get("required")) |r| {
        if (r != .array) {
            try v.add(.err, "input_schema.required", "must be an array of property names");
        } else for (r.array.items) |item| {
            if (item != .string) try v.add(.err, "input_schema.required", "every entry must be a property name");
        }
    }
}

fn checkTypes(v: *Validator, obj: json.ObjectMap) !void {
    for (bool_keys) |key| {
        const val = obj.get(key) orelse continue;
        if (val != .bool) try v.addFmt(.err, key, "must be true or false; any other value reads as the default", .{});
    }
    for (string_array_keys) |key| {
        const val = obj.get(key) orelse continue;
        if (val != .array) {
            try v.add(.err, key, "must be an array of strings");
            continue;
        }
        for (val.array.items) |item| {
            if (item != .string) {
                try v.add(.err, key, "every entry must be a string; a non-string one is dropped silently");
            } else if (item.string.len == 0) {
                try v.add(.err, key, "an empty entry grants nothing and hides a typo");
            }
        }
    }
    if (obj.get("config")) |c| {
        if (c != .object) try v.add(.err, "config", "must be an object: it is handed to the guest verbatim through ck_config");
    }
    if (obj.get("category")) |c| {
        if (c != .string) {
            try v.add(.err, "category", "must be a string");
        } else if (c.string.len > 0 and !isKnownCategory(c.string)) {
            try v.addFmt(
                .warn,
                "category",
                "\"{s}\" is not a known group (agent, chat, code, compute, harness, kanban, knowledge, media, transform, web, other); the Tools view still accepts it, but a typo will sit in its own section",
                .{c.string},
            );
        } else if (c.string.len > 0) {
            if (obj.get("name")) |n| {
                if (n == .string) {
                    if (expectedCategory(n.string)) |want| {
                        if (!std.mem.eql(u8, c.string, want)) {
                            try v.addFmt(
                                .warn,
                                "category",
                                "\"{s}\" is the group for names starting {s}; this tool is in \"{s}\"",
                                .{ want, prefixOf(n.string), c.string },
                            );
                        }
                    }
                }
            }
        }
    }
}

/// The Tools view and `clanker tools` group by these names. Empty renders as
/// `other`. An unknown string is a warning, not a refusal: out-of-tree tools
/// may invent a group, and a typo should be named rather than silently
/// creating a one-tool section nobody meant.
pub const categories = [_][]const u8{
    "agent",
    "chat",
    "code",
    "compute",
    "harness",
    "kanban",
    "knowledge",
    "media",
    "other",
    "transform",
    "web",
};

/// Prefix families live in one group so a `chat_*` typo cannot open a new
/// section. Exact names like `kanban` (the multiplexed guest) have no prefix.
fn expectedCategory(name: []const u8) ?[]const u8 {
    const pairs = [_]struct { prefix: []const u8, cat: []const u8 }{
        .{ .prefix = "chat_", .cat = "chat" },
        .{ .prefix = "kanban_", .cat = "kanban" },
        .{ .prefix = "todo_", .cat = "agent" },
        .{ .prefix = "goal_", .cat = "agent" },
        .{ .prefix = "skill_", .cat = "agent" },
        .{ .prefix = "note_", .cat = "knowledge" },
        .{ .prefix = "session_", .cat = "harness" },
        .{ .prefix = "zig_", .cat = "code" },
        .{ .prefix = "web_", .cat = "web" },
    };
    for (pairs) |p| {
        if (std.mem.startsWith(u8, name, p.prefix)) return p.cat;
    }
    return null;
}

fn prefixOf(name: []const u8) []const u8 {
    if (std.mem.findScalar(u8, name, '_')) |i| return name[0 .. i + 1];
    return name;
}

pub fn isKnownCategory(name: []const u8) bool {
    for (categories) |c| {
        if (std.mem.eql(u8, c, name)) return true;
    }
    return false;
}

fn checkPolicy(v: *Validator, obj: json.ObjectMap) !void {
    if (obj.get("fuel")) |f| {
        if (f != .integer) {
            try v.add(.err, "fuel", "must be a positive integer; anything else silently keeps the sandbox default");
        } else if (f.integer <= 0) {
            try v.add(.err, "fuel", "must be positive; 0 means \"unset\" and a negative budget is not a budget");
        } else if (@as(u64, @intCast(f.integer)) > default_fuel) {
            try v.addFmt(
                .err,
                "fuel",
                "{d} is above the sandbox ceiling of {d}; a manifest can only tighten its own budget, and the runtime clamps this down anyway",
                .{ f.integer, default_fuel },
            );
        }
    }

    if (obj.get("network_from_config")) |n| {
        if (n != .string) {
            try v.add(.err, "network_from_config", "must be a string");
        } else if (!std.mem.eql(u8, n.string, "peers") and !std.mem.eql(u8, n.string, "providers")) {
            try v.addFmt(.err, "network_from_config", "must be \"peers\" or \"providers\", not \"{s}\"", .{n.string});
        }
    }

    if (arrayOf(obj, "network_allow")) |hosts| {
        for (hosts) |item| {
            if (item != .string) continue;
            const host = item.string;
            if (std.mem.find(u8, host, "://") != null or std.mem.findScalar(u8, host, '/') != null) {
                try v.addFmt(.err, "network_allow", "\"{s}\" is a URL; entries are hostnames or globs, with no scheme or path", .{host});
            } else if (std.mem.findScalar(u8, host, ':') != null) {
                try v.addFmt(.err, "network_allow", "\"{s}\" carries a port; the allowlist matches hostnames only", .{host});
            }
        }
    }

    if (arrayOf(obj, "fs_prefixes")) |prefixes| {
        for (prefixes) |item| {
            if (item != .string) continue;
            if (item.string.len == 0) {
                // Silently skipping it left the author with a grant list that
                // validated clean and an entry naming nothing. Write "." to
                // ask for the whole root, or drop the entry.
                try v.add(.err, "fs_prefixes", "an empty prefix names nothing and grants nothing; write \".\" for the whole sandbox root or remove the entry");
                continue;
            }
            const p = item.string;
            if (p[0] == '/') {
                try v.addFmt(.err, "fs_prefixes", "\"{s}\" is absolute; prefixes are relative to the sandbox root", .{p});
            }
            if (std.mem.find(u8, p, "..") != null) {
                try v.addFmt(.err, "fs_prefixes", "\"{s}\" traverses out of the sandbox root", .{p});
            }
        }
    }

    if (arrayOf(obj, "exec_allow")) |cmds| {
        for (cmds) |item| {
            if (item != .string or item.string.len == 0) continue;
            const cmd = item.string;
            if (std.mem.eql(u8, cmd, "*")) {
                try v.addFmt(.err, "exec_allow", "\"{s}\" grants nothing: the gate compares argv[0] exactly, so a glob never matches a command", .{cmd});
                continue;
            }
            if (std.mem.findScalar(u8, cmd, '/') != null or std.mem.findScalar(u8, cmd, ' ') != null) {
                try v.addFmt(.err, "exec_allow", "\"{s}\" must be a bare command name: the gate compares argv[0] exactly, so a path or an argument never matches", .{cmd});
            }
        }
    }
}

fn checkTransform(v: *Validator, obj: json.ObjectMap) !void {
    const raw = obj.get("transform") orelse return;
    if (raw != .object) {
        try v.add(.err, "transform", "must be an object");
        return;
    }
    const t = raw.object;
    const phase = t.get("phase") orelse {
        try v.add(.err, "transform.phase", "required: a transform runs \"before\" or \"after\" the tool it wraps");
        return;
    };
    if (phase != .string or (!std.mem.eql(u8, phase.string, "before") and !std.mem.eql(u8, phase.string, "after"))) {
        try v.add(.err, "transform.phase", "must be \"before\" or \"after\"");
    }
    if (t.get("tools")) |tools| {
        if (tools != .array) {
            try v.add(.err, "transform.tools", "must be an array of tool names, or [\"*\"] for all");
        } else for (tools.array.items) |item| {
            if (item != .string) try v.add(.err, "transform.tools", "every entry must be a tool name");
        }
    }
    if (t.get("order")) |o| {
        if (o != .integer) try v.add(.err, "transform.order", "must be an integer; lower runs first");
    }
}

/// Combinations that each parse but contradict each other. These are the
/// findings a schema check alone cannot make: nothing here is a type error,
/// and every one of them is a key doing nothing.
fn checkCoherence(v: *Validator, obj: json.ObjectMap) !void {
    if (obj.get("tool_allow") != null and !boolAt(obj, "tool_call")) {
        try v.add(.warn, "tool_allow", "ignored without \"tool_call\": true; ck_tool is denied outright");
    }

    for ([_][]const u8{ "statusline", "turn_hook" }) |key| {
        if (boolAt(obj, key) and !boolAt(obj, "internal")) {
            try v.addFmt(.warn, key, "pair with \"internal\": true, or the model sees a tool it is meant to never call", .{});
        }
    }

    if (arrayOf(obj, "config_editable")) |keys| {
        const cfg = obj.get("config");
        for (keys) |item| {
            if (item != .string) continue;
            const present = cfg != null and cfg.? == .object and cfg.?.object.get(item.string) != null;
            if (!present) {
                try v.addFmt(.warn, "config_editable", "\"{s}\" is not a key in config, so there is nothing for an override to replace", .{item.string});
            }
        }
    }

    // A transform is hidden from the model like an internal tool, but it is
    // the one internal thing `/plugins` can switch off, so the pairing is a
    // convention rather than a requirement, a transform without it is still
    // offered to the model as a callable tool, which is not what a wrapper is.
    if (obj.get("transform") != null and !boolAt(obj, "internal")) {
        try v.add(.warn, "transform", "a transform wraps other tools rather than being called; pair it with \"internal\": true");
    }
}

fn boolAt(obj: json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return v == .bool and v.bool;
}

fn arrayOf(obj: json.ObjectMap, key: []const u8) ?[]const json.Value {
    const v = obj.get(key) orelse return null;
    if (v != .array) return null;
    return v.array.items;
}

// ---------------------------------------------------------------- scaffold --

/// A starting manifest for a new tool: valid, minimal, and deliberately
/// granting nothing. An author widens `fs_prefixes` / `network_allow` /
/// `exec_allow` on purpose rather than inheriting a template's guesses.
///
/// `portable` selects the out-of-tree shape: `{name}.wasm` beside the
/// manifest. The in-tree default points at `zig-out/tools/{name}.wasm`.
///
/// The placeholder text deliberately avoids the words `clanker gate`'s lint
/// forbids in a `.zig` file, since the guest below is one: a scaffolder whose
/// output fails the gate on the first run is a scaffolder that has to be
/// hand-edited before it can be built.
pub fn scaffoldManifest(arena: std.mem.Allocator, name: []const u8, portable: bool) ![]const u8 {
    if (!isToolName(name) or name.len == 0) return error.BadToolName;
    const wasm = if (portable)
        try std.fmt.allocPrint(arena, "{s}.wasm", .{name})
    else
        try std.fmt.allocPrint(arena, "zig-out/tools/{s}.wasm", .{name});
    return std.fmt.allocPrint(arena,
        \\{{
        \\  "manifest_version": {d},
        \\  "name": "{s}",
        \\  "description": "REPLACE ME: one sentence the model reads to decide whether to call this tool, then the exact input and output shapes.",
        \\  "wasm": "{s}",
        \\  "input_schema": {{
        \\    "type": "object",
        \\    "properties": {{
        \\      "text": {{
        \\        "type": "string",
        \\        "description": "REPLACE ME: what this argument is."
        \\      }}
        \\    }},
        \\    "required": ["text"]
        \\  }},
        \\  "network_allow": [],
        \\  "fs_prefixes": [],
        \\  "category": "other"
        \\}}
        \\
    , .{ current_version, name, wasm });
}

/// A guest source file that compiles under `zig build tools` and answers the
/// scaffolded schema. It echoes, because a stub that does nothing cannot be
/// told apart from a stub that is wired up wrong.
pub fn scaffoldGuest(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (!isToolName(name) or name.len == 0) return error.BadToolName;
    return std.fmt.allocPrint(arena,
        \\//! {s}: REPLACE ME, describe what this tool does.
        \\//! Input:  {{"text": "..."}}
        \\//! Output: {{"ok": true, "text": "..."}}
        \\
        \\const std = @import("std");
        \\const lib = @import("lib.zig");
        \\
        \\export fn run(ptr: u32, len: u32) callconv(.c) u64 {{
        \\    return lib.run(ptr, len, tool_main);
        \\}}
        \\
        \\fn tool_main(input: []const u8, out: *lib.Out) !void {{
        \\    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{{}});
        \\    var text: []const u8 = "";
        \\    if (parsed == .object) {{
        \\        if (parsed.object.get("text")) |v| {{
        \\            if (v == .string) text = v.string;
        \\        }}
        \\    }}
        \\    if (text.len == 0) return lib.fail(out, "expected {{\"text\": \"...\"}}");
        \\
        \\    const reply = try std.fmt.allocPrint(lib.alloc, "{s}: {{s}}", .{{text}});
        \\    return lib.okText(out, reply);
        \\}}
        \\
    , .{ name, name });
}

// ------------------------------------------------------------------- tests --

const testing = std.testing;

fn reportFor(arena: std.mem.Allocator, raw: []const u8) !Report {
    return validate(arena, "test.tool.json", raw);
}

fn hasFinding(rep: Report, severity: Severity, key: []const u8) bool {
    for (rep.findings) |f| {
        if (f.severity == severity and std.mem.eql(u8, f.key, key)) return true;
    }
    return false;
}

test "a minimal manifest is valid, and so is one with no manifest_version" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Exactly what every manifest written before the key existed looks like.
    const v1_implicit = try reportFor(arena,
        \\{ "name": "calc", "description": "d", "wasm": "zig-out/tools/calc.wasm",
        \\  "input_schema": { "type": "object" } }
    );
    try testing.expectEqual(@as(usize, 0), v1_implicit.findings.len);
    try testing.expect(v1_implicit.ok());

    const v1_explicit = try reportFor(arena,
        \\{ "manifest_version": 1, "name": "calc", "description": "d",
        \\  "wasm": "zig-out/tools/calc.wasm", "input_schema": { "type": "object" } }
    );
    try testing.expectEqual(@as(usize, 0), v1_explicit.findings.len);
}

test "a future manifest_version is refused rather than half-understood" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rep = try reportFor(arena,
        \\{ "manifest_version": 2, "name": "calc", "description": "d", "wasm": "c.wasm" }
    );
    try testing.expect(!rep.ok());
    try testing.expect(hasFinding(rep, .err, "manifest_version"));
    // The message names the version the build does understand, so the reader
    // knows whether to upgrade clanker or the manifest.
    const text = try rep.render(arena);
    try testing.expect(std.mem.find(u8, text, "unsupported version 2") != null);
    try testing.expect(std.mem.find(u8, text, "test.tool.json") != null);
}

test "missing required fields are reported by name, all of them at once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // One pass reports every problem: a validator that stops at the first is
    // a validator you have to run four times.
    const rep = try reportFor(arena, "{}");
    try testing.expect(hasFinding(rep, .err, "name"));
    try testing.expect(hasFinding(rep, .err, "description"));
    try testing.expect(hasFinding(rep, .err, "wasm"));
    try testing.expect(hasFinding(rep, .warn, "input_schema"));
}

test "malformed JSON and a non-object root are findings, never a hard failure" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bad = try reportFor(arena, "{ \"name\": ");
    try testing.expect(!bad.ok());
    try testing.expectEqualStrings("", bad.findings[0].key);

    const arr = try reportFor(arena, "[]");
    try testing.expect(!arr.ok());
    try testing.expect(std.mem.find(u8, arr.findings[0].message, "JSON object") != null);
}

test "a fuel budget above the sandbox ceiling is an error, below it is fine" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tight = try reportFor(arena,
        \\{ "name": "calc", "description": "d", "wasm": "c.wasm",
        \\  "input_schema": {"type":"object"}, "fuel": 100000000 }
    );
    try testing.expect(tight.ok());

    const greedy = try reportFor(arena,
        \\{ "name": "calc", "description": "d", "wasm": "c.wasm",
        \\  "input_schema": {"type":"object"}, "fuel": 99000000000 }
    );
    try testing.expect(hasFinding(greedy, .err, "fuel"));

    // 0 is the loader's "unset", so writing it is a mistake worth naming
    // rather than a way to ask for the default.
    const zero = try reportFor(arena,
        \\{ "name": "calc", "description": "d", "wasm": "c.wasm",
        \\  "input_schema": {"type":"object"}, "fuel": 0 }
    );
    try testing.expect(hasFinding(zero, .err, "fuel"));

    const typo = try reportFor(arena,
        \\{ "name": "calc", "description": "d", "wasm": "c.wasm",
        \\  "input_schema": {"type":"object"}, "fuel": "lots" }
    );
    try testing.expect(hasFinding(typo, .err, "fuel"));
}

test "sandbox grants are checked for shape, not just type" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rep = try reportFor(arena,
        \\{ "name": "bad", "description": "d", "wasm": "b.wasm", "input_schema": {"type":"object"},
        \\  "network_allow": ["https://api.example.com/v1", "api.example.com:443"],
        \\  "fs_prefixes": ["/etc", "../secrets"],
        \\  "exec_allow": ["/usr/bin/git", "git push"] }
    );
    try testing.expectEqual(@as(usize, 0), rep.warningCount());
    // Two per key: URL + port, absolute + traversal, path + argument.
    try testing.expectEqual(@as(usize, 6), rep.errorCount());

    const good = try reportFor(arena,
        \\{ "name": "good", "description": "d", "wasm": "g.wasm", "input_schema": {"type":"object"},
        \\  "network_allow": ["api.example.com", "*.github.com"],
        \\  "fs_prefixes": ["state/mine/", "."],
        \\  "exec_allow": ["git", "zig"] }
    );
    try testing.expectEqual(@as(usize, 0), good.findings.len);
}

test "category is a known group or a named warning" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(isKnownCategory("chat"));
    try testing.expect(isKnownCategory("other"));
    try testing.expect(!isKnownCategory("chatt"));
    try testing.expect(!isKnownCategory(""));

    const known = try reportFor(arena,
        \\{ "name": "calc", "description": "d", "wasm": "c.wasm",
        \\  "input_schema": {"type":"object"}, "category": "chat" }
    );
    try testing.expect(known.ok());
    try testing.expectEqual(@as(usize, 0), known.findings.len);

    const typo = try reportFor(arena,
        \\{ "name": "calc", "description": "d", "wasm": "c.wasm",
        \\  "input_schema": {"type":"object"}, "category": "chatt" }
    );
    try testing.expect(typo.ok());
    try testing.expect(hasFinding(typo, .warn, "category"));

    const empty = try reportFor(arena,
        \\{ "name": "calc", "description": "d", "wasm": "c.wasm",
        \\  "input_schema": {"type":"object"}, "category": "" }
    );
    try testing.expect(empty.ok());
    try testing.expectEqual(@as(usize, 0), empty.findings.len);

    try testing.expectEqualStrings("chat", expectedCategory("chat_dm").?);
    try testing.expectEqualStrings("code", expectedCategory("zig_std").?);
    try testing.expectEqualStrings("agent", expectedCategory("goal_write").?);
    try testing.expectEqualStrings("knowledge", expectedCategory("note_write").?);
    try testing.expectEqualStrings("web", expectedCategory("web_fetch").?);
    try testing.expect(expectedCategory("kanban") == null);
    try testing.expect(expectedCategory("webui_addon") == null);

    const prefix = try reportFor(arena,
        \\{ "name": "chat_dm", "description": "d", "wasm": "c.wasm",
        \\  "input_schema": {"type":"object"}, "category": "code" }
    );
    try testing.expect(prefix.ok());
    try testing.expect(hasFinding(prefix, .warn, "category"));

    const prefix_ok = try reportFor(arena,
        \\{ "name": "chat_dm", "description": "d", "wasm": "c.wasm",
        \\  "input_schema": {"type":"object"}, "category": "chat" }
    );
    try testing.expect(prefix_ok.ok());
    try testing.expectEqual(@as(usize, 0), prefix_ok.findings.len);
}

test "a key that does nothing is a warning that says why" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every one of these loads without complaint today and quietly does
    // nothing, which is the class of bug this validator exists for.
    const rep = try reportFor(arena,
        \\{ "name": "sloppy", "description": "d", "wasm": "s.wasm", "input_schema": {"type":"object"},
        \\  "fs_prefix": ["state"],
        \\  "tool_allow": ["calculator"],
        \\  "statusline": true,
        \\  "config": { "a": 1 },
        \\  "config_editable": ["b"] }
    );
    try testing.expect(rep.ok()); // all of it loads
    try testing.expect(hasFinding(rep, .warn, "fs_prefix")); // typo for fs_prefixes
    try testing.expect(hasFinding(rep, .warn, "tool_allow")); // no tool_call
    try testing.expect(hasFinding(rep, .warn, "statusline")); // not internal
    try testing.expect(hasFinding(rep, .warn, "config_editable")); // key absent from config
}

test "prompt_guidance is a known key the validator accepts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rep = try reportFor(arena,
        \\{ "name": "rfc", "description": "d", "wasm": "r.wasm", "input_schema": {"type":"object"},
        \\  "prompt_guidance": "open the cited source, never the note" }
    );
    try testing.expect(rep.ok());
    try testing.expect(!hasFinding(rep, .warn, "prompt_guidance"));
}

test "the schema is checked against what a provider will accept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Anthropic rejects the whole request over one bad schema, so a wrong
    // "type" is an error and not a note.
    const wrong_type = try reportFor(arena,
        \\{ "name": "t", "description": "d", "wasm": "t.wasm", "input_schema": { "type": "string" } }
    );
    try testing.expect(hasFinding(wrong_type, .err, "input_schema.type"));

    const not_object = try reportFor(arena,
        \\{ "name": "t", "description": "d", "wasm": "t.wasm", "input_schema": "object" }
    );
    try testing.expect(hasFinding(not_object, .err, "input_schema"));

    // OpenAI's spelling loads (the registry normalizes it) but is worth saying.
    const openai = try reportFor(arena,
        \\{ "name": "t", "description": "d", "wasm": "t.wasm",
        \\  "parameters": { "type": "object", "properties": { "path": { "type": "string" } } } }
    );
    try testing.expect(openai.ok());
    try testing.expect(hasFinding(openai, .warn, "parameters"));
}

test "a transform declares a phase the chain runner understands" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rep = try reportFor(arena,
        \\{ "name": "t", "description": "d", "wasm": "t.wasm", "input_schema": {"type":"object"},
        \\  "internal": true, "transform": { "phase": "during", "order": "first" } }
    );
    try testing.expect(hasFinding(rep, .err, "transform.phase"));
    try testing.expect(hasFinding(rep, .err, "transform.order"));

    const good = try reportFor(arena,
        \\{ "name": "t", "description": "d", "wasm": "t.wasm", "input_schema": {"type":"object"},
        \\  "internal": true, "transform": { "phase": "after", "tools": ["*"], "order": 50 } }
    );
    try testing.expectEqual(@as(usize, 0), good.findings.len);
}

test "the scaffolded manifest and guest are what the validator asks for" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const manifest = try scaffoldManifest(arena, "my_tool", false);
    const rep = try validate(arena, "my_tool.tool.json", manifest);
    try testing.expectEqual(@as(usize, 0), rep.findings.len);

    const portable = try scaffoldManifest(arena, "my_tool", true);
    const portable_rep = try validate(arena, "my_tool.tool.json", portable);
    try testing.expectEqual(@as(usize, 0), portable_rep.findings.len);
    try testing.expect(std.mem.find(u8, portable, "\"wasm\": \"my_tool.wasm\"") != null);

    // The generated pair has to agree on the name, or `zig build tools`
    // produces a wasm the manifest does not point at.
    const guest = try scaffoldGuest(arena, "my_tool");
    try testing.expect(std.mem.find(u8, manifest, "zig-out/tools/my_tool.wasm") != null);
    try testing.expect(std.mem.find(u8, guest, "lib.run(ptr, len, tool_main)") != null);
    try testing.expect(std.mem.find(u8, guest, "@import(\"lib.zig\")") != null);

    // The guest is written into tools/zig/, which `clanker gate`'s lint scans.
    // A placeholder spelled with one of its forbidden markers would make the
    // gate fail on a file the scaffolder itself just wrote.
    const forbidden = [_][]const u8{ "TO" ++ "DO", "FIX" ++ "ME", "HA" ++ "CK", "XX" ++ "X" };
    for (forbidden) |marker| {
        try testing.expect(std.mem.find(u8, guest, marker) == null);
    }

    try testing.expectError(error.BadToolName, scaffoldManifest(arena, "My-Tool", false));
    try testing.expectError(error.BadToolName, scaffoldGuest(arena, ""));
}

test "sourceCallsModel spots every helper the descriptor gate cares about" {
    try testing.expect(sourceCallsModel("const x = try lib.llmSystem(alloc, sys, prompt);"));
    try testing.expect(sourceCallsModel("lib.subagentBriefed("));
    try testing.expect(!sourceCallsModel("// lib.llmish( is not a helper\nconst y = 1;"));
}

test "exec_allow glob is rejected as a no-op grant" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rep = try reportFor(arena,
        \\{ "name": "stars", "description": "d", "wasm": "s.wasm", "input_schema": {"type":"object"},
        \\  "exec_allow": ["*"] }
    );
    try testing.expect(!rep.ok());
    try testing.expect(hasFinding(rep, .err, "exec_allow"));
}
