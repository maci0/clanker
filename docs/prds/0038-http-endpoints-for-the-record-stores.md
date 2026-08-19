# PRD — HTTP endpoints for the record stores

## Status

Shipped — 2026-08-16. src/cli.zig is the source of truth: RecordStore, recordsRouteToToolInput and handleRecords, routed from the /api/ dispatch; the record logic stays in tools/zig/{reports,rfc,adr,prd,research}.zig. Covered by the recordsRouteToToolInput unit test and tests/e2e/records_api_test.zig. The web UI view over these endpoints is deferred (see Non-goals).

Implements [ADR 0019](../adrs/0019-record-stores-are-exposed-over-http-as-one-relay-endpoint.md), decided from [RFC 0007](../rfcs/0007-records-http-surface.md).

The record logic is not here and never will be: the source of truth for every
store stays its guest — `tools/zig/reports.zig`, `rfc.zig`, `adr.zig`,
`prd.zig`, `research.zig` with their `tools/manifests/*.tool.json`
descriptors. What this PRD adds is one HTTP route per guest in `src/cli.zig`,
exposed by `clanker serve`, alongside the CLI verbs (`clanker reports`,
`clanker rfc`, `clanker adr`, `clanker prd`, `clanker research`) and the agent
tool catalog that already call the same guests.

The web UI view over these endpoints is deliberately **not** part of this PRD.
See Non-goals: it was deferred, not forgotten.

## Problem

The six docs/ record stores are the only part of clanker a browser cannot see. Every web UI view — chat, sessions, board, schedule, skills, search — is a thin client over an /api/ endpoint, and reports, runbooks, RFCs, ADRs, PRDs and research notes have none, so a view for them has nothing to call. An operator who wants to read a bug report or move an RFC to decided has to leave the UI for a terminal, and the records that are supposed to be the shared memory of the project are reachable only by whoever has a shell.

The constraints that shaped the design: the five guests (reports, rfc, adr, prd, research) already own path policy, record scaffolding and numbering, the second copy of every status in each store's README inventory, and compare-and-swap writes, so any HTTP surface has to relay to them rather than re-derive that in src/ — the stores have already produced one inventory-desync bug and a second writer would double that surface. A GET must not mutate a record, because it is what a browser prefetches and a crawler follows. And the request vocabulary has to stay the guests' own input_schema, so the tool descriptor remains the single description of a request across CLI, agent and HTTP. ADR 0019 records the choice this PRD implements.

## Goals

1. Five endpoints exist and relay to their guest: GET and POST on /api/reports, /api/rfc, /api/adr, /api/prd and /api/research, each reaching the tool of the same name through toolJson, with no record logic in src/ and no read or write of docs/ from src/.
2. GET serves the read actions only — list, search, open, and checklist where the guest has one — taking its fields from the query string under the guest's own field names.
3. POST serves the write actions only — create, append, update, status, and recommend on the RFC guest — taking the guest's input object verbatim as the JSON body.
4. A read action named on POST, or a write action named on GET, is refused before the guest runs, so no request can mutate a record through a safe method.
5. Refusals reach the caller with the neighbouring endpoints' status mapping: a "no such"/"not found" refusal is 404, every other refusal is 400, and a guest that will not load is 500.
6. A compare-and-swap conflict reaches the caller as the guest's own refusal telling them to re-open and retry — never a silent overwrite, and never a 500.
7. Each endpoint is gated the way its neighbours are: no new modules flag, because none of /api/skills, /api/logs, /api/knowledge or /api/prompts has one and config.Modules has no documentation-records flag to reuse.

## Non-goals

**The web UI view.** Deferred, not forgotten. A record-store view is a separate
follow-up built with the `webui_addon` tool as a drop-in plugin under
`ui/plugins/<name>/`, never by editing `ui/app/`. It was split off because the
endpoints are what unblocks it, and because the view's first draft is what
answers the one open question below (whether records need per-record URLs).
Nothing in this PRD is complete only when the view exists.

**`research sweep` over HTTP.** The one guest action deliberately left off both
methods. It performs network egress to eight hosts and can take tens of
seconds, which is a different operational shape from every other action here —
and no caller has asked for it. `clanker research sweep` and the agent still
have it. Leaving it out is a feature: it keeps every endpoint in this PRD fast,
local and side-effect-free apart from the record it writes.

**Per-record REST URLs.** `GET /api/rfc/docs/rfcs/0007-….md` is not offered. A
record id is a path with slashes and a `.md` suffix, so an id route needs
percent-decoding and a traversal check in `src/` — a second path policy beside
the guest's own `fs_prefixes`, which is the drift the plugin boundary exists to
prevent. RFC 0007 Option B has the full argument. Id routes can be added later
beside the query form without breaking a caller.

**Authentication.** Not added here. No existing `/api/` endpoint authenticates
and `clanker serve` binds loopback by default, so these five are exactly as
exposed as `/api/config` already is. If that changes it changes for the whole
server, not for these routes.

