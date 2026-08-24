# RFC 0005: First-run onboarding

## Status

Decided, 2026-08-16. Choice recorded in
[ADR 0016](../adrs/0016-first-run-readiness-verdict.md).

## Overview

A new operator can build clanker, open Chat or the REPL, and still have no
path from "I have a binary" to "I have seen one successful turn." The pieces
exist (`init`, `setup`, `doctor`, `providers check`, four Chat chips) but they
do not share a definition of ready, they do not dismiss themselves, and the
chips assume this checkout is the clanker source tree.

This RFC scopes that first-run interval and picks how the surfaces share it.

**Decision to make.** What counts as first-run, when is it over, and which
option owns the shared "ready / blocked / next action" facts so CLI, REPL,
and Chat do not invent three setups?

**Why now.** Chat is a co-equal product surface (PRD 0006). Opening
`clanker serve` on any other folder still offers "Read src/agent/loop.zig".
The TUI first screen is a bare prompt ([delight-review](../prompts/delight-review.md)).
`clanker setup` is labelled "guided" and is a printout. A later wizard or
plugin tour will otherwise invent a second doctor.

**Drivers.**

- One definition of ready. `doctor`'s `runChecks` already owns the offline
  facts (config, keys present, tools wasm). Do not fork that list.
- Keys stay in the environment or a credential file. Never in
  `config.toml`, never pasted into a web form that writes them. `.env` is
  refused by `safeJoin`; a guest must name a secret on `env_allow`.
- First-run is an interval, not a view. After one successful turn it is
  gone. A later empty conversation is "New conversation", not onboarding.
- The composer always works. A blocked plate replaces suggestions, not the
  task box. Fail-open: if readiness cannot be computed, show the composer.
- Suggestions must be about *this folder*, not `src/agent/loop.zig`.
- No new rail tab and no product tour of Board, Mesh, Goals, or Improve.
  Those have their own empty states.
- No vendor account and no OAuth. We are multi-provider; Claude Code's
  browser login is not available to us.
- WASM-by-default applies to chrome, not to the verdict. A guest cannot
  see whether `DEEPSEEK_API_KEY` is set unless we grant it, and we must
  not. Readiness stays native.
- Do not add a fourth setup verb. `init` scaffolds, `setup` guides,
  `doctor` diagnoses, `providers check` talks to the network.

**Out of scope.** Mesh join and workspace enter (RFC 0001). Goal/card
attachments (RFC 0003). Knowledge uploads (ADR 0014). LLM I/O journal
(ADR 0015). Improve, plugins, skills authoring. Theme and mascot. Storing
API keys. Interactive `providers check` inside first-run (connectivity
stays a separate, network-using command). A webui_addon "Onboarding" app.

## Scope of the experience

First-run starts when this checkout has a clanker binary and has not yet
completed a successful agent turn. It ends when all three are true:

1. **Identity.** `config.local.toml` exists and has `instance.name` /
   `instance.id` (`clanker init` already writes both).
2. **Reach.** At least one configured provider can be used from this
   environment (env var set, credential file present, or a local runtime
   that needs no credential). The default provider is the one that
   matters; a usable non-default is a recovery hint, not ready.
3. **Tools.** Every registered manifest has its `.wasm` (`zig build tools`).
4. **First turn.** One agent turn has finished with content on any
   surface (`clanker run`, REPL, or Chat). That is the dismiss signal.

Until (4), every empty Chat / first REPL paint / `serve` banner may show
the next action. After (4), those plates do not mention setup again.

### The path

```
binary exists
    -> clanker setup          (init + verdict + doctor report)
    -> if blocked: name the one next action
         missing wasm     -> zig build tools
         default has no key -> export $api_key_env
                               or set default_provider to one that works
                               or point at a local runtime (ollama / vllm)
         config unreadable -> fix the TOML, then setup again
    -> open one surface (repl | serve Chat | clanker run "…")
    -> if still blocked: plate names the blocker; composer stays
    -> if ready: three or four folder-generic first tasks
    -> first successful turn -> plate gone for this checkout
```

`providers check` is *after* first-run, or an optional extra when the
operator wants proof the host answers. A missing key is an offline fact;
a 401 from a set key is not first-run.

### Surfaces in scope

