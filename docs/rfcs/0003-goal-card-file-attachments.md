# RFC 0003: Attachments on a goal card (files and links)

## Status

Discussion, opened 2026-08-16, revised the same day to cover links
(http(s), Google Drive, and other URIs), not only uploaded files.

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

An operator attaches a spec, a paste, a website, or a Google Drive doc to
a goal card and expects the goal loop to retrieve it. Chat uploads already
have a decided door into Knowledge
([ADR 0014](../adrs/0014-chat-uploads-land-in-knowledge.md)). The card
today can link a `goal` id. It has no attachment list. A URL pasted into
the card body is not chunked and is not memory.

**Decision to make.** What can hang off a goal card (file, http(s) URL,
Drive, other URI), where does it live, and how does a goal run retrieve it?

**Why now.** RFC 0001 made the card a projection of `goals.json`. ADR 0014
made Chat drops `knowledge.add_doc`. The next board control will otherwise
stash bytes or raw URLs in `@todo` (two stores, no RAG) or dump Drive
links into Chat `uploads`.

**Drivers.**

- The goal is the parent, not the card ([RFC 0001](0001-workspace-room-board-hierarchy.md)).
  Attachments hang off the goal record. The card lists them.
- One Knowledge store. Ingest is `knowledge.add_doc` (ADR 0014). Do not
  put file bytes or fetched pages in the board room log.
- An attachment is a **kinded ref**, not only a file:
  `{kind: file|url, name, url?, doc_id?, visible_to}`.
- Goal runs must retrieve public attachments. `run --goal <id>` includes
  `goal-<id>` in `req.knowledge`.
- Public vs private matches tasks. Private attachments never land in
  `#general`.
- Fetch is not identity. A URL we cannot fetch (Drive auth, login wall,
  `web.allow` miss) still attaches as a link. The snapshot is optional.
- `web_fetch` today allowlists `api.github.com`,
  `raw.githubusercontent.com`, and `config web.allow`. Google Drive is
  not on that list and needs OAuth, not a bare GET.
- Chat `uploads` / `uploads-<workspace>` stays chat. Goal attachments
  do not share that collection.
- ADR 0012: attach is persist, not run. `write-goal` does not ingest.
- Text snapshots, 500 KB, same accept-list as Knowledge for files.
  HTML from a public GET is reduced to text before `add_doc`.

**Out of scope.** Implementing Chat upload (ADR 0014 spike). PDF/OCR
extract. A full Google Drive (or Dropbox, Notion) connector and token
store. Mesh replica of Knowledge. Attach on a card with no `goal` id.
REPL attach. Making `web_fetch` open-internet by default.

## Current state

| Surface | Attachments today |
|---|---|
| Goal record | `state/goals.json`: objective, criterion, optional `worktree`. No attach list |
| Goal card | `cards.zig` `goal` link. No attachment field. Body is free text |
| Chat upload | Decided: file `add_doc` into `uploads` / `uploads-<ws>` (ADR 0014). Not built. No URL ingest |
| Knowledge | `add_doc` (name + string), folder sync. No URL field, no goal key |
| `web_fetch` | GET, truncated body, host allowlist. No Drive, no persist |
| Goal run | Knowledge only if the session already selected collections |

A card can name a goal. It cannot hold a file or a link.

## Options considered

### Option A: per-goal Knowledge collection; file or URL, snapshot when we can

- **What it is:** the attach control takes a file **or** a URI. Both
  write a ref on the goal and a doc in collection `goal-<id>`.

  | kind | What we store | What memory searches |
  |---|---|---|
  | `file` | bytes via `add_doc` (text, 500 KB) | the file text |
  | `url` (public http(s) we can GET) | URL + snapshot via `add_doc` | the snapshot (and the URL string) |
  | `url` (Drive, login wall, not allowlisted) | URL + name, no snapshot | the URL and title only |

  A later connector (Drive OAuth, etc.) fills `doc_id` on refresh
  without changing the ref shape. A goal run selects `goal-<id>`.
- **Maturity:** `add_doc`, chunk cache, inject, and `web_fetch` ship.
  Missing: refs on the goal, board UI, fetch-then-add_doc, auto-select
  on `run --goal`. Drive fetch does not exist.
- **How it would fit:** board/goal detail: file picker and a URL field.
  Host or a small helper GETs allowlisted http(s), strips tags, POSTs
  `add_doc`. Failed or private hosts skip the GET. `handleRun` unions
  `goal-<id>` into `req.knowledge`. Filter `visible_to` at inject time
  from the goal record (no Knowledge schema change in v1).
- **Pros:**
  - One attach list for files and links.
  - One store, one inject path.
  - Drive links are first-class before we have Drive auth.
  - Card stays a projection.
- **Cons:**
  - Snapshots go stale. Need a refresh later.
  - `web_fetch` allowlist will refuse most websites until `web.allow`
    grows or a dedicated ingest allow is added.
  - Collection-per-goal multiplies files under `state/knowledge/`.
- **Cost to adopt:** refs + UI + optional snapshot GET + `run --goal`
  select. Drive remains link-only until a connector exists.
- **Cost to leave:** delete `goal-*` collections; ignore refs.
- **Evidence:** ADR 0014; `web_fetch.tool.json` allowlist;
  `cards.zig` `goal`; `handleRun` `req.knowledge`.

### Option B: files in `uploads-<ws>`, URLs left as card body text

- **What it is:** files reuse Chat's collection. URLs are pasted on the
  card. Goal run selects `uploads-<ws>` and hopes.