**Any change to the guests.** No new action, no schema change, no storage
change. If an endpoint needs something the guest does not do, that is a change
to the guest, in its own record.

## Design

**One endpoint per tool, not per store.** There are six stores but five tools —
`reports` covers both `docs/reports/` and `docs/runbooks/`. Following the tools
keeps the API and the guests one-to-one, so a route is never a place where two
stores have to be told apart.

**The method decides which actions are reachable.** The endpoint sends an
explicit `action` on every call, so the guest's own default action never
applies over HTTP (this matters for `research`, whose default is `plan`, not
`list`). An action outside the method's set is refused before the guest runs.

| Endpoint | Tool | Store(s) | GET actions | POST actions |
|---|---|---|---|---|
| `/api/reports` | `reports` | `docs/reports/`, `docs/runbooks/` | `list`, `search`, `open` | `create`, `append`, `update`, `status` |
| `/api/rfc` | `rfc` | `docs/rfcs/` | `list`, `search`, `open`, `checklist` | `create`, `append`, `update`, `recommend`, `status` |
| `/api/adr` | `adr` | `docs/adrs/` | `list`, `search`, `open` | `create`, `append`, `update`, `status` |
| `/api/prd` | `prd` | `docs/prds/` | `list`, `search`, `open`, `checklist` | `create`, `append`, `update`, `status` |
| `/api/research` | `research` | `docs/research/` | `list`, `search`, `open`, `plan` | `create`, `append`, `update`, `status` |

`plan` is a GET because it is pure: `tools/zig/research.zig` `plan` builds
search angles from the topic and makes no network call. `sweep` is the one
action on neither method (see Non-goals).

**Request shape is the guest's own `input_schema`.** There is no translation
table, because a third naming scheme is a table nobody maintains.

- **GET** takes its fields from the query string: every parameter becomes a
  string field on the guest input, percent-decoded, under the name the schema
  already uses (`query`, `path`, `kind`, `topic`, `depth`, …). `action`
  defaults to `list` when absent, so `GET /api/rfc` is the natural listing
  call. Read actions take only string fields today, which is what makes the
  query string sufficient.
- **POST** takes the guest's input object verbatim as the JSON body, so a
  write sends exactly what the agent would send. An explicit `action` is
  required: a body with none is refused rather than falling through to a
  guest default that might be a read.

**Responses are the guest's output, relayed.** `toolJson` runs the guest;
`toolResultFailed` detects a refusal; `respondTool` maps it through
`toolRefusalStatus` — `no such …` / `not found` to 404, every other refusal to
400 — and a success goes out through `respondCompressible`. The handler never
rewrites a guest's JSON, so what a browser sees is what the CLI prints.

**Compare-and-swap survives unchanged, because nothing was added to preserve
it.** All five stores write compare-and-swap: `append`, `update`, `status` and
`recommend` refuse when the record moved under them. That refusal is a normal
`{"ok":false,...}` body naming the conflict, so it reaches the caller as a 400
with the guest's own "re-open and retry" wording. There is no native write path
that could overwrite instead, and no exception mapping that could turn it into
a 500.

**Gating: no new flag.** `config.Modules` has no documentation-records flag,
and the closest neighbours — `/api/skills`, `/api/logs`, `/api/knowledge`,
`/api/prompts` — are ungated. `/api/sessions` is gated only because
`modules.sessions` exists for the session store as a whole. Adding a flag here
would be a new operator concept for a surface that has no operational cost when
idle.

**Dependencies.**

- [ADR 0019](../adrs/0019-record-stores-are-exposed-over-http-as-one-relay-endpoint.md)
  (hard): the decision this implements, from
  [RFC 0007](../rfcs/0007-records-http-surface.md).
- The five guests and descriptors (hard): `tools/zig/{reports,rfc,adr,prd,research}.zig`
  and `tools/manifests/{reports,rfc,adr,prd,research}.tool.json`. Their
  `fs_prefixes` stay the only path policy.
- `src/cli.zig` relay machinery (hard): `toolJson`, `toolResultFailed`,
  `toolRefusalStatus`, `respondTool`, `respondCompressible`, `queryParam`,
  `percentDecode`. Not `requestPath`: no record id is read off the path, and
  the router matches against the already query-stripped `path`.
- [PRD 0037](0037-decision-and-spec-stores-on-the-cli.md) (soft): added the `adr` and
  `prd` guests and CLI verbs; this extends the same guests to HTTP.
- `handleSkills` / `skillsRouteToToolInput` in `src/cli.zig` (soft): the
  pattern the pure route function copies.

**Implementation.**

1. `src/cli.zig` — the pure route function and its unit tests: a
   `RecordStore` enum, its per-method action sets, and
   `recordsRouteToToolInput(arena, store, method, target, body)` returning
   either the guest JSON input or the refusal to send. No I/O, so it is
   testable without a server.