| Surface | Today | First-run job |
|---|---|---|
| `clanker init` | Writes `config.local.toml` + `state/` | Keep. Identity only. |
| `clanker setup` | init + "which key works" + doctor | The CLI guide. Same verdict the others read. |
| `clanker doctor` | Read-only offline report | Unchanged. Source of the checks. |
| `clanker serve` | Prints the URL | If blocked, print the next action under the URL. |
| Web Chat empty | "New conversation" + four repo-specific chips | Blocked: next action. Ready: generic chips. After dismiss: today's empty plate. |
| TUI / `repl` | Bare prompt | One dim line when blocked or not yet dismissed. |
| `clanker run` | Fails with a provider error | Keep failing loudly; the error already names the provider. |

### Surfaces out of this RFC

Board empty, Rooms empty, Knowledge empty, Models, Fleet, Mesh plugin,
System Config, the Set up rail fold. Those are feature empty states, not
first-run.

## Current state

| Piece | What it does | Gap |
|---|---|---|
| README Quick start | `zig build`, `tools`, `test`, `init`, `gate`, `providers check`, `run` | A checklist, not a product path. Gate is not required to chat. |
| `cmdInit` | Writes `config.local.toml` from `local_template` (hard-codes `default_provider = "deepseek"`) and a friendly instance name | DeepSeek is the default even when another key is the only one set. |
| `cmdSetup` | Calls init, says whether the default has a credential, names one other provider that would work, runs `runChecks` | Not interactive. "Guided" is a label. Exit 1 on doctor failures. |
| `cmdDoctor` | Offline report: config, keys (names only), dirs, missing wasm | No JSON. Nothing Chat can fetch. |
| `GET /api/status` | instance, peers, worktree defaults | No ready/blocked. Chat already loads it (`loadStatus`). |
| Chat chips | Four hardcoded tasks in `app.js` `SUGGESTIONS`, hidden after the first turn in *that* conversation | Assume this is the clanker repo. Come back on every new chat. |
| Chat empty plate | "New conversation / Write a task or pick one below." | Same for first-run and the hundredth new chat. |
| TUI | No first-run hint | Flagged in delight-review. |
| `status` guest | Prints instance + peers from harness config | Identity only, same as `/api/status`. |

