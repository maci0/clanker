//! Self-contained HTML transcript for a saved session (`clanker session
//! export <id>`).
//!
//! Local-first by design: this writes one file to disk and never talks to the
//! network. The shareable-link half of the idea (a paste-service upload that
//! hands back a public URL) is deliberately not built here; a file that opens
//! from `file://` and can be attached to a mail or a ticket is the version
//! that does not need a server to keep running for the link to survive.
//!
//! The rendering core (escaping, timestamps, the self-contained HTML) lives in
//! session_export_logic.zig, a host-tested module: this guest runs sandboxed
//! wasm, where a `test` block can never run, and the XSS-hardening tests
//! around `escape`/`render` are the ones that must run.

const std = @import("std");
const lib = @import("lib.zig");
const logic = @import("session_export_logic.zig");

const Session = logic.Session;
const validId = logic.validId;
const render = logic.render;
const defaultPath = logic.defaultPath;

const Request = struct { id: []const u8, return_html: bool = false, forget: bool = false };

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, toolMain);
}

/// Deletes the export of one session, called when its transcript is deleted.
///
/// An export is the whole conversation rendered to HTML, so erasing the
/// session while `state/exports/<id>.html` stays behind erases nothing. A
/// session that was never exported has no file, which is success rather than
/// an error: the caller is a delete path that has already dropped the
/// transcript and cannot know whether an export was ever taken.
fn forget(out: *lib.Out, id: []const u8) !void {
    const path = try defaultPath(lib.alloc, id);
    lib.fsDelete(path) catch |err| switch (err) {
        error.NotFound => {},
        else => return lib.failErr(out, err, "deleting export"),
    };
    var writer = lib.writer(out);
    var json = lib.json(&writer);
    try json.beginObject();
    try json.objectField("ok");
    try json.write(true);
    try json.objectField("forgot");
    try json.write(path);
    try json.endObject();
    lib.commit(out, &writer);
}

fn toolMain(input: []const u8, out: *lib.Out) !void {
    const req = std.json.parseFromSliceLeaky(Request, lib.alloc, input, .{ .ignore_unknown_fields = true }) catch
        return lib.fail(out, "expected a session id");
    if (!validId(req.id)) return lib.fail(out, "invalid session id");
    if (req.forget) return forget(out, req.id);
    const source = try std.fmt.allocPrint(lib.alloc, "state/sessions/{s}.json", .{req.id});
    const raw = lib.fsRead(source) catch |err| return lib.failErr(out, err, "reading session");
    const value = std.json.parseFromSliceLeaky(Session, lib.alloc, raw, .{ .ignore_unknown_fields = true }) catch |err|
        return lib.failErr(out, err, "parsing session");
    const html = render(lib.alloc, value) catch |err| return lib.failErr(out, err, "rendering session");
    const path = try defaultPath(lib.alloc, req.id);
    if (!req.return_html) lib.fsWrite(path, html) catch |err| return lib.failErr(out, err, "writing export");

    var writer = lib.writer(out);
    var json = lib.json(&writer);
    try json.beginObject();
    try json.objectField("ok");
    try json.write(true);
    try json.objectField("path");
    try json.write(path);
    try json.objectField("messages");
    try json.print("{d}", .{value.messages.len});
    try json.objectField("bytes");
    try json.print("{d}", .{html.len});
    if (req.return_html) {
        try json.objectField("html");
        try json.write(html);
    }
    try json.endObject();
    lib.commit(out, &writer);
}
