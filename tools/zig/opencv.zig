//! opencv: image analysis through OpenCV.
//!
//! Input:  {"op": "info"|"edges"|"faces"|"contours"|"grayscale"|"resize",
//!          "path": "<image>", "options": { ... }}
//! Output: the analysis JSON, or {"ok": false, "error": "..."}
//!
//! A wasm32-freestanding guest cannot link OpenCV, and no in-process binding
//! exists, so this shells out to tools/py/opencv.py through ck_exec. uv
//! supplies cv2 in an ephemeral environment, so nothing is installed on the
//! host. The descriptor's `exec_allow` limits this tool to `uv` alone.

const std = @import("std");
const lib = @import("lib.zig");

const script = "tools/py/opencv.py";

const Request = struct {
    op: []const u8 = "info",
    path: []const u8 = "",
    options: std.json.Value = .{ .object = .{} },
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    const req = std.json.parseFromSliceLeaky(Request, alloc, input, .{ .ignore_unknown_fields = true }) catch
        return lib.fail(out, "input must be {\"op\": ..., \"path\": ...}");

    if (req.path.len == 0) return lib.fail(out, "path is required");
    const known_ops = [_][]const u8{ "info", "edges", "faces", "contours", "grayscale", "resize" };
    var op_ok = false;
    for (known_ops) |k| {
        if (std.mem.eql(u8, req.op, k)) op_ok = true;
    }
    if (!op_ok) return lib.fail(out, "op must be info, edges, faces, contours, grayscale, or resize");
    // The script reads whatever path it is handed, so the traversal check
    // belongs here rather than in Python: keep it inside the project.
    if (std.mem.startsWith(u8, req.path, "/") or std.mem.find(u8, req.path, "..") != null)
        return lib.fail(out, "path must be relative and stay inside the project");

    const opts = try std.fmt.allocPrint(alloc, "{f}", .{std.json.fmt(req.options, .{})});

    var args: std.ArrayList([]const u8) = .empty;
    // `uv run --with` builds a throwaway env: no host package is touched.
    for ([_][]const u8{ "run", "--quiet", "--with", "opencv-python-headless~=4.14", "--with", "numpy>=1.26,<3", "python3", script, req.op, req.path }) |a| {
        try args.append(alloc, a);
    }
    try args.append(alloc, opts);

    const raw = lib.exec("uv", args.items) catch |err| return lib.failErr(out, err, "running the opencv helper");

    // ck_exec answers {"code":N,"stdout":"...","stderr":"..."}; the script's
    // own JSON is on stdout and is what the agent should see.
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{ .ignore_unknown_fields = true }) catch
        return lib.fail(out, "exec returned no JSON");
    if (parsed != .object) return lib.fail(out, "exec returned no JSON");

    const stdout = lib.jsonStrField(parsed.object, "stdout");
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len > 0) return out.writeAll(trimmed);

    const stderr = lib.jsonStrField(parsed.object, "stderr");
    const tail = if (stderr.len > 400) stderr[stderr.len - 400 ..] else stderr;
    var ebuf: [640]u8 = undefined;
    var ew: std.Io.Writer = .fixed(&ebuf);
    var es = std.json.Stringify{ .writer = &ew, .options = .{} };
    try es.beginObject();
    try es.objectField("ok");
    try es.write(false);
    try es.objectField("error");
    try es.write(if (tail.len > 0) tail else "opencv script produced no output");
    try es.endObject();
    try out.writeAll(ebuf[0..ew.end]);
}
