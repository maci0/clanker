//! ask_user: put a decision to the human and wait for their pick.
//!
//! For the moments where guessing is worse than asking: which of two designs
//! to build, which file to change, whether to widen the scope. The harness
//! renders the options and returns the chosen one verbatim.
//!
//! Input:  {"question": "Which first?", "options": ["fix the eval", "add the tool"]}
//! Output: {"ok": true, "answer": "fix the eval"}
//!         {"ok": false, "error": "..."} when nobody is attached to answer.

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{}) catch
        return errJson(out, "input must be a JSON object");
    if (parsed != .object) return errJson(out, "input must be a JSON object");

    const q = parsed.object.get("question") orelse return errJson(out, "missing required field: question");
    if (q != .string or q.string.len == 0) return errJson(out, "question must be a non-empty string");

    var options: std.ArrayList([]const u8) = .empty;
    defer options.deinit(std.heap.wasm_allocator);
    if (parsed.object.get("options")) |o| {
        if (o == .array) {
            for (o.array.items) |item| {
                if (item == .string and item.string.len > 0) try options.append(std.heap.wasm_allocator, item.string);
            }
        }
    }
    if (options.items.len < 2) return errJson(out, "give at least two options; ask in your answer instead when the question is open-ended");

    const answer = lib.ask(q.string, options.items) catch |err| return errJson(out, switch (err) {
        // Scripted runs have no human: say so plainly so the model picks.
        error.NotFound => "no interactive user is attached; decide yourself and say which option you took and why",
        else => "could not ask the user",
    });

    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("answer");
    try s.write(answer);
    try s.endObject();
    try out.writeAll(buf[0..w.end]);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
