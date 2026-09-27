//! Unwrapping one store guest's `{"ok":...}` answer.
//!
//! `cli.zig` owns the registry, the sandbox and the config, so a command
//! module that talks to a guest is handed a call in rather than reaching back
//! into the sandbox. Five record stores and the schedule command each carried
//! their own copy of that seam type and of the "call it, parse the JSON, insist
//! it is an object, insist it says ok" policy, and the copies drifted: only the
//! record copy reported a guest that failed to *run* as a broken build, while
//! `schedule` let the raw error escape to `main.zig`, which prints a bare
//! error name with no hint of which guest was asked.
//!
//! The policy is the same everywhere, so it is one function here. Only the
//! refusal wording differs, and that is the caller's to choose, so a refusal
//! comes back as data rather than an error.

const std = @import("std");
const log = @import("log.zig");
const json_util = @import("json.zig");

/// How a command module reaches its WASM tool. `cli.zig` owns the registry,
/// the sandbox and the config needed to load a tool, so it passes the call in
/// rather than these modules reaching back into it. Tests pass a canned answer
/// through the same seam.
pub const Tool = struct {
    ctx: *anyopaque,
    /// Takes the tool's JSON input, returns its JSON output. The result is
    /// owned by the caller's arena.
    call: *const fn (ctx: *anyopaque, input: []const u8) anyerror![]const u8,
};

/// What a guest answered. `refused` carries the message the guest wrote in its
/// `error` field, or a stand-in when it left that field out.
pub const Reply = union(enum) {
    ok: std.json.ObjectMap,
    refused: []const u8,
};

/// The message a guest that answered `ok:false` without saying why gets. The
/// refusal is the caller's argument at fault, not a broken tool, so naming the
/// problem beats a blank line.
const refusal_unspecified = "the tool refused the request";

/// Runs `tool` with `input` and unwraps its answer. Only the ways a *tool* can
/// misbehave are errors here, and each is a log record: a guest that traps, is
/// missing, or answers something unreadable is a broken build, and the
/// command's own argument mistakes arrive as `.refused` instead.
pub fn callTool(arena: std.mem.Allocator, store: []const u8, tool: Tool, input: []const u8) error{ OutOfMemory, ToolFailed }!Reply {
    const raw = tool.call(tool.ctx, input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.log(.error_, "{s}: the tool call failed: {s}", .{ store, @errorName(err) });
            return error.ToolFailed;
        },
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{ .ignore_unknown_fields = true }) catch {
        log.log(.error_, "{s}: the tool answered something that is not JSON", .{store});
        return error.ToolFailed;
    };
    if (parsed != .object) {
        log.log(.error_, "{s}: the tool answered something that is not a JSON object", .{store});
        return error.ToolFailed;
    }
    if (!json_util.boolFieldOrFalse(parsed.object, "ok")) {
        return .{ .refused = json_util.strFieldOrNull(parsed.object, "error") orelse refusal_unspecified };
    }
    return .{ .ok = parsed.object };
}

const testing = std.testing;

/// A seam the tests drive with canned answers, standing in for the guest
/// `cli.zig` would have loaded.
const FakeTool = struct {
    answer: []const u8,
    fail_with: ?anyerror = null,

    fn call(ctx: *anyopaque, input: []const u8) anyerror![]const u8 {
        const self: *FakeTool = @ptrCast(@alignCast(ctx));
        _ = input;
        if (self.fail_with) |e| return e;
        return self.answer;
    }

    fn tool(self: *FakeTool) Tool {
        return .{ .ctx = self, .call = call };
    }
};

test "an ok answer comes back as the object to read fields out of" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fake: FakeTool = .{ .answer = "{\"ok\":true,\"entries\":[]}" };
    const reply = try callTool(arena, "schedule", fake.tool(), "{}");
    try testing.expect(reply == .ok);
    try testing.expect(reply.ok.get("nope") == null);
    // The fields a command actually reads are the guest's own, not the wrapper's.
    try testing.expect((reply.ok.get("entries").?) == .array);
}

test "a refusal is data, with the guest's own wording when it gave one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var said: FakeTool = .{ .answer = "{\"ok\":false,\"error\":\"no such entry\"}" };
    const reply = try callTool(arena, "schedule", said.tool(), "{}");
    try testing.expectEqualStrings("no such entry", reply.refused);

    // A guest that omits `ok`, or spells it as anything but a bool true, did
    // not say the call succeeded.
    var silent: FakeTool = .{ .answer = "{\"note\":\"done\"}" };
    try testing.expectEqual(refusal_unspecified, (try callTool(arena, "rfc", silent.tool(), "{}")).refused);

    // A refusal that did say why must keep that reason, not the stand-in.
    var bare: FakeTool = .{ .answer = "{\"ok\":false}" };
    try testing.expectEqual(refusal_unspecified, (try callTool(arena, "rfc", bare.tool(), "{}")).refused);
}

test "an unreadable answer is a failed tool, not a refusal the caller can word" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var broken: FakeTool = .{ .answer = "{\"ok\":true,\"note\":oops}" };
    try testing.expectError(error.ToolFailed, callTool(arena, "rfc", broken.tool(), "{}"));

    // A JSON array is readable JSON, but a store's answer is an object; a
    // caller reading fields off an array would be reading nothing.
    var list: FakeTool = .{ .answer = "[1,2]" };
    try testing.expectError(error.ToolFailed, callTool(arena, "rfc", list.tool(), "{}"));
}

test "a guest that fails to run is a failed tool, and OutOfMemory still propagates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var trapped: FakeTool = .{ .answer = "", .fail_with = error.ToolWasmMissing };
    try testing.expectError(error.ToolFailed, callTool(arena, "schedule", trapped.tool(), "{}"));

    var oom: FakeTool = .{ .answer = "", .fail_with = error.OutOfMemory };
    try testing.expectError(error.OutOfMemory, callTool(arena, "schedule", oom.tool(), "{}"));
}
