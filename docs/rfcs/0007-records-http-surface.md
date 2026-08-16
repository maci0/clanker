# RFC 0007 — HTTP surface for the five record-store tools

## Status

Decided — 2026-08-16. Decided as ADR 0019 — Record stores are exposed over HTTP as one relay endpoint per tool.

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

Every web UI view is backed by an /api/ endpoint, and no docs/ record store has one, which is the only reason reports, RFCs, ADRs, PRDs and research notes cannot get a view. The five stores already have guests (reports, rfc, adr, prd, research) whose input_schema is an action plus fields. What has to be decided before writing any handler: whether HTTP relays writes at all or only reads, and what the URL and status vocabulary is.

**Decision to make.** Which HTTP shape do we adopt for the five record-store
guests — how much of each guest's action set a request may reach, and by which
URL and method?

**Why now.** A web UI view for the record stores is blocked on it. Every
existing view (chat, sessions, board, schedule, skills, search) is a thin
client over an `/api/` endpoint; the six `docs/` stores have no endpoint at
all, so a view for them has nothing to call. Writing the view first would
force the shape by accident, and the shape is the part that is expensive to
change once a plugin depends on it.

**Drivers.**

- The guest stays the single implementation. `reports`, `rfc`, `adr`, `prd`
  and `research` already own path policy, the inventory-README second copy of
  every status, and the compare-and-swap writes. A handler that re-derives
  any of that in `src/` is a second implementation that will drift.
- One vocabulary across CLI, agent and HTTP. The `input_schema` field names
  (`action`, `path`, `old`, `new`, `status`, `note`, …) are what the agent
  already sends; a third naming scheme for HTTP is a translation table
  nobody maintains.
- Compare-and-swap has to survive the trip. A concurrent edit must reach the
  caller as a refusal that tells them to re-open and retry — never a silent
  overwrite, and never a 500.
- HTTP method semantics. A GET must not mutate a record: it is what a browser
  prefetches, a crawler follows, and a `<img src>` can forge.
- No new sandbox surface. Whatever the shape, `src/` must not read or write
  `docs/` directly; the guest's `fs_prefixes` stay the only path policy.

**Out of scope.** The web UI view itself, which is a follow-up built with the
`webui_addon` tool under `ui/plugins/`. Also out of scope: any change to the
guests, their schemas, or their storage layout.

## Current state

Five guests, five CLI verbs, no HTTP. `clanker reports`, `clanker rfc`,
`clanker adr`, `clanker prd` and `clanker research` in `src/cli.zig` reach the
guests through `toolJson`, and the agent reaches the same guests through the
tool catalog. `cli.zig`'s HTTP router has no `/api/reports`, `/api/rfc`,
`/api/adr`, `/api/prd` or `/api/research` arm, and the 404 fallthrough answers
all five.

The relay machinery a decision here would use already exists and is what
`handleLogs` and `handleSessions` are built from: `requestPath` strips the
query before an id is read off the target, `toolJson` runs the guest,
`toolResultFailed` detects a refusal, `toolRefusalStatus` maps `no such` /
`not found` to 404 and every other refusal to 400, `respondTool` writes a
refusal, and `respondCompressible` writes a success. `skillsRouteToToolInput`
is the closest precedent for the piece that would be new: a pure
`(method, target, body) -> guest JSON` function, unit-tested beside the
handler.

Nothing in `config.Modules` covers documentation records. `/api/skills`,
`/api/logs`, `/api/knowledge` and `/api/prompts` — the closest neighbours —
are ungated, while `/api/sessions` is gated because `modules.sessions` exists
for the session store as a whole, not for its endpoint.

## Options considered

Five options, all of them buildable today; the differences are in what the URL
promises and how much of the guest a request can reach.

### Option A — Method-split relay, one endpoint per tool

- **What it is:** one route per guest — `/api/reports`, `/api/rfc`,
  `/api/adr`, `/api/prd`, `/api/research` — carrying the guest's own field
  names. `GET` accepts only the read actions (`list`, `search`, `open`,
  and `checklist` where the guest has one) with the fields in the query
  string; `POST` accepts only the write actions (`create`, `append`,
  `update`, `status`, and `recommend` on the RFC guest) with the guest's
  input object as the JSON body. Anything else is refused before the guest
  runs.
