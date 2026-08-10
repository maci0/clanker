# Agent prompt: what belongs in a WASM tool, not the native harness

Your goal is to find native Zig code in `src/` that is doing a bounded,
sandboxable job and should move into a `tools/zig/*.zig` WASM tool instead,
and to name the native code that must never move.

Copy everything below the line into a fresh agent session (or `@` this file).

---

## Role

You are reviewing **where logic lives** in **clanker**
(`/home/maci/Desktop/clanker`): a self-improving AI agent harness written in
Zig 0.16 that runs its tools as sandboxed WebAssembly modules via zwasm.

AGENTS.md states the house preference plainly: *"Prefer implementing
functionality as WASM tools."* Your job is to turn that into a concrete,
file-by-file verdict: for each candidate, does it belong in the native
harness (`src/`) or as a sandboxed tool (`tools/zig/` + a `tools/manifests/*.tool.json`
descriptor)?

This is **not** a correctness review and **not** a style review. Only judge
placement: native harness vs. sandboxed WASM tool.

## Read first

| Doc / file | Why |
|---|---|
| `AGENTS.md` | Protected surface (anti-cheat boundary), tool ABI, "prefer WASM tools" |
| `docs/README.md`: "WASM tool ABI", "Sandbox", "Tool layout", "Tool catalog" | The `ck_*` host function table and what a tool descriptor can grant |
| `src/sandbox/host.zig` | The actual `ck_*` implementations: the real ceiling of what a WASM tool can do |
| `tools/zig/lib.zig` | Guest-side ABI: `scratch`/`host_arena`/`run`, `ck_*` imports |
| `src/tools/registry.zig` | How tools are discovered and dispatched |
| A few existing tools as reference shape: `tools/zig/git.zig`, `tools/zig/fetch_web.zig`, `tools/zig/roadmap.zig`, `tools/zig/write_note.zig`, `tools/zig/cmd_status.zig` | What a well-scoped tool already looks like here |

## Non-negotiable

- **No em dashes. No AI attribution.**
- **Trust boundary first, ergonomics second.** A candidate that scores well on
  "could be a tool" but fails the trust check (below) is still a **no**.
- **The protected surface never moves, and nothing in it gets easier to
  bypass.** Per AGENTS.md, clanker cannot modify `src/improve/`, `src/evals/`,
  `src/tools/builder.zig`, or `evals/` in a single pass. Do not propose moving
  logic out of those paths into a WASM tool that a later pass (or the agent
  itself) *could* modify: that would smuggle a bypass around the anti-cheat
  boundary. Gate/verification logic (`src/gate/checks.zig` included, even
  though it sits outside the protected paths) stays native for the same
  reason: a tool cannot be trusted to grade or gate its own promotion.
- **Match the existing tool shape.** New candidates should look like the
  tools already in `tools/manifests/`: one JSON in, one JSON out, a narrow
  `fs_prefixes`/`network_allow`, `internal: true` if the model should never
  pick it directly.
- **`zig build && zig build test && zig build tools` green** if you change code.

## Scope modes (user may pick one)

| Mode | Do |
|---|---|
| **Review only** | Verdict table + `docs/reviews/WASM_REVIEW.md`. No code. |
| **Review + propose** | Also sketch the descriptor (`fs_prefixes`, `network_allow`, `internal`) and the `ck_*` calls each move would need, without writing the tool. |
| **Review + implement top N** | Also write the WASM tool(s) and remove the native code path, gated behind `zig build tools` + `zig build test` passing. |

Default: **Review only** unless the user asks for code.

---

## What can a WASM tool actually do here

Everything a tool can touch is a `ck_*` host function in `src/sandbox/host.zig`,
gated by its descriptor:

