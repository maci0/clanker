//! chain: pipeline runner — one model-visible call that fans out to N
//! real tool calls via `ck_tool`, with inline LLM `mutate` steps in between.
//! Each step's output feeds the next via {{prev}} / {{prev.field}} substitution.

const std = @import("std");
const lib = @import("lib.zig");

const Config = struct {
    chains_dir: []const u8 = "chains",
    max_steps: u32 = 16,
    max_tokens: u32 = 2048,
};

const Step = struct {
    tool: ?[]const u8 = null,
    args: std.json.Value = .{ .object = .empty },
    mutate: ?Mutate = null,
    stop_on_error: ?bool = null,
};

const Mutate = struct {
    instruction: []const u8,
    mode: []const u8 = "json",
};

const Input = struct {
    steps: ?[]const Step = null,
    chain: ?[]const u8 = null,
    vars: ?std.json.Value = null,
    list: ?bool = null,
    show: ?[]const u8 = null,
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    const chains_cfg = std.json.parseFromSliceLeaky(Config, alloc, lib.config(), .{ .ignore_unknown_fields = true }) catch Config{};
    // chains_dir is also available via harness config (agent.chains_dir) so
    // `chain` tracks `config.toml` like `workflows` does — not a stale descriptor copy.
    var chains_dir: []const u8 = chains_cfg.chains_dir;
    {
        const cfg_raw = lib.harnessConfig();
        if (cfg_raw.len > 4) {
            const cfg_val = std.json.parseFromSliceLeaky(std.json.Value, alloc, cfg_raw, .{ .ignore_unknown_fields = true }) catch null;
            if (cfg_val) |c| if (c == .object) {
                if (c.object.get("agent")) |ag| if (ag == .object) {
                    if (ag.object.get("chains_dir")) |cd| {
                        if (cd == .string) chains_dir = cd.string;
                    }
                };
            };
        }
    }
    if (chains_dir.len == 0) chains_dir = "chains";
    const cfg = chains_cfg;
    const parsed = std.json.parseFromSliceLeaky(Input, alloc, input, .{ .ignore_unknown_fields = true }) catch {
        return lib.fail(out, "expected {steps:[...], chain:\"name\", vars:{}, list:bool, show:\"name\"}");
    };
    if (parsed.list orelse false) return listChains(out, chains_dir);
    if (parsed.show) |name| return showChain(out, chains_dir, name);
    var steps_slice: []const Step = &.{};
    if (parsed.steps) |s| {
        steps_slice = s;
    } else if (parsed.chain) |name| {
        if (name.len == 0) return lib.fail(out, "chain name must not be empty");
        const p = try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ chains_dir, name });
        const raw = lib.fsRead(p) catch {
            const alt = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ chains_dir, name });
            const raw2 = lib.fsRead(alt) catch return lib.fail(out, "no chain named with that id");
            const v2 = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw2, .{}) catch return lib.fail(out, "chain file is not valid JSON");
            steps_slice = try parseStepsArray(alloc, v2);
            return executeSteps(out, alloc, cfg, steps_slice, parsed.vars, name);
        };
        const v = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{}) catch return lib.fail(out, "chain file is not valid JSON");
        steps_slice = try parseStepsArray(alloc, v);
        return executeSteps(out, alloc, cfg, steps_slice, parsed.vars, name);
    } else {
        return lib.fail(out, "provide steps:[...] or chain:\"name\" (or list:true / show:\"name\")");
    }
    return executeSteps(out, alloc, cfg, steps_slice, parsed.vars, null);
}

