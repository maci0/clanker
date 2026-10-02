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

// ---------------------------------------------------------------------
// pthread_cond_timedwait budgets
// ---------------------------------------------------------------------

/// Longest single `pthread_cond_timedwait` a caller re-arms for. The budget is
/// re-checked against the monotonic clock between slices, so this bounds how
/// long a wall-clock step can delay a wakeup that has already arrived, not how
/// long the whole wait may last.
pub const cond_slice_ns: u64 = std.time.ns_per_s;

/// How much of `budget_ns` is left after `spent_ns` of monotonic time, and how
/// long the next `pthread_cond_timedwait` should be armed for.
///
/// A `timedwait` deadline is absolute and expressed on whatever clock the
/// condvar was built with, which is CLOCK_REALTIME unless a clock attribute
/// says otherwise — and `std.c` exposes no way to set that attribute. So the
/// absolute deadline has to be computed from the wall clock, while the question
/// "is the budget spent?" can only be answered from the monotonic one. Measured
/// against the wall clock, an NTP step or an operator `date -s` decides a budget
/// that is really a claim about how long a person gets to answer: a backward
/// step puts the absolute deadline in the past and every waiter times out at
/// once, refusing on the caller's behalf; a forward step grants the whole
/// interval again and holds the thread for it. Re-arming in short slices bounds
/// both to one slice.
///
/// `null` means the budget is spent and the caller must stop waiting. `spent_ns`
/// is a monotonic difference and so never negative.
pub fn condWaitSlice(budget_ns: u64, spent_ns: u64) ?u64 {
    if (spent_ns >= budget_ns) return null;
    const left = budget_ns - spent_ns;
    return @min(left, cond_slice_ns);
}

test "a spent budget stops the wait, and a partial one waits the slice" {
    // Nothing spent: one whole slice, not the whole budget, so a wall-clock
    // step can extend the wait by at most this.
    try std.testing.expectEqual(@as(u64, cond_slice_ns), condWaitSlice(120 * std.time.ns_per_s, 0).?);

    // Mid-budget: the slice, because the budget exceeds it.
    try std.testing.expectEqual(@as(u64, cond_slice_ns), condWaitSlice(120 * std.time.ns_per_s, 5 * std.time.ns_per_s).?);

    // The last slice is what is left, never the slice ceiling again: this is
    // the arming that ends the wait instead of overshooting the budget.
    try std.testing.expectEqual(@as(u64, 250 * std.time.ns_per_ms), condWaitSlice(120 * std.time.ns_per_s, 120 * std.time.ns_per_s - 250 * std.time.ns_per_ms).?);

    // Spent, and exactly spent, both stop: `>=` rather than `>` so a budget
    // that reaches zero exactly does not buy one more slice.
    try std.testing.expect(condWaitSlice(120 * std.time.ns_per_s, 120 * std.time.ns_per_s) == null);
    try std.testing.expect(condWaitSlice(120 * std.time.ns_per_s, 121 * std.time.ns_per_s) == null);
}

test "a zero budget never waits" {
    // A zero budget is spent from the first reading: `left` would be 0, and
    // arming a timedwait for zero would park a thread on a deadline it has
    // already passed and hand the answer to whoever steps the clock next.
    try std.testing.expect(condWaitSlice(0, 0) == null);
    try std.testing.expect(condWaitSlice(0, 1) == null);
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