- **Maturity:** the mechanism is what `handleLogs`, `handleSkills` and
  `handleFeedback` already do; nothing new is introduced.
- **How it would fit:** one pure `(method, target, body) -> guest JSON`
  function per store in `src/cli.zig` (the `skillsRouteToToolInput` shape),
  one thin handler each, five router arms. No guest change, no descriptor
  change, no config change.
- **Pros:**
  - The action allowlist per method is explicit and testable without a
    server: a GET that names `create` is refused by a pure function.
  - One vocabulary. What the agent sends, the CLI sends, and a browser
    sends are the same field names, so the tool's `input_schema` stays the
    only documentation of the request.
  - New guest actions reach HTTP by adding a name to one allowlist, not by
    designing a URL.
  - Compare-and-swap needs nothing: the guest's refusal is already the
    right answer, and `toolRefusalStatus` already maps it to 400.
- **Cons:**
  - Not REST-shaped. `GET /api/rfc?action=open&path=…` is a remote
    procedure call wearing a URL, and a record has no addressable URL of
    its own.
  - Query-string encoding of a long `query` is clumsier than a JSON body.
- **Cost to adopt:** five handlers plus five route arms, mechanical after
  the first.
- **Cost to leave:** low while only clanker's own UI calls it; it becomes a
  public API the moment a plugin does.
- **Evidence:** `src/cli.zig` `handleSkills` / `skillsRouteToToolInput`
  (verified in tree); the five `tools/manifests/*.tool.json` schemas
  (verified).

### Option B — Resource-style REST per store

- **What it is:** `GET /api/rfc` lists, `GET /api/rfc/<path>` opens one
  record, `GET /api/rfc/search?q=` searches, `POST /api/rfc` creates,
  `POST /api/rfc/<path>/append`, `POST /api/rfc/<path>/status`. The handler
  translates each URL into the guest's `action` and fields.
- **Maturity:** the shape `/api/sessions` uses for its id routes.
- **How it would fit:** the same relay call, but with a per-store URL
  grammar and a percent-decode of a `docs/rfcs/0007-….md` path segment
  inside the URL.
- **Pros:**
  - Each record gets a real URL, which is what a link, a bookmark and an
    HTTP cache want.
  - Reads and writes are separated by the URL as well as the method.
- **Cons:**
  - A record id *is* a path with slashes and a `.md` suffix, so every id
    route needs percent-decoding and a traversal check — a second path
    policy beside the guest's `fs_prefixes`, which is exactly the drift the
    plugin boundary exists to prevent.
  - The translation table is per store and grows with every new action.
  - `checklist` and `recommend` have no resource shape and end up as verbs
    anyway.
- **Cost to adopt:** meaningfully more than A, most of it in id parsing and
  its tests.
- **Cost to leave:** higher; the URLs are the API.
- **Evidence:** `handleSessions`'s id branch (verified in tree) is ~120
  lines of exactly this parsing for ids that are *not* even paths.

### Option C — Reads relay, writes stay native

- **What it is:** `GET` relays the guest; `create`, `append`, `update` and
  `status` are implemented natively in `src/`, the way `/api/sessions`
  relays the `sessions` guest for its listing but keeps mutations native.
- **Maturity:** live precedent in tree.
- **How it would fit:** five read handlers plus native write code that
  re-implements record scaffolding, numbering, the inventory-README second
  copy of every status, and compare-and-swap.
- **Pros:**
  - Follows the one existing precedent for a store with both reads and
    writes.
  - A native writer can do things a guest cannot, such as touching a path
    outside the descriptor's `fs_prefixes`.
- **Cons:**
  - It is the second implementation, and the stores are precisely where
    that already burned us: `create` writing the inventory copy once and
    never again is why `docs/reports/` records read `Open` months after
    they were fixed. Two writers double that class of bug.
  - The reason `/api/sessions` keeps mutations native does not transfer:
    sessions mutations are branch/fork/compact over live transcript state,
    not text edits to a file the guest already owns.
  - `src/` would read and write `docs/`, which the sandbox boundary exists
    to prevent.
- **Cost to adopt:** highest of the five.
- **Cost to leave:** the native writer is deletable, but any divergence it
  introduced in the records is not.
