//! Eval task model and scoring. Evals are the verification harness the
//! self-improvement engine gates on, including "selfhost" evals that build
//! and test clanker itself.

const std = @import("std");
const json = std.json;
const strField = @import("../util/json.zig").strField;

pub const Criterion = union(enum) {
    /// The response must contain all listed substrings.
    includes: []const []const u8,
    /// The response must parse as JSON and contain the given key with a
    /// matching string value.
    json_key: struct { key: []const u8, value: []const u8 },
    /// The response, with surrounding whitespace trimmed, must be exactly
    /// this. `includes` is a substring test, so a criterion of "1" is also
    /// satisfied by "10" and "21": for a short answer that is usually not what
    /// the case meant to assert.
    equals: []const u8,
    /// None of these may appear. Catches an answer that says the right thing
    /// and the wrong thing at once, which a substring test scores as a pass.
    excludes: []const []const u8,
};

pub const Kind = enum {
    /// Run a prompt through the agent and score the answer.
    task,
    /// `zig build` must succeed in the project.
    selfhost_build,
    /// `zig build test` must pass in the project.
    selfhost_tests,
    /// `zig build tools` must succeed.
    selfhost_tools,
};

pub const Eval = struct {
    name: []const u8,
    kind: Kind = .task,
    /// Prompt for `.task` evals.
    prompt: []const u8 = "",
    /// Criteria for `.task` evals.
    criteria: []const Criterion = &.{},
    /// Expected tool-call names the agent should invoke (in order of use).
    requires_tool: ?[]const u8 = null,

    pub fn loadAll(arena: std.mem.Allocator, io: std.Io, evals_dir: []const u8) ![]Eval {
        var out: std.ArrayList(Eval) = .empty;
        var dir = std.Io.Dir.cwd().openDir(io, evals_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return &.{},
            else => return err,
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".task.json")) continue;
            const raw = dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20)) catch continue;
            const eval = parse(arena, raw) catch continue;
            try out.append(arena, eval);
        }
        return out.toOwnedSlice(arena);
    }

    pub fn parse(arena: std.mem.Allocator, raw: []const u8) !Eval {
        const v = try json.parseFromSliceLeaky(json.Value, arena, raw, .{ .ignore_unknown_fields = true });
        const obj = switch (v) {
            .object => |o| o,
            else => return error.EvalNotObject,
        };
        var e = Eval{ .name = try strField(obj, "name") };
        if (obj.get("kind")) |k| {
            const ks = try strVal(k);
            e.kind = if (std.mem.eql(u8, ks, "task")) .task else if (std.mem.eql(u8, ks, "selfhost_build")) .selfhost_build else if (std.mem.eql(u8, ks, "selfhost_tests")) .selfhost_tests else if (std.mem.eql(u8, ks, "selfhost_tools")) .selfhost_tools else return error.UnknownEvalKind;
        }
        if (obj.get("prompt")) |p| e.prompt = try strVal(p);
        if (obj.get("requires_tool")) |p| e.requires_tool = try strVal(p);
        if (obj.get("criteria")) |c| {
            switch (c) {
                .array => |arr| {
                    var list: std.ArrayList(Criterion) = .empty;
                    for (arr.items) |item| {
                        const co = switch (item) {
                            .object => |o| o,
                            else => continue,
                        };
                        if (co.get("includes")) |inc| {
                            switch (inc) {
                                .array => |ia| {
                                    var subs: std.ArrayList([]const u8) = .empty;
                                    for (ia.items) |s| switch (s) {
                                        .string => |ss| try subs.append(arena, ss),
                                        else => {},
                                    };
                                    try list.append(arena, .{ .includes = try subs.toOwnedSlice(arena) });
                                },
                                else => {},
                            }
                        } else if (co.get("excludes")) |exc| {
                            switch (exc) {
                                .array => |ia| {
                                    var subs: std.ArrayList([]const u8) = .empty;
                                    for (ia.items) |s| switch (s) {
                                        .string => |ss| try subs.append(arena, ss),
                                        else => {},
                                    };
                                    try list.append(arena, .{ .excludes = try subs.toOwnedSlice(arena) });
                                },
                                else => {},
                            }
                        } else if (co.get("equals")) |eq| {
                            switch (eq) {
                                .string => |es| try list.append(arena, .{ .equals = es }),
                                else => {},
                            }
                        } else if (co.get("json_key")) |jk| {
                            const jo = switch (jk) {
                                .object => |o| o,
                                else => continue,
                            };
                            try list.append(arena, .{ .json_key = .{ .key = try strField(jo, "key"), .value = try strField(jo, "value") } });
                        }
                    }
                    e.criteria = try list.toOwnedSlice(arena);
                },
                else => {},
            }
        }
        return e;
    }

    fn strVal(v: json.Value) ![]const u8 {
        return switch (v) {
            .string => |s| s,
            else => error.FieldNotString,
        };
    }
};