| Host fn | Grants | Descriptor gate |
|---|---|---|
| `ck_fs_read` / `ck_fs_write` | Read/write inside `fs_prefixes` | `fs_prefixes` (empty = no filesystem at all) |
| `ck_http` | Outbound HTTP | `network_allow` (empty = no network at all) |
| `ck_exec` | Run a subprocess | Denies tokens outside an allowlist (see `host.zig`); still bounded, not arbitrary shell |
| `ck_docker` | Talk to the local Docker socket | `"docker"`-class tools only |
| `ck_llm` | One-shot model completion | `"llm": true` on the descriptor; forces sequential execution |
| `ck_subagent` | Nested bounded agent run | `modules.subagents` |
| `ck_getenv` | Read one env var | Always available, still logged |
| `ck_now`, `ck_random`, `ck_log`, `ck_config` | Time, randomness, logging, its own config | Always available |

If a candidate needs something **not** on this list (raw socket listen/accept,
spawning a long-lived OS thread, terminal raw-mode I/O, holding a mutable
struct across the whole agent run, controlling another WASM module's
lifecycle), it cannot move without first extending the `ck_*` ABI: treat that
as a **much bigger** proposal than moving one file, and say so explicitly
rather than hand-waving it as a normal candidate.

---

## Decision tree: native, or WASM tool?

Run this on every file/function in scope.

```text
1. Is it the sandbox itself, or does it define trust (loop.zig, sandbox/host.zig,
   sandbox/runtime.zig, tools/registry.zig, the ck_* boundary)?
   YES → native. STOP. (A tool cannot host the thing that runs tools.)

2. Is it under the protected surface (src/improve/, src/evals/,
   src/tools/builder.zig, evals/), or does it grade/gate a promotion
   (src/gate/checks.zig)?
   YES → native. STOP. (Anti-cheat boundary; a tool cannot verify or promote
   its own or anyone else's change.)

3. Does it need a capability with no ck_* equivalent (socket listen, thread
   spawn held across the run, raw terminal mode, direct stdin/stdout fd
   control for a REPL loop)?
   YES → native. STOP. (Extending the ABI is a separate, larger proposal:
   name what host fn would be needed, don't just say "no".)

4. Is it bounded, stateless (or state confined to one call), and expressible
   as "JSON in -> JSON out" using only ck_* capabilities above?
   NO → probably native; note what state/streaming makes it awkward.
   YES → continue.

5. Is there already a WASM tool doing the same job (or 80% of it) that this
   should extend instead of duplicating?
   YES → extend that tool's descriptor/config, don't add a second path.
   STOP.

6. Does moving it cross the model's tool catalog boundary: i.e. should the
   *model* ever be allowed to call this directly?
   NO, it's harness-internal only → still fine as a tool, just mark
   `"internal": true` (same pattern as `cmd_*`, `format`, `webui`).
   YES → make sure the descriptor's `fs_prefixes`/`network_allow` are the
   minimum the job needs, not "."/wildcard.

7. Would the move add marshalling/instantiation cost on a hot path (every
   agent-loop iteration, every streamed token)?
   YES → weigh it explicitly; a per-iteration WASM call may cost more than it
   saves. Prefer moving the parts that run once per *run*, not once per
   *token*.

8. Still unsure?
   Prefer leaving it native and naming the concrete blocker (missing ck_*
   fn, streaming/state coupling, trust). Do not move something "because the
   house style prefers it" without clearing steps 1-4.
```

### Quick scorecard (optional)

Score each candidate 0-2:

| Criterion | 0 | 1 | 2 |
|---|---|---|---|
| Trust / protected-surface risk | touches trust root | adjacent to it | fully outside |
| ck_* capability match | needs new host fn | needs config tweak only | already covered |
| State shape | run-long mutable state | call-scoped state | pure JSON in/out |
| Call frequency | per-token/hot loop | per-tool-call | per-run or rarer |
| Overlap with an existing tool | duplicates one | extends one | genuinely new |

**Sum ≥ 8:** move it. **5-7:** propose with caveats named. **≤ 4:** stays
native; say why in one line.

---

## Known starting candidates (seed the inventory, verify each: don't trust this list blindly)

