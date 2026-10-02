//! A blocking lock for structures that do not carry an `std.Io` handle.
//!
//! `std.Io.Mutex` is the tree's lock everywhere an `Io` exists, but a
//! process-global registry touched at first use, and a table a connection
//! thread reaches without one, have no handle to hand it: `std.Thread.Mutex`
//! is gone in Zig 0.16 and there is no other std lock that takes none. This
//! is that lock, in the one place, so the process table, the job table and the
//! A2A reply cache stop each carrying their own copy.
//!
//! The critical sections it guards are short (map lookup, a dupe, an append),
//! so yielding between attempts is enough; a long wait would want `Io`.

const std = @import("std");

pub const SpinMutex = struct {
    raw: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *SpinMutex) void {
        while (!self.raw.tryLock()) {
            std.Thread.yield() catch {};
        }
    }

    pub fn unlock(self: *SpinMutex) void {
        self.raw.unlock();
    }
};

const testing = std.testing;

test "the lock excludes, so a guarded counter cannot lose a count" {
    // What the three call sites depend on: the process table, the job table and
    // the A2A reply cache each mutate shared state under this lock from every
    // thread that reaches them. A lock that let two threads into a section at
    // once would not fail any single-call assertion -- it would lose
    // increments, or corrupt a list, where no assertion can see it. So the
    // assertion is the property the callers rely on: N threads take the lock
    // N times each, every critical section read-modify-writes shared state,
    // and the total has to come out exact.
    //
    // `std.testing.allocator` would race inside itself, so the guarded state is
    // a plain integer: the allocator must not be touched from inside a section
    // another thread can enter concurrently.
    const iterations = 2000;
    const Worker = struct {
        fn run(mutex: *SpinMutex, counter: *u64) void {
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                mutex.lock();
                counter.* += 1;
                mutex.unlock();
            }
        }
    };

    var mutex: SpinMutex = .{};
    var counter: u64 = 0;

    const threads = 8;
    var handles: [threads]std.Thread = undefined;
    for (&handles) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &mutex, &counter });
    for (&handles) |*t| t.join();

    try testing.expectEqual(@as(u64, threads * iterations), counter);
}

test "a held lock is waited out, and the mutex is reusable afterwards" {
    // The retry path needs its own case: a `tryLock`-only lock would pass the
    // counter test above (its `tryLock` would simply fail there instead of
    // blocking, and the count would come out short) but a `lock` that never
    // retried would hang it. So: a holder keeps the lock across yields, a
    // waiter must not get in until the holder has left, and the same mutex must
    // serve the next acquisition rather than being left locked.
    const Holder = struct {
        fn run(mutex: *SpinMutex, ready: *std.atomic.Value(bool), released: *std.atomic.Value(bool)) void {
            mutex.lock();
            ready.store(true, .release);
            // Held across yields: a waiter that barged in would find the lock
            // free here, and the assertion below that `released` is already set
            // is what pins the ordering rather than the luck of the scheduler.
            var i: usize = 0;
            while (i < 50) : (i += 1) std.Thread.yield() catch {};
            mutex.unlock();
            released.store(true, .release);
        }
    };

    var mutex: SpinMutex = .{};
    var ready: std.atomic.Value(bool) = .init(false);
    var released: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, Holder.run, .{ &mutex, &ready, &released });

    while (!ready.load(.acquire)) std.Thread.yield() catch {};
    // The holder announced itself inside the section, so taking the lock is
    // only possible once it has left.
    mutex.lock();
    try testing.expect(released.load(.acquire));
    mutex.unlock();
    thread.join();

    // Re-usable: the waiter unlocked what it took, so this completes rather
    // than spinning forever.
    mutex.lock();
    mutex.unlock();
}
