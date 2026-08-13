//! image: read an image file, base64-encode it, and return it as a multimodal
//! part so the model can see it on the next turn. The agent loop detects
//! {"ok":true,"image":{...}} results and attaches them to the conversation.
//! Input:  {"path": "tests/fixtures/photo.png"}
//! Output: {"ok": true, "image": {"mime": "image/png", "b64": "..."}}

const std = @import("std");
const lib = @import("lib.zig");

const max_image_bytes = 1 << 20;

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    const obj = parsed.object;
    const path = switch (obj.get("path") orelse return lib.fail(out, "missing path")) {
        .string => |s| s,
        else => return lib.fail(out, "path must be a string"),
    };

    const data = lib.fsRead(path) catch |err| return lib.failErr(out, err, "reading the image");
    // Keep the base64 + JSON under the guest output cap (lib.out_cap, 2 MiB):
    // 1 MiB of image encodes to ~1.37 MiB of base64 plus JSON framing.
    if (data.len > max_image_bytes) return lib.fail(out, "image too large (max 1048576 bytes)");

    const mime = mimeFor(path);
    const b64_len = std.base64.standard.Encoder.calcSize(data.len);
    const b64 = lib.alloc.alloc(u8, b64_len) catch return lib.fail(out, "alloc");
    defer lib.alloc.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, data);

    const rbuf = lib.alloc.alloc(u8, b64_len + 256) catch return lib.fail(out, "alloc");
    defer lib.alloc.free(rbuf);
    var w: std.Io.Writer = .fixed(rbuf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("image");
    try s.beginObject();
    try s.objectField("mime");
    try s.write(mime);
    try s.objectField("b64");
    try s.write(b64);
    try s.endObject();
    try s.endObject();
    try out.writeAll(rbuf[0..w.end]);
}

fn mimeFor(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
    return "image/png";
}
