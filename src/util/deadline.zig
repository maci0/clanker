//! One bounded window around one blocking call.
//!
//! `std.Io` has no connect or read ceiling of its own here (the Threaded
//! io's connect timeout is an unimplemented stub), so a peer that accepts and
//! then goes quiet would hold the caller for the kernel's own timeout (~75s
//! on Linux when SYNs are dropped) or forever. The policy every such caller
//! needs: run the call as a concurrent task, wait on its done event under a
//! deadline, and cancel at the deadline; cancel interrupts the underlying
//! syscall and joins the task before returning, so nothing writes into caller
//! memory afterwards.
//!
//! That wait loop used to live in three copies (util/http_client.zig,
//! cli.zig httpGetDeadline, serve/mesh_net.zig connectBounded), including its
//! subtleties: `waitTimeout` reports Timeout on spurious wakeups too, so only
//! the deadline clock decides whether the budget is really spent; and every
//! task exit must set its done event or the waiter never wakes. One named
//! implementation keeps those decisions in one place.

const std = @import("std");

/// Runs `function(args)` as a concurrent task under a wall-clock budget.
///
/// `budget_ms <= 0` means no ceiling: the call runs inline on this thread,
/// for callers that explicitly opt into the unbounded wait.
///
/// Errors: the task's own errors pass through unchanged, plus
/// `error.ConcurrencyUnavailable` when no io worker could be spawned, and
/// `error.Timeout` / `error.Canceled` from the window itself. Allocation-free:
/// the window adds only the event, the future, and one timestamp.
pub fn runBounded(
    io: std.Io,
    budget_ms: i64,
    function: anytype,
    args: anytype,
) blk: {
    const R = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    break :blk switch (@typeInfo(R)) {
        // Tasks return error unions; merge their set with the window's so
        // callers see the task's own errors unchanged.
        .error_union => |eu| (eu.error_set || error{ ConcurrencyUnavailable, Timeout, Canceled })!eu.payload,
        else => R,
    };
} {
    const Args = @TypeOf(args);
    const Return = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const Wrapper = struct {
        fn task(inner_io: std.Io, a: Args, d: *std.Io.Event) Return {
            defer d.set(inner_io);
            return @call(.auto, function, a);
        }
    };

    if (budget_ms <= 0) return @call(.auto, function, args);

    var done: std.Io.Event = .unset;
    var fut = try io.concurrent(Wrapper.task, .{ io, args, &done });
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{
        .clock = .awake,
        .raw = .{ .nanoseconds = @as(i96, budget_ms) * std.time.ns_per_ms },
    });
    while (!done.isSet()) {
        done.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => {
                if (done.isSet()) break;
                if (deadline.durationFromNow(io).raw.nanoseconds > 0) continue;
                _ = fut.cancel(io) catch {};
                return error.Timeout;
            },
            error.Canceled => {
                _ = fut.cancel(io) catch {};
                return error.Canceled;
            },
        };
    }
    return try fut.await(io);
}

test "runBounded passes the task's result through" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const T = struct {
        fn answer(x: u32) anyerror!u32 {
            return x * 2;
        }
        fn slowAnswer(io2: std.Io, x: u32) anyerror!u32 {
            try io2.sleep(.fromMilliseconds(20), .awake);
            return x + 1;
        }
    };
    try std.testing.expectEqual(@as(u32, 84), try runBounded(io, 5_000, T.answer, .{42}));
    // The bounded path itself, not the inline shortcut: a real future that
    // finishes well inside the budget.
    try std.testing.expectEqual(@as(u32, 43), try runBounded(io, 5_000, T.slowAnswer, .{ io, 42 }));
}

test "runBounded cancels a silent task at the deadline" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const T = struct {
        fn never(io2: std.Io) anyerror!void {
            // Cancellable park, not a spin: cancel() must be able to join us.
            io2.sleep(.fromSeconds(30), .awake) catch {};
        }
    };
    const started = std.Io.Timestamp.now(io, .awake);
    const r = runBounded(io, 100, T.never, .{io});
    try std.testing.expectError(error.Timeout, r);
    const elapsed_ns = std.Io.Timestamp.now(io, .awake).nanoseconds - started.nanoseconds;
    // Budget decided the answer, not the 30s sleep.
    try std.testing.expect(elapsed_ns < std.time.ns_per_s);
}

test "runBounded with a non-positive budget runs inline without a ceiling" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const T = struct {
        fn answer() anyerror![]const u8 {
            return "inline";
        }
        fn failing() anyerror!u8 {
            return error.TaskFailed;
        }
    };
    try std.testing.expectEqualStrings("inline", try runBounded(io, 0, T.answer, .{}));
    // The task's own errors pass through unchanged in both paths.
    try std.testing.expectError(error.TaskFailed, runBounded(io, 5_000, T.failing, .{}));
}