// ----------------------------------------------------------------- scorers --

/// Scores a completed task answer against the eval's criteria. 1.0 = pass.
pub fn scoreAnswer(answer: []const u8, criteria: []const Criterion) f64 {
    if (criteria.len == 0) return if (answer.len > 0) 1.0 else 0.0;
    var satisfied: usize = 0;
    for (criteria) |c| {
        if (criterionSatisfied(answer, c)) satisfied += 1;
    }
    return @as(f64, @floatFromInt(satisfied)) / @as(f64, @floatFromInt(criteria.len));
}

fn criterionSatisfied(answer: []const u8, c: Criterion) bool {
    return switch (c) {
        .includes => |subs| blk: {
            for (subs) |s| {
                if (std.mem.find(u8, answer, s) == null) break :blk false;
            }
            break :blk true;
        },
        .equals => |want| std.mem.eql(u8, std.mem.trim(u8, answer, " \t\r\n"), want),
        .excludes => |subs| blk: {
            for (subs) |sub| {
                if (std.mem.find(u8, answer, sub) != null) break :blk false;
            }
            break :blk true;
        },
        .json_key => |jk| blk: {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const v = json.parseFromSliceLeaky(json.Value, arena.allocator(), answer, .{}) catch break :blk false;
            switch (v) {
                .object => |o| {
                    if (o.get(jk.key)) |val| {
                        switch (val) {
                            .string => |s| break :blk std.mem.eql(u8, s, jk.value),
                            .bool => |b| break :blk std.mem.eql(u8, if (b) "true" else "false", jk.value),
                            .integer => |i| {
                                var num_buf: [32]u8 = undefined;
                                const num = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch break :blk false;
                                break :blk std.mem.eql(u8, num, jk.value);
                            },
                            else => break :blk false,
                        }
                    }
                    break :blk false;
                },
                else => break :blk false,
            }
        },
    };
}

// ------------------------------------------------------------------- tests --

test "scorers" {
    const criteria = [_]Criterion{
        .{ .includes = &.{"true"} },
        .{ .json_key = .{ .key = "ok", .value = "true" } },
    };
    try std.testing.expectEqual(@as(f64, 1.0), scoreAnswer("{\"ok\": true}", &criteria));
    try std.testing.expectEqual(@as(f64, 0.5), scoreAnswer("true", &criteria));
    try std.testing.expectEqual(@as(f64, 0.0), scoreAnswer("nope", &criteria));
}

test "eval parse" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const e = try Eval.parse(arena,
        \\{"name":"math","kind":"task","prompt":"what is 2+2?","criteria":[{"includes":["4"]}]}
    );
    try std.testing.expectEqualStrings("math", e.name);
    try std.testing.expectEqual(Kind.task, e.kind);
    try std.testing.expectEqual(@as(usize, 1), e.criteria.len);
}