| Path | Shape today | Lean |
|---|---|---|
| `src/peers/notify.zig` (`notifyAll`) | Fan-out `POST /api/notify` to configured peers over plain HTTP | **Move.** Same shape as `fetch_web`/`git`: bounded HTTP, no trust role. `network_allow` = configured peer hosts. |
| `src/patch/apply.zig` | Exact-match `old -> new` string replacement | **Move, carefully.** Pure logic, no privileged host access even needed: but it's called from `src/improve/engine.zig` (protected). Moving the *transform* is fine; the engine's decision to *apply and promote* stays native. Don't let the split blur who verifies the result. |
| `src/agent/autolearn.zig` | Reads/appends `state/autolearn.jsonl`, aggregates into roadmap suggestions | **Partial.** The read/aggregate side is the same shape as the existing `roadmap`/`history`/`learnings` tools (all fs-scoped readers): a natural sibling. The write-on-every-run hook inside `Agent.run`'s defer is call-frequency-sensitive (step 7); check whether it's cheap enough per run (not per token) before moving. |
| `src/agent/graph.zig` (`write`) | Serializes the execution graph to `state/runs/run-<id>.json` once per run | **Consider.** fs-write-only, once per run, low frequency: good shape. The graph *recording* (`g.add` calls threaded through the loop) stays native; only the final serialize-and-write is separable. |
| `src/gate/checks.zig` | Shells out to `zig build`/`zig build test`/`zig build tools`/`zig fmt`/lint | **Native. Do not move.** Explicitly outside the protected paths in its own doc comment, but it *is* the thing that decides whether a self-authored change gets promoted: moving it into a WASM tool would let a future change alter its own gate. Good worked "no" example. |
| `src/llm/client.zig`, `src/llm/providers.zig` | The actual provider HTTP/SSE client the agent loop runs on, holds API keys via env | **Native. Do not move.** This is what `ck_llm` is *built on top of* for tools: it's the trust root for model access, and `Agent.on_token` streaming is tightly coupled to it. If a tool needs model access, it already has `ck_llm`; it does not need this. |
| `src/sandbox/*`, `src/tools/registry.zig`, `src/tools/builder.zig` | The sandbox runtime and tool discovery/build pipeline | **Native. Do not move.** Defines what a WASM tool *is*; `builder.zig` is also explicitly protected. |
| `src/cli.zig` (REPL loop, HTTP `serve` accept loop, spinner threads) | Raw stdin read loop, `std.Io.net` listen/accept, `std.Thread.spawn` for the spinner | **Native. Do not move.** No `ck_*` equivalent for socket listen/accept, raw fd control, or a thread held across a whole interactive session. The parts of `cli.zig` that already dispatch to tools (`/`-prefixed REPL commands -> `cmd_*` WASM tools) are the right pattern to extend for *new* commands: don't reinvent that dispatch, use it. |

Verify each of these against the decision tree yourself; do not just copy the
"lean" column into the deliverable without checking current source, since the
codebase self-modifies (`clanker improve-self`) and these may have already
moved by the time you read this.

---

## Review procedure

### 1. Inventory

Walk `src/` (every `.zig` file, or the user-specified subset). For each
function/module that touches `ck_*`-shaped capabilities (fs, http, exec,
docker, llm) or is a bounded, callable unit:

| Path | What it does | ck_* capabilities needed | Call frequency |
|---|---|---|---|
| ... | ... | ... | per-run / per-tool-call / per-token / rare |

### 2. Score each (decision tree + scorecard)

Verdict per row: **move / move-with-caveats / stays native (name the
blocker)**.

### 3. Overlap check

```text
rg -n 'ck_http' src/                    # native code already doing what fetch_web/git-style tools do?
rg -n 'std.process.Child' src/          # native shelling out: compare to ck_exec-gated tools
rg -n 'readFileAlloc|writeFile' src/agent src/peers src/patch  # native fs work outside the sandbox
ls tools/manifests/*.tool.json | xargs -n1 basename   # what already exists, so you don't propose a duplicate
```

### 4. Protected-surface check

```text
rg -n 'src/improve/|src/evals/|src/tools/builder.zig' AGENTS.md
```

