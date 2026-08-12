# ADR 0006 — Fan-out concurrency belongs to the host, not to the guest

## Status

Accepted.

## Context

A wasm32-freestanding guest is single-threaded. Every model call a tool makes
goes through `ck_llm`, one host trap per call, and the guest is blocked inside
it until the provider answers. So a tool that asks N models the same question
costs the *sum* of their latencies. At the four to six seconds a real completion
takes, five models is half a minute of dead time for work that has no ordering
between its parts at all.

That is the whole shape of `clanker compare` (blind side-by-side model
comparison, `docs/ROADMAP.md`): one prompt, N independent answers, nothing
downstream until they are all in. Three ways to get the parallelism:

1. **Loop `ck_llm` in the guest.** No new ABI surface, and correct. Also
   sequential by construction, which is the thing being fixed. Not viable.
2. **Do the fan-out natively in `src/cli.zig`, next to `pingWithTimeout`.** The
   sweep in `cmdProvidersCheck` already runs concurrent `client.chat` calls via
   `io.concurrent`, so the machinery exists and nothing new is exposed to a
   guest. The cost is that the feature then exists only as a subcommand: an
   agent reaching for the `compare` tool mid-run would get either nothing or a
   second, sequential implementation of the same logic. Two implementations of a
   comparison that are allowed to disagree is worse than the latency.
3. **A new host function, `ck_llm_many`.** One trap carries N targets; the host
   runs them side by side and returns an array. The guest stays single-threaded
   and stays the only place the feature is implemented.

`ck_swarm` already established that a fan-out on the guest's behalf is the
host's job: it spawns a thread and a full nested agent per task, joins every one
before returning, and hands the guest a JSON array. Nothing about that shape is
specific to agent runs.

## Decision

Add `ck_llm_many(request) -> [{provider, model, ok, text|error, ms, tokens}]`,
one thread per target, all joined before the call returns. Option 3.

The guest-visible contract deliberately mirrors `ck_llm` rather than inventing a
second one: same `"llm": true` descriptor grant, same session token budget
(charged once for the batch, so running the calls side by side does not make
them free), same provider/model override fields, capped at 8 targets for the
same reason `ck_swarm` caps at 8 tasks. A failing target is a failing *element*,
carrying the provider's own error text; it is never a failing call.

## Consequences

Makes easy: any tool that has N independent completions to make gets the
parallelism for one host call and no threading of its own. `compare` is the
first, but "ask three models and vote" and "translate into five languages at
once" are the same shape, and neither needs a guest change to get there.

Makes hard: the ABI grew a function, and the ABI is the sandbox's contract
surface. Every future reviewer of `docs/prompts/sandbox-security-review.md` has
one more entry point to reason about, and the child-instance linker in
`host.zig` has to keep registering it in lockstep with the parent's, or a nested
tool call silently loses the function.

Costs, honestly: the fan-out uses `std.Thread.spawn` rather than the `io.concurrent`
+ `Future.cancel` pattern `pingWithTimeout` uses, which means there is no
per-target wall-clock ceiling. A provider that accepts a connection and then
never answers holds the whole batch for as long as `client.chat`'s own retry
budget allows. `ck_swarm` has the same exposure and it has not bitten yet, but a
comparison is more likely to include a half-configured provider than a swarm is,
so this is the first thing to revisit if batches start hanging. The fix is
known (wrap each leg the way `pingWithTimeout` wraps a ping) and does not change
the ABI.

Thread safety is inherited, not new: `client.chat` is already called
concurrently by `ck_swarm`'s nested agents, and the one piece of shared mutable
state on that path, `vertex_token.zig`'s access-token cache, is behind
`std.Io.Mutex`. Each leg allocates from its own arena over the shared gpa, as
`ck_swarm`'s calls do.