test "equals is exact where includes is a substring" {
    // The case that motivated this: a criterion of "1" asserting a count of
    // one is also satisfied by 10 and 21, so a wrong answer scored a pass.
    try std.testing.expect(criterionSatisfied("10", .{ .includes = &.{"1"} }));
    try std.testing.expect(!criterionSatisfied("10", .{ .equals = "1" }));
    try std.testing.expect(criterionSatisfied("1", .{ .equals = "1" }));

    // Models pad an answer with a newline; that is not a different answer.
    try std.testing.expect(criterionSatisfied("  391\n", .{ .equals = "391" }));
    try std.testing.expect(!criterionSatisfied("391 files", .{ .equals = "391" }));
}

test "excludes rejects an answer that says both things" {
    // A substring test passes an answer that contains the right word
    // somewhere, even alongside its opposite.
    const hedged = "YES, though on reflection NO";
    try std.testing.expect(criterionSatisfied(hedged, .{ .includes = &.{"YES"} }));
    try std.testing.expect(!criterionSatisfied(hedged, .{ .excludes = &.{"NO"} }));
    try std.testing.expect(criterionSatisfied("YES", .{ .excludes = &.{"NO"} }));
}

test "every shipped eval definition parses and is complete" {
    // loadAll drops a file it cannot parse (`catch continue`): a malformed
    // eval silently stops being run and nothing goes red. This is the loud
    // version, run from the repo root it parses every shipped definition
    // and asserts a task eval actually asserts something.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(io, "evals", .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(io);

    var count: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".task.json")) continue;
        const raw = try dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20));
        const e = Eval.parse(arena, raw) catch |err| {
            std.debug.print("eval {s}: {s}\n", .{ entry.name, @errorName(err) });
            return err;
        };
        if (e.kind == .task) {
            // A task with no prompt runs the agent on nothing; a task with no
            // criteria passes on any non-empty answer. Neither is a case
            // anyone wrote on purpose.
            if (e.prompt.len == 0) {
                std.debug.print("eval {s}: task without a prompt\n", .{entry.name});
                return error.TaskEvalMissingPrompt;
            }
            if (e.criteria.len == 0) {
                std.debug.print("eval {s}: task without criteria\n", .{entry.name});
                return error.TaskEvalMissingCriteria;
            }
        }
        count += 1;
    }
    try std.testing.expect(count > 0);
}

test "every eval requires_tool names a shipped tool" {
    // requires_tool is matched against transcript tool-call names at score
    // time, so a tool rename strands the eval at a permanent score of 0;
    // which the improve loop reads as its own regression. Cross-check the
    // name against the manifests the registry actually loads.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var man_dir = std.Io.Dir.cwd().openDir(io, "tools/manifests", .{ .iterate = true }) catch return error.SkipZigTest;
    defer man_dir.close(io);

    var tool_names: std.StringHashMapUnmanaged(void) = .empty;
    var man_it = man_dir.iterate();
    while (man_it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".tool.json")) continue;
        const raw = try man_dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20));
        const v = json.parseFromSliceLeaky(json.Value, arena, raw, .{ .ignore_unknown_fields = true }) catch continue;
        if (v != .object) continue;
        const name = v.object.get("name") orelse continue;
        if (name != .string) continue;
        try tool_names.put(arena, name.string, {});
    }

    var dir = std.Io.Dir.cwd().openDir(io, "evals", .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".task.json")) continue;
        const raw = try dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20));
        const e = Eval.parse(arena, raw) catch continue;
        const want = e.requires_tool orelse continue;
        if (tool_names.get(want) == null) {
            std.debug.print("eval {s} requires tool '{s}' but no shipped manifest declares it\n", .{ entry.name, want });
            return error.EvalRequiresUnknownTool;
        }
    }
}

test "equals and excludes are read from a descriptor" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        \\{"name":"c","kind":"task","prompt":"p","criteria":[{"equals":"391"},{"excludes":["error","NO"]}]}
    ;
    const e = try Eval.parse(arena, text);
    try std.testing.expectEqual(@as(usize, 2), e.criteria.len);
    try std.testing.expect(criterionSatisfied("391", e.criteria[0]));
    try std.testing.expect(!criterionSatisfied("391 and an error", e.criteria[1]));
}