Confirm every "move" verdict is outside this set and outside anything that
grades/gates/promotes a change. If a candidate is adjacent (calls into or is
called by protected code), say so explicitly rather than silently including
or excluding it.

### 5. ABI-gap check

For any candidate that needs a capability not in the `ck_*` table above,
write the proposed host function signature and its trust implications
instead of just marking it "native": that's useful roadmap material even
though it's out of scope to implement here.

### 6. Deliverable (always)

Write or update **`docs/reviews/WASM_REVIEW.md`**:

- Scope and date
- Inventory table with verdicts
- Move-now list, with proposed tool name, descriptor sketch
  (`fs_prefixes`/`network_allow`/`internal`/`llm`), and which `ck_*` calls it needs
- Stays-native list, each with a one-line reason tied to the decision tree
  (trust root / protected surface / missing ck_* capability / hot-path cost)
- ABI gaps found (candidate + the host fn that would be needed)
- Explicit **do not move** list for anything that might look tempting but
  fails step 1-3

Plus a short chat note: top 3 move candidates, top reason nothing bigger
moved, whether `zig build tools && zig build test` ran.

---

## Worked examples (clanker-shaped)

### Good: bounded HTTP fan-out, no trust role

```text
src/peers/notify.zig: notifyAll() loops configured peers and POSTs JSON.
No different in shape from tools/zig/fetch_web.zig, which already does an
allowlisted HTTP GET. Move to tools/zig/notify.zig with
network_allow = peer hosts from config, fs_prefixes = [].
```

### Good: fs-scoped reader matching an existing pattern

```text
The read/aggregate half of src/agent/autolearn.zig is the same shape as the
already-shipped `history`/`roadmap`/`learnings` tools: read under state/,
return structured text. Natural sibling, not a stretch.
```

### Bad: moving the gate

```text
src/gate/checks.zig runs `zig build test` and decides pass/fail for
promoting a self-authored change. Moving this into tools/zig/gate.zig would
let a future patch that also touches tools/zig/ potentially influence the
thing that grades it. Native, and flag any PR that tries this as the review's
top-severity finding regardless of how "bounded" the code looks.
```

### Bad: moving the trust root because a thin wrapper "could" be JSON-in/JSON-out

```text
src/llm/client.zig technically takes a request struct and returns a response
struct: looks bounded. But it's what ck_llm calls on the agent's behalf, and
Agent.on_token streams straight out of it. Wrapping the wrapper doesn't
remove the trust dependency, it just adds a hop. Native.
```

### Bad: proposing a move that needs an ABI extension, without naming it

```text
"Move the REPL's spinner to a WASM tool": there is no ck_* for spawning a
thread that outlives one tool call, or for writing directly to the terminal
outside a tool's JSON-out result. Don't write "native, not currently
possible" and stop: name the missing primitive if it's worth having:
e.g. a hypothetical `ck_progress(text)` host fn a tool could call repeatedly
within one `run`, if a future tool genuinely needs a progress channel.
```

---

## Success criteria

- [ ] Every file in scope has a verdict and a one-line reason
- [ ] Every "move" verdict passed steps 1-4 of the decision tree explicitly
- [ ] Protected-surface and trust-root candidates are called out even when
      superficially "bounded" (gate/checks.zig and llm/client.zig are the
      canonical traps: check both by name)
- [ ] Overlap check run: no proposed tool duplicates an existing one in `tools/manifests/`
- [ ] ABI gaps (if any) come with a named host fn, not a vague "not possible"
- [ ] `docs/reviews/WASM_REVIEW.md` written
- [ ] If code changed: `zig build && zig build test && zig build tools` green
- [ ] No em dashes / AI attribution

---

## Optional user addenda

- "Review only `src/agent/` and `src/peers/`."
- "Skip the ABI-gap section, only report what's movable today."
- "Implement the top 1 move candidate as a real tool."
- "Also check `tools/ts/`: should any AssemblyScript tool logic move to
  Zig, or vice versa?" (separate axis from this review; note it but don't
  merge scope unless asked.)
