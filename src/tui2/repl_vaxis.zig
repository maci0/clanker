//! Phase 1 of the libvaxis migration (see docs/ROADMAP.md): a minimal
//! vaxis-backed skeleton proving the dependency actually builds and runs,
//! before anything user-facing (transcript, streaming, tool cards) moves
//! onto it. Deliberately not wired into `clanker repl` — reachable only
//! via the separate `clanker repl-vaxis` subcommand so the existing
//! hand-rolled REPL (src/tui/*) keeps working untouched while this is
//! proven out alongside it.
//!
//! Scope, on purpose: a status line, a bordered text input, live SIGWINCH
//! reflow (via vaxis's own winsize event — no self-pipe needed, unlike
//! src/tui/term.zig's hand-rolled one), and Ctrl-C to quit. No transcript,
//! no LLM calls, no streaming.

const std = @import("std");
const vaxis = @import("vaxis");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub fn cmdReplVaxis(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &buffer);
    defer tty.deinit();
    const writer = tty.writer();

    var vx = try vaxis.init(io, gpa, init.environ_map, .{
        .kitty_keyboard_flags = .{ .report_events = true },
    });
    defer vx.deinit(gpa, writer);

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(writer);
    try vx.queryTerminal(writer, .fromSeconds(1));

    var text_input = vaxis.widgets.TextInput.init(gpa);
    defer text_input.deinit();

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) return;
                try text_input.update(.{ .key_press = key });
            },
            .winsize => |ws| {
                try vx.resize(gpa, writer, ws);
                vx.queueRefresh();
            },
        }

        const win = vx.window();
        win.clear();

        const status_style: vaxis.Style = .{ .dim = true };
        _ = win.printSegment(.{
            .text = "clanker (vaxis skeleton) \xc2\xb7 Ctrl-C to quit",
            .style = status_style,
        }, .{ .row_offset = 0 });

        const input_win = win.child(.{
            .x_off = 0,
            .y_off = win.height -| 3,
            .width = win.width,
            .height = 3,
            .border = .{ .where = .all },
        });
        text_input.draw(input_win);

        try vx.render(writer);
        try writer.flush();
    }
}
