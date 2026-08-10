//! webui: serves the clanker web UI — a single self-contained page with no
//! external scripts, styles, or fonts, so it works on an offline host
//! (webui/index.html, embedded at comptime via @embedFile) — from the sandbox.
//! Third-party JS the page needs (graph layout, code highlighting) is vendored
//! and served separately by the native HTTP server from webui/vendor/ — see
//! handleWebui/handleWebuiVendor in cli.zig — rather than routed through this
//! WASM tool, whose shared output buffer (lib.zig's out_cap, 64 KiB) is far
//! smaller than those files.
//! Internal tool: it is never offered to the LLM; the `clanker serve` HTTP
//! server calls it to render GET / and /webui.
//! Input:  {"path": "/"}
//! Output: {"ok": true, "content_type": "text/html", "body": "..."}

const std = @import("std");
const lib = @import("lib.zig");

/// The page is kept as a separate asset (webui/index.html) so it can be
/// edited independently of the tool code; embedded at comptime.
const page = @embedFile("webui/index.html");

// The page reaches the browser JSON-encoded through lib.zig's shared output
// buffer, so the buffer — not the raw file size — is the real ceiling on how
// big index.html may get. Checked here at build time: outgrowing it silently
// would otherwise surface as a 500 from `clanker serve` at request time.
comptime {
    // One branch per byte of the page, plus headroom.
    @setEvalBranchQuota(4 * page.len);
    // Matches std.json's default (escape_unicode = false): bytes 0x20-0x21,
    // 0x23-0x5B and 0x5D-0xFF pass through, `"` `\` and the seven short
    // control escapes take two bytes, every other control byte becomes \u00xx.
    var encoded: usize = 2; // the enclosing quotes
    for (page) |c| encoded += switch (c) {
        '"', '\\', 0x08, 0x0C, '\n', '\r', '\t' => 2,
        0x00...0x07, 0x0B, 0x0E...0x1F => 6,
        else => 1,
    };
    const envelope = "{\"ok\":true,\"content_type\":\"text/html\",\"body\":".len + encoded + "}".len;
    if (envelope > lib.out_cap) @compileError(std.fmt.comptimePrint(
        "webui/index.html JSON-encodes to {d} bytes, over lib.zig's out_cap of {d}. Shrink the page or raise out_cap.",
        .{ envelope, lib.out_cap },
    ));
}

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    _ = parsed;
    // Any path serves the single-page app (client-side routing is handled in JS).
    // Encoded straight into the shared output buffer: an intermediate stack
    // copy would duplicate the whole page and cap it at its own size rather
    // than at out_cap.
    var w: std.Io.Writer = .fixed(out.buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("content_type");
    try s.write("text/html");
    try s.objectField("body");
    try s.write(page);
    try s.endObject();
    out.len = w.end;
}