2. `src/cli.zig` — `handleRecords`, one thin handler parameterised by store,
   and the five router arms beside the existing `/api/logs` and
   `/api/skills` arms.
3. `tests/e2e/records_api_test.zig` (new), referenced from
   `tests/e2e/main.zig` — HTTP journeys against the real binary: a GET list,
   a POST create then a GET open that reads back the created record, a
   compare-and-swap conflict, a write action refused on GET, and a missing
   record answered 404.
4. Documents in the same pass: `CHANGELOG.md` under `[Unreleased]`,
   `docs/README.md` (the endpoint and its store), `README.md`, and
   `AGENTS.md` / `CLAUDE.md` only if the change alters how an agent works.

## Failure modes

| Condition | Behaviour |
|---|---|
| Method is not GET or POST | 405, `{"ok":false,"error":"method not allowed"}`. The guest is not run. |
| GET names a write action (`create`, `append`, `update`, `status`, `recommend`) | 400 naming the actions GET accepts. The guest is not run, so no safe method can mutate a record. |
| POST names a read action, or omits `action` | 400 naming the actions POST accepts. A missing `action` is not defaulted, because a guest default may be a read. |
| Either method names `sweep`, or an action the guest does not have | 400 naming the actions that method accepts. |
| POST body is absent or not a JSON object | 400. The body is the guest's input object; there is nothing to relay without one. |
| Required field missing (`open` with no `path`, `search` with no `query`, `create` with no title) | The guest's own refusal, relayed as 400 with its wording. |
| Record does not exist (`open`, `append`, `update`, `status` on a bad path) | The guest's `no such …` / `not found` refusal, relayed as 404 by `toolRefusalStatus`. |
| Path outside the guest's `fs_prefixes`, or a `..` traversal | The guest's refusal, relayed as 400. The sandbox, not the handler, is what refuses it. |
| Record changed between read and write (compare-and-swap conflict) | The guest's refusal telling the caller to re-open and retry, relayed as 400. Never a silent overwrite, never a 500. |
| `update` `old` text absent or not unique in the record | The guest's refusal, relayed as 400. |
| Guest `.wasm` missing or fails to load (`zig build tools` not run) | 500, `{"ok":false,"error":"<tool> tool unavailable"}`, and the load failure is logged host-side. |
| Query string carries an unknown parameter (a `?t=` cache-buster) | Passed to the guest as a string field and ignored by it. No record id is read off the path, so a query parameter can never become part of one. |

## Acceptance criteria

- [x] **G1** `GET` and `POST` on `/api/reports`, `/api/rfc`, `/api/adr`, `/api/prd` and `/api/research` each reach the tool of the same name through `toolJson`, and `src/` contains no record parsing and no read or write of `docs/`.
- [x] **G2** `GET /api/rfc` lists; `GET /api/reports?action=search&query=…` searches; `GET /api/adr?action=open&path=…` returns the record; `GET /api/prd?action=checklist` and `GET /api/research?action=plan&topic=…` answer. Every field name is the one in the tool's `input_schema`.
- [x] **G3** `POST /api/prd` with `{"action":"create",…}` creates a record and the e2e test reads it back through `GET …&action=open`; `append`, `update`, `status` and `rfc` `recommend` are accepted on POST.
- [x] **G4** `GET …?action=create&…` is answered 400 without running the guest, and `POST` with a read action or with no `action` is answered 400. An e2e case asserts no record was created by the refused GET.
- [x] **G5** An `open` of a path that does not exist answers 404; a `create` missing a required field answers 400; a missing guest `.wasm` answers 500. A unit test covers the mapping and an e2e case covers the 404.
- [x] **G6** An e2e case performs two `update`s against the same `old` text and asserts the second is a 400 whose body names the conflict and tells the caller to re-open — not a 200, and not a 500.
- [x] **G7** No key is added to `config.Modules`; the five routes answer with a default config, exactly as `/api/skills` and `/api/logs` do.

## Open questions / future work

**Does the deferred view need per-record URLs?** Records are addressed by
query string today (`?action=open&path=…`). A view that wants a link surviving
a reload can carry the path in its own hash route, but a link shared outside
the UI, or an HTTP cache, would want a real URL. Resolving it means adding id
routes beside the query form — additive, and it does not change the relay, but
from then on there are two ways to address one record and both have to keep
working. The view's first draft is what should answer it.

**Should `research sweep` ever be reachable over HTTP?** It is the one action
left off both methods. Exposing it would mean a route that performs network
egress and can run for tens of seconds, which needs a streaming or job shape
rather than a request/response one — `ck_job` exists for exactly that. Worth
revisiting only when a caller wants to start a sweep from a browser.

**Should a record write announce itself on the live bus?** Chat and mesh
publish to `GET /api/events` so open views update without polling. A record
view would want the same, which means a `Topic` for record writes and a
publish in the handler. Left out because the view does not exist yet and the
topic shape should be designed with its first consumer, not before it.