- **Evidence:** `handleSessions` (verified); bug
  `docs/reports/bugs/2026-08-16-reports-status-leaves-the-tldr-saying-open.md`
  and the inventory-desync fix in the TODO board's Done list (verified).

### Option D — status quo, no HTTP surface

- **What it is:** keep doing what we do today — records are reachable from
  the CLI and the agent only.
- **Pros:**
  - Zero code, zero API surface to keep compatible.
  - The agent can already read and write every store, so nothing an
    operator wants is impossible; it is only manual.
- **Cons:**
  - The record-store view stays impossible, which is the whole point.
  - It quietly pushes anyone who wants records in a browser toward the
    thing we do not want: a plugin that shells out or re-reads `docs/`
    itself.
- **Cost to adopt:** zero now. Later it costs the view, and every ad-hoc
  workaround built in its absence.
- **Evidence:** the router's 404 fallthrough in `src/cli.zig` (verified).

### Option E — out of the box: one generic tool-relay endpoint

- **What it is:** no per-store routes at all. `POST /api/tools/<name>`
  relays any non-`internal` tool's JSON verbatim to that guest, and the
  five stores come along for free with everything else in the catalog.
- **Maturity:** nothing like it in tree; MCP (`src/mcp/`) is the same idea
  over a different transport and is already shipped, which is evidence the
  generic surface is useful — and evidence it already exists.
- **How it would fit:** one handler, one route, no per-store code ever
  again.
- **Pros:**
  - Smallest possible code, and every future guest is reachable the day it
    lands.
  - Genuinely one vocabulary, because there is no translation at all.
- **Cons:**
  - It hands the network the whole tool catalog through one route, so the
    endpoint's blast radius is every guest including `exec`, `git` and
    `file_ops`. The sandbox limits what each guest may do, but the choice
    of which guest runs would move from the harness to the caller.
  - Every call is a `POST`, so reads lose HTTP caching and the safe-method
    guarantee.
  - `clanker mcp` already covers "expose the catalog over a protocol", and
    it is the surface built for it.
- **Cost to adopt:** lowest.
- **Cost to leave:** hard — it is a universal API; anything could depend on
  any part of it.
- **Evidence:** `src/mcp/` (verified in tree); `internal` descriptor flag in
  `docs/manifest.md` (verified).

## Implications by horizon

A and B unblock the view equally well and differ almost entirely in the medium
term, once actions are added and a plugin has started depending on the URLs.
That is the deciding horizon.

### Short term (this release / 0–3 months)

- **If A:** five handlers, five pure route functions with unit tests, and an
  e2e journey per verb family. The view becomes buildable.
- **If B:** the same, plus per-store URL grammar and id percent-decoding, and
  the tests that a traversal attempt is refused.
- **If C:** reads land quickly; the native writers are the bulk of the work and
  the records gain a second writer immediately.
- **If D (status quo):** nothing changes and the view stays blocked.
- **If E:** one handler lands in an afternoon and every guest is on the
  network.

### Medium term (3–12 months)

- **If A:** a new guest action is one name in one allowlist. The URLs stay
  five; a record still has no address, so a UI that wants to deep-link to one
  record links by query string.
- **If B:** each new action needs a URL decision, and the id parser is a
  standing traversal-review obligation. Deep links work properly.
- **If C:** the native writers and the guests drift on the first schema change
  or the first new store, and the inventory copy of status is the field most
  likely to diverge, because it is the one that already did.
- **If D:** pressure builds for a plugin that reads `docs/` directly, which is
  the outcome the plugin boundary exists to prevent.
- **If E:** the generic route is depended on by things we did not anticipate,
  and narrowing it later is a breaking change.

### Long term (12+ months)

- **If A:** the surface is as stable as the guests' schemas, which are the
  thing we already maintain. Migrating to B later is possible by adding id
  routes beside the query form.
- **If B:** stable and conventional, at the cost of a URL grammar per store
  forever.
- **If C:** the second implementation is now load-bearing and expensive to
  delete.
- **If D:** the record stores are the only part of the system a browser cannot
  see.
- **If E:** the tool catalog is a public API, and `clanker mcp` and this
  endpoint are two answers to one question.

## Recommendation