fn parseStepsArray(alloc: std.mem.Allocator, v: std.json.Value) ![]const Step {
    if (v == .array) {
        var buf: [256 * 1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var s = std.json.Stringify{ .writer = &w, .options = .{} };
        try s.write(v);
        const wrapped = try std.fmt.allocPrint(alloc, "{{\"steps\":{s}}}", .{buf[0..w.end]});
        const p = try std.json.parseFromSliceLeaky(struct { steps: []const Step }, alloc, wrapped, .{ .ignore_unknown_fields = true });
        return p.steps;
    }
    if (v == .object) {
        if (v.object.get("steps")) |_| {
            const p = try std.json.parseFromSliceLeaky(struct { steps: []const Step }, alloc, try stringifyAlloc(alloc, v), .{ .ignore_unknown_fields = true });
            return p.steps;
        }
    }
    return error.InvalidChainFile;
}

fn stringifyAlloc(alloc: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    var w_state: std.Io.Writer.Allocating = .init(alloc);
    var s = std.json.Stringify{ .writer = &w_state.writer, .options = .{} };
    try s.write(v);
    return w_state.written();
}

fn executeSteps(out: *lib.Out, alloc: std.mem.Allocator, cfg: Config, steps: []const Step, vars_val: ?std.json.Value, chain_name: ?[]const u8) !void {
    const max_steps = if (cfg.max_steps > 0) cfg.max_steps else @as(u32, 16);
    if (steps.len == 0) return lib.fail(out, "chain has no steps");
    if (steps.len > max_steps) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "chain has {d} steps but max_steps is {d}", .{ steps.len, max_steps }) catch "too many steps";
        return lib.fail(out, msg);
    }
    var prev_json: ?std.json.Value = null;
    var prev_raw: []const u8 = "";
    var trace: std.ArrayList(TraceEntry) = .empty;
    for (steps, 0..) |st, idx| {
        const is_tool = st.tool != null;
        const is_mutate = st.mutate != null;
        if (is_tool == is_mutate) {
            try trace.append(alloc, .{ .index = idx, .kind = "error", .ok = false, .output = "step must have exactly one of tool or mutate", .tool = st.tool orelse "" });
            if (st.stop_on_error orelse true) break else continue;
        }
        if (is_mutate) {
            const m = st.mutate.?;
            if (m.instruction.len == 0) {
                try trace.append(alloc, .{ .index = idx, .kind = "mutate", .ok = false, .output = "mutate instruction must not be empty", .tool = "" });
                if (st.stop_on_error orelse true) break else continue;
            }
            const prev_block = if (prev_raw.len > 0) prev_raw else if (prev_json) |v| try stringifyAlloc(alloc, v) else "(no prior output)";
            const prompt = try std.fmt.allocPrint(alloc, "{s}\n\nPrevious output:\n{s}", .{ m.instruction, prev_block });
            const answer = lib.llmWith(prompt, null, cfg.max_tokens) catch |err| {
                const msg = try std.fmt.allocPrint(alloc, "mutate llm failed: {s}", .{switch (err) {
                    error.SandboxDenied => "refused by sandbox policy",
                    error.NetworkError => "request did not complete",
                    error.TooLarge => "prompt too large",
                    else => "model did not respond",
                }});
                try trace.append(alloc, .{ .index = idx, .kind = "mutate", .ok = false, .output = msg, .tool = "" });
                if (st.stop_on_error orelse true) break else continue;
            };
            const cleaned = stripFences(std.mem.trim(u8, answer, " \t\r\n"));
            if (std.mem.eql(u8, m.mode, "json")) {
                const vv = std.json.parseFromSliceLeaky(std.json.Value, alloc, cleaned, .{}) catch {
                    const msg = try std.fmt.allocPrint(alloc, "mutate returned non-JSON: {s}", .{cleaned[0..@min(cleaned.len, 300)]});
                    try trace.append(alloc, .{ .index = idx, .kind = "mutate", .ok = false, .output = msg, .tool = "" });
                    if (st.stop_on_error orelse true) break else continue;
                };
                prev_json = vv;
                prev_raw = cleaned;
                try trace.append(alloc, .{ .index = idx, .kind = "mutate", .ok = true, .output = cleaned, .tool = "" });
            } else {
                prev_json = .{ .string = cleaned };
                prev_raw = cleaned;
                try trace.append(alloc, .{ .index = idx, .kind = "mutate", .ok = true, .output = cleaned, .tool = "" });
            }
            continue;
        }
        const tool_name = st.tool.?;
        if (tool_name.len == 0) {
            try trace.append(alloc, .{ .index = idx, .kind = "tool", .ok = false, .output = "tool name must not be empty", .tool = tool_name });
            if (st.stop_on_error orelse true) break else continue;
        }
        const args_json = try argsToJsonWithSubst(alloc, st.args, prev_json, prev_raw, vars_val);
        const result = lib.toolCall(tool_name, args_json) catch |err| {
            const why: []const u8 = switch (err) {
                error.SandboxDenied => "refused by this tool's sandbox policy",
                error.NotFound => "not found (no such tool, or tool_call is not granted)",
                error.TooLarge => "too large for one call",
                error.NetworkError => "the request did not complete",
                error.InvalidArg => "the arguments were rejected",
            };
            const msg = try std.fmt.allocPrint(alloc, "tool {s} failed: {s}", .{ tool_name, why });
            try trace.append(alloc, .{ .index = idx, .kind = "tool", .ok = false, .output = msg, .tool = tool_name });
            if (st.stop_on_error orelse true) break else continue;
        };
        prev_raw = result;
        prev_json = std.json.parseFromSliceLeaky(std.json.Value, alloc, result, .{}) catch .{ .string = result };
        try trace.append(alloc, .{ .index = idx, .kind = "tool", .ok = true, .output = result, .tool = tool_name });
    }
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    if (chain_name) |n| {
        try s.objectField("chain");
        try s.write(n);
    }
    try s.objectField("output");
    if (prev_json) |v| {
        if (v == .string) try s.write(v.string) else try s.write(v);
    } else {
        try s.write(prev_raw);
    }
    try s.objectField("steps");
    try s.write(@as(i64, @intCast(steps.len)));
    try s.objectField("trace");
    try s.beginArray();
    for (trace.items) |e| {
        try s.beginObject();
        try s.objectField("index");
        try s.write(@as(i64, @intCast(e.index)));
        try s.objectField("kind");
        try s.write(e.kind);
        if (e.tool.len > 0) {
            try s.objectField("tool");
            try s.write(e.tool);
        }
        try s.objectField("ok");
        try s.write(e.ok);
        try s.objectField("output");
        try s.write(e.output);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

const TraceEntry = struct {
    index: usize,
    kind: []const u8,
    tool: []const u8 = "",
    ok: bool,
    output: []const u8,
};

fn argsToJsonWithSubst(alloc: std.mem.Allocator, args: std.json.Value, prev_json: ?std.json.Value, prev_raw: []const u8, vars_val: ?std.json.Value) ![]const u8 {
    const raw = try stringifyAlloc(alloc, args);
    if (std.mem.find(u8, raw, "{{") == null) return raw;
    const substituted = try substituteInValue(alloc, args, prev_json, prev_raw, vars_val);
    return try stringifyAlloc(alloc, substituted);
}

fn substituteInValue(alloc: std.mem.Allocator, v: std.json.Value, prev_json: ?std.json.Value, prev_raw: []const u8, vars_val: ?std.json.Value) !std.json.Value {
    return switch (v) {
        .string => |s| blk: {
            if (std.mem.find(u8, s, "{{") == null) break :blk v;
            const out = try substituteString(alloc, s, prev_json, prev_raw, vars_val);
            break :blk .{ .string = out };
        },
        .object => |o| blk: {
            var m: std.json.ObjectMap = .empty;
            var it = o.iterator();
            while (it.next()) |kv| {
                const nv = try substituteInValue(alloc, kv.value_ptr.*, prev_json, prev_raw, vars_val);
                try m.put(alloc, kv.key_ptr.*, nv);
            }
            break :blk .{ .object = m };
        },
        .array => |a| blk: {
            var arr = std.json.Array.init(alloc);
            for (a.items) |item| {
                const nv = try substituteInValue(alloc, item, prev_json, prev_raw, vars_val);
                try arr.append(nv);
            }
            break :blk .{ .array = arr };
        },
        else => v,
    };
}

fn substituteString(alloc: std.mem.Allocator, s: []const u8, prev_json: ?std.json.Value, prev_raw: []const u8, vars_val: ?std.json.Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], "{{")) {
            const close = std.mem.find(u8, s[i..], "}}") orelse {
                try out.appendSlice(alloc, s[i..]);
                break;
            };
            const expr = std.mem.trim(u8, s[i + 2 .. i + close], " \t");
            const val = resolveExpr(alloc, expr, prev_json, prev_raw, vars_val) catch "";
            try out.appendSlice(alloc, val);
            i += close + 2;
        } else {
            try out.append(alloc, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

fn resolveExpr(alloc: std.mem.Allocator, expr: []const u8, prev_json: ?std.json.Value, prev_raw: []const u8, vars_val: ?std.json.Value) ![]const u8 {
    if (std.mem.eql(u8, expr, "prev")) {
        if (prev_raw.len > 0) return prev_raw;
        if (prev_json) |v| return try stringifyAlloc(alloc, v);
        return "";
    }
    if (std.mem.startsWith(u8, expr, "prev.")) {
        const path = expr["prev.".len..];
        if (prev_json) |v| {
            if (jsonPath(v, path)) |found| {
                if (found == .string) return found.string;
                return try stringifyAlloc(alloc, found);
            }
        }
        return "";
    }
    if (std.mem.startsWith(u8, expr, "vars.")) {
        const path = expr["vars.".len..];
        if (vars_val) |v| {
            if (jsonPath(v, path)) |found| {
                if (found == .string) return found.string;
                return try stringifyAlloc(alloc, found);
            }
        }
        return "";
    }
    return "";
}

fn jsonPath(root: std.json.Value, path: []const u8) ?std.json.Value {
    var cur = root;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (std.mem.findScalar(u8, seg, '[')) |br| {
            const key = seg[0..br];
            if (cur != .object) return null;
            cur = cur.object.get(key) orelse return null;
            var rest = seg[br..];
            while (rest.len > 0 and rest[0] == '[') {
                const close = std.mem.findScalar(u8, rest, ']') orelse return null;
                const idx = std.fmt.parseInt(usize, rest[1..close], 10) catch return null;
                if (cur != .array) return null;
                if (idx >= cur.array.items.len) return null;
                cur = cur.array.items[idx];
                rest = rest[close + 1 ..];
            }
        } else {
            if (cur == .object) {
                cur = cur.object.get(seg) orelse return null;
            } else if (cur == .array) {
                const idx = std.fmt.parseInt(usize, seg, 10) catch return null;
                if (idx >= cur.array.items.len) return null;
                cur = cur.array.items[idx];
            } else return null;
        }
    }
    return cur;
}

fn stripFences(s: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, s, "```")) return s;
    const first_nl = std.mem.findScalar(u8, s, '\n') orelse return s;
    const body = s[first_nl + 1 ..];
    const close = std.mem.lastIndexOf(u8, body, "```") orelse return body;
    return std.mem.trim(u8, body[0..close], " \t\r\n");
}