- **Pros:** fewer collections; no fetch.
- **Cons:** chat dumps mix with goal specs; URLs are not memory; Drive
  links are dead strings in `#general`.
- **Evidence:** ADR 0014 collection key is workspace, not goal.

### Option C: status quo

- **What it is:** no attach control. Paste into the card or Include-in-chat.
- **Pros:** zero work.
- **Cons:** no RAG, `#general` floods, session-global Knowledge is not
  goal-scoped.
- **Evidence:** card `body` is a string.

### Option D: out of the box, always live-fetch the URL at run time

- **What it is:** store only `{kind:url, url}`. Each goal turn calls
  `web_fetch` (or a Drive tool) instead of memory search.
- **Maturity:** `web_fetch` exists; Drive does not. Allowlist is narrow.
- **Pros:** no stale snapshot; no extra Knowledge docs for links.
- **Cons:**
  - Every turn pays a GET; offline and 404 become missing context.
  - `web_fetch` cannot hit Drive.
  - Files still need `add_doc`, so two retrieve paths.
  - Retrieved pages skip the untrusted Knowledge fence unless we wrap
    them by hand.
- **Cost to adopt:** run-loop fetch list. Brittle for anything not on
  `web.allow`.
- **Evidence:** `web_fetch` default hosts are GitHub only.

## Implications by horizon

### Short term (this release / 0–3 months)

- **If A:** card attach = file or URL; snapshot public GET when allowed;
  Drive is a named link; goal runs search `goal-<id>`.
- **If B:** files mix with chat; links stay paste.
- **If status quo:** paste.
- **If D:** every turn fetches; Drive still fails.

### Medium term (3–12 months)

- **If A:** a Drive (or Notion) connector fills snapshots into the same
  refs. Refresh is one verb.
- **If B / D:** a connector still has nowhere goal-scoped to land.
- **If status quo:** people keep pasting.

### Long term (12+ months)

- **If A:** Goal : collection stays 1:0..1. New URI kinds are fetchers,
  not stores.
- **If B:** `uploads` is a junk drawer.
- **If D:** retrieve policy is "whatever the allowlist is today."
- **If status quo:** board and Knowledge stay two products.

## Recommendation

**Recommended option:** Option A. A goal attachment is a kinded ref
(`file` or `url`) on `goals.json`, ingested into `goal-<id>` when we
have text (upload, or a successful public GET). A URL we cannot fetch
still attaches. The card lists public names and host/path. `run --goal`
selects `goal-<id>`. Chat `uploads` is not used. Drive in v1 is a link
plus title, not a silent failed GET.

**Confidence:** 7/10

**Why this confidence.** File ingest is the same decision as ADR 0014.
Links are the new bit: snapshot-when-possible avoids pretending Drive
works, and avoids a second retrieve path for files. Confidence rises
when a spike shows allowlisted GET -> `add_doc` and a Drive URL
surviving as a ref with no snapshot. It sinks if operators need live
Drive bodies in v1 (that is a connector RFC, not this one).

**Rationale.** B mixes corpora and ignores links. C is paste. D fetches
every turn and still cannot do Drive. A is one list, one store, and a
fetcher we can add later without moving refs.

**Reversibility.** Additive. Delete `goal-*` collections and ignore
refs. Teaching "a Drive link on the card is not the doc body" is the
UX risk, not a migration.

## Open questions

1. **Private titles.** Hide names from others, or show a count? Bias:
   hide names; count only for members in `visible_to`.
2. **Card without a goal id.** Refuse. Attach is a goal verb.
3. **`write-goal`.** No attach (no id). After `add-goal` only.
4. **Which hosts may we snapshot?** Bias: `web_fetch` allowlist plus an
   explicit ingest allow (not the whole internet). Drive/docs.google.com
   is not in that set until a connector exists.
5. **Stale snapshots.** Bias: show fetched-at on the card; a Refresh
   control re-GETs. No automatic refresh on every goal turn.
6. **Same URL attached twice.** Bias: one ref per URL per goal; refresh
   replaces the snapshot.

## Next steps / action items

- [ ] Comment on snapshot allowlist (question 4) and private titles
      (question 1).
- [ ] Spike: file attach and URL attach on a goal-linked card ->
      `goal-<id>` -> `run --goal` memory hit (URL hit may be title-only).
- [ ] Do not put bytes or fetched HTML in `@todo`.
- [ ] Do not write goal attachments into `uploads` / `uploads-<ws>`.
- [ ] Do not silently GET Google Drive in v1.
- [ ] Write the ADR once the decision is made.

## References

- [RFC 0001: Workspace, room, board, and folder hierarchy](0001-workspace-room-board-hierarchy.md)
- [RFC 0002: Chat file upload into Knowledge / memory](0002-chat-upload-into-knowledge.md)
- [ADR 0014: Chat file uploads land in Knowledge through add_doc](../adrs/0014-chat-uploads-land-in-knowledge.md)
- [ADR 0012: Goal draft, persistence, and execution are separate](../adrs/0012-goal-draft-persistence-and-execution-are-separate.md)
- [PRD 0002: Shared Kanban board](../prds/0002-kanban-board.md)
- [PRD 0007: Memory layer](../prds/0007-memory.md)
- `tools/zig/cards.zig` (`goal`)
- `tools/zig/knowledge.zig` (`add_doc`)
- `tools/manifests/web_fetch.tool.json` (allowlist)
- `src/cli.zig` (`handleRun`, `memorySearch`)