**Recommended option:** Option A — a method-split relay, one endpoint per tool: GET carries only the read actions (list, search, open, checklist) in the query string, POST carries only the write actions (create, append, update, status, recommend) as the guest's own input object, and both go straight to the guest through toolJson.


**Confidence:** 8/10

**Why this confidence.** It rests on two verified facts: the relay machinery already exists and is exercised by `handleLogs`, `handleSkills` and `handleFeedback`, and the five guests already own every piece of policy a handler would otherwise re-derive. It is 8 and not 10 because the deferred view has not been written, so the deep-link question is answered by argument rather than by use. A first draft of that plugin needing stable per-record URLs would raise B and lower this to about 6 — though not sink it, since id routes can be added later. What would sink it outright is discovering a store action that cannot be expressed as a query string without losing fidelity on a read, which would mean reads need a body and the method split buys nothing.


**Rationale.** Against the drivers, A wins on the one that matters most and loses nothing the view needs. It keeps the guest as the single implementation with no translation table, so the tools' input_schema stays the only description of a request; compare-and-swap and the inventory-README copy of every status keep working because no second writer exists. B, the runner-up, buys per-record URLs at the price of a second path policy in src/ — percent-decoding a docs/rfcs/0007-....md id and traversal-checking it beside the guest's own fs_prefixes — which is the drift the plugin boundary exists to prevent, and the deep-link benefit is speculative until the deferred view asks for it. C is disqualified by the record stores' own history: the inventory copy of status diverging is a bug we have already filed, and a native writer doubles that surface. E is smaller than all of them but puts the whole tool catalog behind one route, which clanker mcp already does deliberately and with a protocol. The trade-off accepted is that a record has no URL of its own; the mitigation is that id routes can be added beside the query form without changing the relay or breaking a caller.


**Reversibility.** Easy while clanker's own UI is the only caller: deleting five router arms and five handlers removes the surface with no data migration, because nothing is stored and no record format changes. The point of no return is the first third-party plugin that calls these URLs — from then on the query-string vocabulary is a public API, and the mitigation is that it is the guests' own `input_schema`, which we already keep stable for the agent.

## Open questions

- **Does the view need a per-record URL?** If the follow-up plugin wants
  deep links that survive a reload, A needs a query-string link
  (`#records?store=rfc&path=…`) where B would have given a real one. The
  plugin's first draft answers it, and the answer does not change the
  relay — id routes can be added beside the query form.
- **Should `research sweep` be reachable over HTTP?** It performs network
  egress and can take tens of seconds, unlike every other action here. It is
  a write-shaped read, and this RFC recommends leaving it off the surface
  until something asks for it; `clanker research sweep` and the agent still
  have it.
- **Does anything need authentication before this ships?** `clanker serve`
  binds loopback by default and no existing `/api/` endpoint authenticates,
  so these endpoints are exactly as exposed as `/api/config` already is. If
  that changes, it changes for the whole server, not for these five routes.

## Next steps / action items

- [x] Write the ADR recording the decision, linking this RFC.
- [x] Write the PRD for the feature, naming the deferred view explicitly.
- [x] Implement the five handlers and their route arms, test-first.
- [ ] Build the record-store view as a `webui_addon` plugin under
      `ui/plugins/`, and answer the deep-link question above from it.

## References



- [ADR 0004 — Providers are a native vtable, not WASM](../adrs/0004-providers-are-a-native-vtable-not-wasm.md):
  the standing test for when native code is allowed instead of a guest
  (credentials on the hot path). Neither test applies to a record store, which
  is why Option C fails it.
- [ADR 0018](../adrs/) and [PRD 0037](../prds/): the `adr` and `prd` guests and
  their CLI verbs, the surfaces this RFC extends to HTTP.
- [docs/manifest.md](../manifest.md): every descriptor field, including
  `internal` and `fs_prefixes`, which bound what Options A and E can reach.
- [docs/README.md](../README.md): the store taxonomy these endpoints serve, and
  which tool maintains each store.
- `src/cli.zig` — `handleLogs`, `handleSkills`, `skillsRouteToToolInput`,
  `handleSessions`, `requestPath`, `toolRefusalStatus`: the relay machinery
  every option above reuses.

## Appendix

Optional: benchmark output, diagrams, licence texts, transcript excerpts, and
anything else too long for the body but needed to re-check the reasoning.