`setup` already contains the recovery sentence we need ("`X` does. Set
`default_provider = \"X\"` in `config.local.toml`"). It is stdout-only.

## Options considered

### Option A: One readiness verdict, three thin surfaces

- **What it is:** Factor `runChecks` into a structured verdict
  (`ready` / `blocked`, `blockers[{label, detail, next}]`,
  `usable_other_provider?`). `setup` and `doctor` print it as they do
  today. `GET /api/status` grows those fields (Chat already fetches it).
  Serve banner and REPL first paint print the first blocker's `next`.
  Chat empty state: blocked replaces the chips with that next action;
  ready shows folder-generic chips. First successful turn writes a small
  `state/onboarding.json` `{ "first_turn_at": <unix> }` so the plate
  does not return. Composer is never disabled.
- **Maturity:** the checks exist and have tests. `/api/status` is a
  live contract. A one-object state file matches `state/schedule.json`
  more than a new subsystem.
- **How it would fit:** `src/doctor.zig` grows a `Verdict` the CLI
  already builds as `Report`. `handleStatus` in `src/cli.zig` serialises
  it. `ui/app/app.js` branches the empty plate. REPL: one line in the
  TUI first paint. Serve: one extra print. No new command, no plugin,
  no guest grant for key names.
- **Pros:**
  - One list of checks. Chat cannot drift from doctor.
  - Hits the operator where they already look (empty Chat, serve URL).
  - Reversible: drop the extra `/api/status` fields and the state file.
- **Cons:**
  - `/api/status` grows a readiness meaning it did not have.
  - A dismiss file is a new state shape (tiny).
  - Serve start pays `runChecks` once (offline, cheap).
- **Cost to adopt:** factor verdict, three consumers, generic chips,
  one dismiss write, tests that the chips do not mention `src/agent`.
- **Cost to leave:** ignore the new fields; delete `state/onboarding.json`.
- **Evidence:** `src/doctor.zig` `runChecks` / `cmdSetup`;
  `handleStatus` at `GET /api/status`; `SUGGESTIONS` in `ui/app/app.js`;
  Chat already calls `loadStatus`.

### Option B: Interactive wizard (CLI and web)

- **What it is:** a multi-step flow: name the instance, pick a provider,
  collect a key, build tools, run a sample prompt. Closest to Claude
  Code / Continue first launch (browser login or paste a key, then a
  session).
- **Maturity:** those products are single-vendor or have an account.
  We do not.
- **How it would fit:** new CLI interactive prompts (stdin) plus a
  Chat or System modal. Writing a key means a new `.env` writer in the
  host, or putting secrets in `config.local.toml` (forbidden). A web
  form that accepts a key is a new credential surface with no sandbox.
- **Pros:**
  - Familiar. A stranger is walked, not briefed.
  - Can change `default_provider` away from the DeepSeek template.
- **Cons:**
  - Fights the key policy. The wizard's only honest write is
    `default_provider` plus "export this var in your shell."
  - Interactive stdin is a poor fit for `clanker run` and for serve.
  - A modal in Chat traps people who already have keys.
  - Large relative to the gap.
- **Cost to adopt:** new TUI/web flow, env-file policy review, e2e.
- **Cost to leave:** delete the flow; keys already in the environment stay.
- **Evidence:** Continue CLI first run asks for a Continue login or an
  Anthropic key ([docs](https://docs.continue.dev/cli/quickstart),
  unverified beyond the published page). Claude Code opens a browser
  OAuth on first `claude` ([quickstart](https://code.claude.com/docs/en/quickstart)).
  OpenHands CLI "guides you through LLM and agent configuration on
  first run" (survey claim, unverified). None of those are multi-provider
  env-var setups.

### Option C: Status quo

- **What it is:** keep README + `init` / `setup` / `doctor` / four
  repo-specific chips / blank REPL.
- **Pros:**
  - Zero work. Operators of this repo already have keys and wasm.
- **Cons:**
  - Chat on any other folder lies about what to try first.
  - `setup` is not where serve users look.
  - The TUI still says nothing.
  - The next person who "adds onboarding" will invent a wizard.
- **Cost to adopt:** zero now. Cost later is a forked setup.
- **Evidence:** current `SUGGESTIONS`, `cmdSetup`, delight-review
  first-impressions item.

### Option D: Out of the box: retarget chips, print doctor, no new contract

- **What it is:** keep doctor's text and `setup` as the only verdict.
  Change the four Chat chips to folder-generic prompts. `serve` and
  `repl` print doctor's last line when `failures > 0`. No `/api/status`
  change, no dismiss file. Every new Chat still shows the chips.
- **Maturity:** all of this is already in-tree. A copy change plus two
  print sites.
- **How it would fit:** `ui/app/app.js` `SUGGESTIONS`; a `runChecks`
  call at serve start and REPL entry (doctor already does this).
- **Pros:**
  - Smallest change. Uses `doctor` as it stands.
  - Fixes the worst lie (repo-specific chips) immediately.
- **Cons:**
  - Chat still cannot see "DeepSeek has no key, Moonshot does."
    The operator clicks a chip and gets a provider error toast.
  - No dismiss: chips return on every new conversation forever.
  - Serve users who never run `setup` still only see a URL plus a
    doctor line they may not connect to the empty Chat.
- **Cost to adopt:** an afternoon.
- **Cost to leave:** revert the chip strings and the two prints.
- **Evidence:** `SUGGESTIONS` is four string literals; `cmdSetup`
  already formats the "X does" sentence.

## Implications by horizon

### Short term (this release / 0–3 months)

- **If A:** empty Chat tells the truth; REPL and serve name the next
  action; chips stop mentioning `src/agent`. First turn dismisses it.
- **If B:** a wizard ships, and the key-policy review is the critical
  path. Likely slips.
- **If status quo:** another repo clone still sees loop.zig.
- **If D:** chips are honest; Chat still cannot recover a missing key
  without leaving the page.

### Medium term (3–12 months)

- **If A:** Models / System Config can reuse the same verdict ("this
  provider is the default and has no key") instead of growing a second
  check. `local_template`'s DeepSeek default becomes a smaller footgun
  because the plate names the other usable provider.
- **If B:** the wizard becomes the place people expect every new
  setting to land (instance, mesh, worktree). Scope creeps.
- **If status quo / D:** a plugin "onboarding" app appears and forks
  doctor.

### Long term (12+ months)

- **If A:** first-run stays a verdict plus empty plates. New surfaces
  subscribe or they do not.
- **If B:** we own a credential-collection UX we spent the rest of the
  project refusing.
- **If status quo / D:** first-run remains folklore in the README.

## Recommendation

**Recommended option:** A (one readiness verdict, three thin surfaces).
Ship D's chip rewrite as the first patch of A, not as a substitute.

**Confidence:** 7/10

**Why this confidence.** The checks, the Chat fetch, and the recovery
sentence already exist; A is assembly, not invention. What is not
measured: whether a stranger dismisses after one turn or wanted a
"next: open the board" beat. A finding that operators ignore the plate
and still paste keys into System Config would drop this below 5 and
reopen B's `default_provider` step only (still no key paste). Evidence
that first-run is only ever this repo (chips are fine) would drop A
to D.

**Rationale.** D fixes the lying chips and leaves the actual failure
(default provider has no credential, another one does) as a toast after
the operator has already committed a turn. That is the first-run
failure `setup` already diagnoses. B solves it by collecting secrets,
which our sandbox and config rules exist to prevent. A puts setup's
sentence on the plate the serve user already sees, without a new verb
or a new tab.

**Reversibility.** Easy until clients depend on the new `/api/status`
fields. The dismiss file is optional to honour: delete it and first-run
returns. Point of no return is documenting `ready` / `blockers` as a
stable HTTP field; keep them additive and omit-when-absent so old
pages ignore them.

## Open questions

- **Dismiss signal.** One successful turn (model returned content)
  plus a quiet skip. *Confirmed in ADR 0016.*
- **Does `local_template` stay DeepSeek?** A does not have to change
  it. Changing the default is a separate config RFC. The plate must
  work either way. *Answerable by:* whoever owns `default_provider`
  in the committed `config.toml`.
- **Does a failed turn (401, missing wasm mid-run) count?** No.
  Success means the model returned content. *Confirmed in ADR 0016.*
- **Should serve refuse to start when blocked?** No. The URL is how
  they see the plate. *Closed here; confirmed in ADR 0016.*

## Next steps / action items

- [ ] If accepted: extract `Verdict` from `runChecks` with unit tests
      on the DeepSeek-unset / other-key-set case `setup` already prints.
- [ ] Add additive `ready` / `blockers` to `GET /api/status`.
- [ ] Chat empty plate branches; replace `SUGGESTIONS` with folder-generic
      tasks; never mention `src/agent`.
- [ ] REPL first paint and serve banner: first blocker's `next`.
- [ ] Write `state/onboarding.json` after the first successful turn
      (CLI, REPL, and `/api/run` share the write).
- [ ] Tests: chips are generic; `/api/status` omits blockers when ready;
      dismiss stops the plate; composer stays enabled when blocked.
- [x] Write the ADR once the decision is made.

## References

- [ADR 0016: First-run is one doctor verdict on existing empty surfaces](../adrs/0016-first-run-readiness-verdict.md)
- `src/doctor.zig` (`cmdSetup`, `cmdDoctor`, `runChecks`)
- `src/cli.zig` `cmdInit`, `local_template`, `handleStatus`
- `ui/app/app.js` `SUGGESTIONS`, `loadStatus`, `syncTranscriptEmpty`
- [PRD 0006](../prds/0006-webui.md) (Chat is a co-equal surface)
- [delight-review](../prompts/delight-review.md) (TUI first screen)
- RFC 0001 (workspace/room/board: not first-run)
- Continue CLI first run (login or Anthropic key):
  https://docs.continue.dev/cli/quickstart
- Claude Code first run (browser OAuth):
  https://code.claude.com/docs/en/quickstart

## Appendix

### Suggested first-turn chips (when ready, not yet dismissed)

These are the replacements for today's four. They must make sense in any
folder, including one with no `src/`.

- Summarise what this folder is, in five sentences.
- List the tools you have and what each one is for.
- What files should I read first to work here?
- What did the last recorded run do?

The last one is empty-safe: if there is no run, the model says so.

### What the blocked plate says (examples)

- Default provider `deepseek` has no `DEEPSEEK_API_KEY`. `moonshotai`
  does. Set `default_provider = "moonshotai"` in `config.local.toml`.
- 12 compiled tool modules are missing. Run `zig build tools`.
- `config.toml` is missing. Run `clanker setup` from the checkout.

One blocker at a time, the same order doctor already uses (config,
then keys, then dirs, then wasm).