fn listChains(out: *lib.Out, chains_dir: []const u8) !void {
    const raw = lib.fsList(chains_dir) catch |err| {
        if (err == error.NotFound) {
            var w2 = lib.writer(out);
            var s2 = lib.json(&w2);
            try s2.beginObject();
            try s2.objectField("ok");
            try s2.write(true);
            try s2.objectField("chains");
            try s2.beginArray();
            try s2.endArray();
            try s2.endObject();
            lib.commit(out, &w2);
            return;
        }
        return lib.failErr(out, err, "listing chains");
    };
    const arr = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{}) catch
        return lib.fail(out, "could not parse chain listing");
    if (arr != .array) return lib.fail(out, "unexpected listing shape");
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("chains");
    try s.beginArray();
    for (arr.array.items) |item| {
        if (item != .string) continue;
        if (!std.mem.endsWith(u8, item.string, ".json")) continue;
        const name = item.string[0 .. item.string.len - 5];
        try s.write(name);
    }
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

fn showChain(out: *lib.Out, chains_dir: []const u8, name: []const u8) !void {
    if (name.len == 0) return lib.fail(out, "chain name must not be empty");
    if (std.mem.findScalar(u8, name, '/') != null or std.mem.find(u8, name, "..") != null)
        return lib.fail(out, "invalid chain name");
    const path = try std.fmt.allocPrint(lib.alloc, "{s}/{s}.json", .{ chains_dir, name });
    const raw = lib.fsRead(path) catch |err| {
        if (err == error.NotFound) {
            const alt = try std.fmt.allocPrint(lib.alloc, "{s}/{s}", .{ chains_dir, name });
            _ = lib.fsRead(alt) catch return lib.fail(out, "no chain named with that id");
            return lib.fail(out, "no chain named with that id");
        }
        return lib.failErr(out, err, "reading chain");
    };
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("name");
    try s.write(name);
    try s.objectField("chain");
    try s.write(raw);
    try s.endObject();
    lib.commit(out, &w);
}
