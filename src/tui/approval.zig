//! Inline approval prompt: `ask_user`'s terminal side. Fires mid-turn (the
//! agent is blocked on an answer and the REPL's own input loop is not
//! running), so this owns the terminal for its duration: enters raw mode,
//! reads through the same `lineedit.Editor` + `input.KeyReader` path the main
//! input box uses, and re-prompts on anything unparseable or out-of-range
//! instead of silently picking the first option.
//!
//! Entering raw mode (rather than reading through whatever cooked mode was
//! left over from the last `readLineRaw` call, as the previous
//! implementation did) is not just cosmetic: in cooked mode `ISIG` stays on,
//! so Ctrl-C here used to send a real `SIGINT` and kill the process instead
//! of just canceling the prompt. Raw mode makes Ctrl-C an ordinary
//! `.interrupt` key like everywhere else in the REPL.

const std = @import("std");
const lineedit = @import("../util/lineedit.zig");
const term = @import("term.zig");
const region = @import("region.zig");
const input = @import("input.zig");
const theme_mod = @import("theme.zig");
const Theme = theme_mod.Theme;

const prompt_text = "pick> ";
const prompt_width = 6; // "pick> "

/// Prints the question and numbered options once, then collects a numeric
/// pick through a small `BottomRegion` that re-prompts on bad input. Returns
/// the chosen option text (gpa-owned; the caller — `ckAsk` — frees it).
pub fn ask(
    gpa: std.mem.Allocator,
    out_w: *std.Io.File.Writer,
    stdin_file: std.Io.File,
    theme: *const Theme,
    question: []const u8,
    options: []const []const u8,
) anyerror![]const u8 {
    try out_w.interface.print("\n{s}? {s}{s}\n", .{ theme.ask_question, theme.reset, question });
    for (options, 1..) |o, n| {
        try out_w.interface.print("  {s}{d}{s} {s}\xc2\xb7{s} {s}\n", .{ theme.ask_pick, n, theme.reset, theme.dim, theme.reset, o });
    }
    try out_w.interface.flush();

    const raw_guard = term.enterRaw(stdin_file.handle) catch {
        // Not actually a terminal: no keys can arrive, so waiting for one
        // would hang forever. Fall back to the first option.
        return gpa.dupe(u8, options[0]);
    };
    defer raw_guard.exit();

    var editor = lineedit.Editor{ .gpa = gpa };
    defer editor.deinit();
    var reg = region.BottomRegion{ .gpa = gpa };
    defer reg.deinit();
    var err_buf: [96]u8 = undefined;
    var err_line: []const u8 = "";
    var key_reader = input.KeyReader{};

    while (true) {
        var frame_arena = std.heap.ArenaAllocator.init(gpa);
        defer frame_arena.deinit();
        try redraw(frame_arena.allocator(), out_w, theme, &editor, &reg, err_line);

        const key = try key_reader.next(stdin_file) orelse return cancel(out_w, theme, &reg);
        switch (key) {
            // Ctrl-C/Ctrl-D bail out of the question; they must not read as
            // "the user picked option 1", which is what returning options[0]
            // here used to do silently.
            .interrupt, .eof => return cancel(out_w, theme, &reg),
            .enter => {
                const typed = std.mem.trim(u8, editor.line(), " \t.)");
                const idx = std.fmt.parseInt(usize, typed, 10) catch 0;
                if (idx >= 1 and idx <= options.len) {
                    return finish(out_w, theme, &reg, gpa, options[idx - 1]);
                }
                err_line = std.fmt.bufPrint(&err_buf, "'{s}' is not 1-{d} \xe2\x80\x94 try again", .{ typed, options.len }) catch "not a valid pick \xe2\x80\x94 try again";
                editor.reset();
            },
            else => _ = editor.apply(key),
        }
    }
}

fn redraw(arena: std.mem.Allocator, out_w: *std.Io.File.Writer, theme: *const Theme, editor: *const lineedit.Editor, reg: *region.BottomRegion, err_line: []const u8) !void {
    const input_line = try std.fmt.allocPrint(arena, "{s}{s}{s}{s}", .{ theme.dim, prompt_text, theme.reset, editor.line() });
    var lines: std.ArrayList([]const u8) = .empty;
    try lines.append(arena, input_line);
    if (err_line.len > 0) {
        try lines.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ theme.err, err_line, theme.reset }));
    }
    try reg.render(&out_w.interface, lines.items, 0, prompt_width + editor.cursor);
    try out_w.interface.flush();
}

/// Moves the cursor past whatever the region last drew (an error line may
/// still be showing) before printing the chosen answer as an ordinary
/// transcript line, so it can't land mid-region and garble the output.
fn finish(out_w: *std.Io.File.Writer, theme: *const Theme, reg: *const region.BottomRegion, gpa: std.mem.Allocator, chosen: []const u8) ![]const u8 {
    const rows = reg.lineCount();
    if (rows > 1) try out_w.interface.print("\x1b[{d}B", .{rows - 1});
    try out_w.interface.print("\r\n{s}\xe2\x86\x92 {s}{s}\n", .{ theme.dim, chosen, theme.reset });
    try out_w.interface.flush();
    return gpa.dupe(u8, chosen);
}

/// Same cursor bookkeeping as `finish`, but for a question the user backed
/// out of instead of answered. Returns `error.NoUser`, the same signal a
/// closed browser tab or a headless run gives ckAsk, so the caller falls
/// back to "let the model decide" rather than treating a bail-out as a pick.
fn cancel(out_w: *std.Io.File.Writer, theme: *const Theme, reg: *const region.BottomRegion) anyerror![]const u8 {
    const rows = reg.lineCount();
    if (rows > 1) try out_w.interface.print("\x1b[{d}B", .{rows - 1});
    try out_w.interface.print("\r\n{s}\xe2\x86\x92 cancelled{s}\n", .{ theme.dim, theme.reset });
    try out_w.interface.flush();
    return error.NoUser;
}
