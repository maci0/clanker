# Investigation — zig build test crashed once with an ISCONN panic in the peers connect path

## TL;DR

- **Question:** One gate run on 31e999c3's parent crashed: std.Io.Threaded posixConnect got ISCONN (already connected) and panicked as a programmer bug, inside HostName.enqueueConnection under a peers/mesh test. Same family as the member-socket fd-reuse race 677722dc fixed on the close side; connect-side reuse may remain. Not reproduced: the immediate rerun and two sibling worktree gates on the same base were clean.
- **Finding:** Traced to zig std, not clanker. `std.Io.Threaded.posixConnect` retries `connect()` after EINTR; POSIX keeps establishing the connection asynchronously after an interrupted connect, so the retry can legally return EISCONN — which posixConnect maps to `errnoBug` and panics. Connect-side fd reuse in clanker is ruled out: `HostName.enqueueConnection` gives every attempt a private, freshly created socket.
- **Resolution:** Closed 2026-08-21 — no clanker defect. The fix belongs upstream in zig's `posixConnect` (treat EISCONN after an EINTR retry as success).

## Status

Closed on 2026-08-21. Root cause identified in `std.Io.Threaded.posixConnect` (zig 0.16 toolchain, `lib/std/Io/Threaded.zig`); nothing in clanker's tree to change.

## Trigger and scope

Any blocking connect made through the Threaded io — `IpAddress.connect` (mesh `connectBounded`), or a hostname connect through `std.http.Client` → `HostName.connect` → `enqueueConnection` (the peers/mesh path via `src/util/http_client.zig`) — is exposed. The panic needs a signal to land while `connect()` is blocked, so it is rare and load-dependent, which matches "seen once, clean on rerun and on two sibling gates".

## Evidence

- `lib/std/Io/Threaded.zig`, `posixConnect`: the syscall loop retries `connect()` on `.INTR` (`try syscall.checkCancel(); continue;`) and maps `.ISCONN` to `syscall.errnoBug(err)` — a panic, not an error return.
- POSIX (`connect(2)`): if connect() is interrupted by a caught signal, "the connection request shall not be aborted, and the connection shall be established asynchronously"; a subsequent connect() on the same socket then fails EALREADY while in progress and **EISCONN once established**. The retry-after-EINTR in posixConnect is exactly that subsequent connect.
- `lib/std/Io/net/HostName.zig`, `connectMany`/`enqueueConnection`: each resolved address gets its own `address.connect(io, options)` on a socket created inside that call. No socket is shared or reused across attempts, so there is no clanker-visible fd for a connect-side reuse race — fd reuse would surface as BADF/NOTSOCK (both also mapped to errnoBug), not ISCONN.

## Hypotheses and tests

- **Connect-side fd reuse in clanker (original suspicion): ruled out.** The panicking fd is private to one `enqueueConnection` attempt from socket() to close; clanker code never sees it. The close-side race 677722dc fixed involved member fds owned by mesh_net's registry — a different population of descriptors.
- **EINTR-retry → EISCONN in std: consistent with everything observed.** Threaded io implements cancellation by signalling threads out of blocking syscalls, so its own signals are a ready EINTR source: a stale cancel signal hitting a reused pool thread (whose current task is *not* cancelled, so `checkCancel` passes and the loop retries), or happy-eyeballs `group.cancel` traffic in `connectMany` while a sibling attempt sits in connect. A localhost handshake completes fast enough that the interrupted attempt is established by the time the retry runs.
- Not reproduced locally by rerunning the gate; the window is one signal delivery inside a blocking connect that is about to succeed. No clanker-side test can force it without patching std.

## Finding

The panic is a zig std defect: `posixConnect` retries `connect()` after EINTR but treats the EISCONN that retry can legally return as a programmer bug. Clanker's connect paths are correct; 677722dc's close-side fix stands on its own and is unrelated to this crash.

## Resolution or handoff

Closed as no-clanker-defect. Upstream fix: in `posixConnect`, after at least one `.INTR` retry, treat `.ISCONN` as success (the socket is connected to the requested address). Until zig ships that, a recurrence looks identical: a one-off `errnoBug: ISCONN` panic inside any Threaded connect under signal load — rerun the gate, do not hunt clanker's socket handling for it.

## References

- Related bug: none — close-side fd reuse was fixed in 677722dc (`src/serve/mesh_net.zig`), a separate defect.
- `lib/std/Io/Threaded.zig` `posixConnect` (ISCONN → errnoBug) and `lib/std/Io/net/HostName.zig` `connectMany`/`enqueueConnection` in the pinned zig 0.16 toolchain.
