# Investigation — zig build test crashed once with an ISCONN panic in the peers connect path

## TL;DR

- **Question:** One gate run on 31e999c3's parent crashed: std.Io.Threaded posixConnect got ISCONN (already connected) and panicked as a programmer bug, inside HostName.enqueueConnection under a peers/mesh test. Same family as the member-socket fd-reuse race 677722dc fixed on the close side; connect-side reuse may remain. Not reproduced: the immediate rerun and two sibling worktree gates on the same base were clean.
- **Finding:** Investigating on 2026-08-19. seen once, not reproduced on rerun or sibling gates; connect-side fd reuse suspected, close side was fixed in 677722dc
- **Resolution:** Investigating on 2026-08-19. seen once, not reproduced on rerun or sibling gates; connect-side fd reuse suspected, close side was fixed in 677722dc

## Status

Investigating on 2026-08-19. seen once, not reproduced on rerun or sibling gates; connect-side fd reuse suspected, close side was fixed in 677722dc

## Trigger and scope

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

## References

- Related bug: none yet
