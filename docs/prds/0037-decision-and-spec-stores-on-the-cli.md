# PRD — Decision and spec stores on the CLI

## Status

Shipped — 2026-08-16. tools/zig/adr.zig, tools/zig/prd.zig and tools/zig/doc_scaffold.zig are the source of truth; src/adr/command.zig and src/prd/command.zig render for the CLI. No HTTP surface.

Sources of truth: `tools/zig/adr.zig` and `tools/zig/prd.zig` (the guests),
`tools/manifests/adr.tool.json` and `prd.tool.json` (the sandbox policy),
`tools/zig/doc_scaffold.zig` (the shared, host-tested scaffolding), and
`src/adr/command.zig` / `src/prd/command.zig` (rendering only). Surfaces:
the `adr` and `prd` tools in the agent's catalog, and `clanker adr` /
`clanker prd` on the CLI. No HTTP or web UI surface yet.

## Problem

docs/adrs/ and docs/prds/ were the only record stores with no verb: the taxonomy listed both as maintained by hand, so the CLI, the web UI and the agent each reached for a text editor while every neighbouring store had one implementation behind a sandboxed tool. Numbering, template rendering and index upkeep were therefore done from memory, and an index status was a second copy that nothing kept true.

## Goals

1. `clanker adr` and `clanker prd` expose both stores, through guests rather
   than native code.
2. Numbering, `TEMPLATE.md` rendering and index upkeep happen inside the
   tool, so the CLI, the agent and any later surface share one implementation.
3. Search spans the neighbouring stores and reports which store each hit fell
   in, rather than merging them into one list.
4. The refusals encode each store's own rules: an ADR needs consequences, a
   supersede needs its replacement, a shipped PRD names its source files.
5. Listing reads each status from the document, never from the index, and
   writes both when a status changes.

## Non-goals

- **No HTTP or web UI surface.** The stores are read and written by whoever is
  changing the code, and that is a terminal or an agent run. A view can be
  added later as a `ui/plugins/` addon over the same guests without touching
  either tool.
- **No judgement about content.** Neither tool decides whether a decision is
  right or a spec is complete; it enforces the shape the store documents and
  nothing else. A tool that scored an ADR would be wrong more often than the
  writer, and its refusals would be argued with rather than fixed.
- **No RFC requirement.** An ADR does not need an RFC and an RFC does not need
  an ADR. Coupling them would force a fake RFC for an obvious decision, which
  is how a record store starts collecting ceremony.
- **No renumbering or renaming.** A number, once handed out, is permanent even
  if the document is deleted: links to it outlive it.

## Design

**Two guests, one scaffolding module.** `adr.zig` and `prd.zig` are separate
guests rather than one parameterised store, because the two differ in the
places that matter: the ADR index is a bullet list and the PRD index is a
table with a Notes column, and PRD statuses are phrases ("In progress") while
ADR statuses are single words. Everything genuinely shared — numbering,
template substitution, section arithmetic, inventory edits — lives in
`doc_scaffold.zig`, which imports nothing from the guest ABI and therefore has
`test` blocks that actually run under `zig build test`. A wrong section
boundary silently corrupts a document, which is the class of bug a wasm-only
helper can never be tested for.

**Status is read from the document, never the index.** `list` opens each
record and parses its `## Status`. An index is a second copy, and a second
copy that only `create` writes is wrong from the first status change onwards —
which is how every record in `docs/reports/` once read `Open` months after it
was fixed. Every writer of a status therefore writes both, and reports
`indexed:false` when the index write lost a compare-and-swap, naming the line
to reconcile rather than silently diverging.

**Statuses come from a stated vocabulary.** `doc_scaffold.statusFrom` takes the
store's list of valid phrases and returns the earliest one occurring in the
Status line. `statusWord` cuts at the first space, so it reads "In progress"
as "In" and "**Web UI plugins: Shipped.**" as "**Web". An unrecognised wording
falls back to `statusWord` rather than to an empty string: a row with a
surprising status is still worth listing, a row with none looks unreadable.

**Search spans neighbours and keeps them apart.** `adr search` covers the ADRs,
RFCs and PRDs; `prd search` covers the PRDs and ADRs. The groups are reported
separately because which store a hit lands in *is* the answer — settled, still
open, or already specified around. Both filter `README.md` and `TEMPLATE.md`
out of the hits (`isDocPath`): an index names every record it lists, so an
unfiltered grep answers one real hit with an inventory line stapled to it.

**Refusals encode the store's rules.** `adr create` requires consequences;
`adr status ... superseded` and `... deprecated` require a note; `prd status
... shipped` requires a note naming the source files. Each is a rule the store
already documents in prose that nothing enforced. The tool refuses rather than
warns, because a warning on a record nobody re-reads is the same as silence.

**Dependencies.** `tools/zig/doc_scaffold.zig` (shared with the `rfc` and
`research` guests), the `rfc` store for the ADR link, and `toolJson` in
`cli.zig` for the CLI call. No new host capability: both descriptors grant only
`fs_prefixes` under `docs/` and no network.

If a table of ops/fields/endpoints exists in code, mirror it here exactly;
treat a mismatch between this table and the code as a bug in the PRD, not
a stylistic choice, and fix it the same day it's noticed.

For a **Draft** (or partially shipped) PRD, Design must also settle build
blockers and sequencing — do not leave "must decide before coding" items
only under Open questions:

- **Dependencies.** Other PRDs, ADRs, and existing code this rides on.
  Hard blockers first; soft/related after.
- **Implementation.** Numbered phases with concrete file paths (create /
  edit). Each phase should be independently checkable. Put "decide X"
  work in Design policy above, not as a phase that re-opens the decision.

## Failure modes

| Condition | Behaviour |
|---|---|
| The store's `TEMPLATE.md` is missing | `create` refuses and names the file, rather than inventing a skeleton that would then differ from every other record |
| A record already exists at the target path | `create` refuses (compare-and-swap against empty) and says to list and open it instead |
| The index changed concurrently | The record is still written; the answer carries `indexed:false` and names the line or row to reconcile by hand |
| The index lacks its inventory markers | Same as above — the tool will not guess where the list belongs |
| The record changed between read and write | `append`, `update` and `status` refuse with a message saying to re-open and retry against current text |
| `update`'s old text occurs more than once | Refused as ambiguous, asking for more surrounding text; replacing "it" would be a guess |
| A record's status word is unrecognised | Listed under its literal wording (`OTHER` for `prd list`), never dropped |
| A record cannot be read at all | Still listed, with an empty status, because the path is what a reader needs in order to go look |
| More than 60 records in a store | The remainder are listed without their status and the answer says so, rather than exhausting the 1 MiB host arena |
| A `prd create` note contains `|` | Refused: it is written into a Markdown table cell and would shift every column after it |

## Acceptance criteria

- [x] `clanker adr` and `clanker prd` list, search and open the two stores (Goal 1).
- [x] Both are WASM guests under a descriptor; no native code reads or writes either store (Goal 1).
- [x] `create` allocates the next number, renders the store's `TEMPLATE.md` and adds the index entry (Goal 2).
- [x] `adr search` reports ADR, RFC and PRD hits separately; `prd search` reports PRD and ADR hits separately (Goal 3).
- [x] `README.md` and `TEMPLATE.md` are excluded from search hits (Goal 3).
- [x] `adr create` refuses without consequences; `adr status ... superseded` refuses without a note (Goal 4).
- [x] `prd status ... shipped` refuses without a note naming the source files (Goal 4).
- [x] Listing reads each status from the document, and a status change writes the index too (Goal 5).
- [x] A failed index write is reported rather than silently dropped (Goal 5).
- [ ] No HTTP surface exists for either store; `GET /api/adr` and `GET /api/prd` are unwritten. Deliberate — see Non-goals — but it is not true that every surface shares the implementation until one exists to share it.

## Open questions / future work

- **Should the rendered scaffold keep its instructional prose?** `create`
  substitutes the caller's text into the template and leaves the template's
  own guidance underneath it, so a fresh record carries both. That matches the
  `rfc` store, and the guidance is what a first-time writer needs, but it
  means every new record has to be edited down before it reads as a document.
  Resolving it either way is a template change, not a code change; the cost of
  removing it is that the bar each section has to clear stops being visible at
  the point of writing.
- **Should `prd list` show the index's Notes column?** The note ("Phase 3
  open", "e2e not wired") is often the most informative field in the store and
  the listing does not show it, because it lives in the index rather than in
  the document and the listing deliberately trusts only documents. Surfacing
  it would mean reading a second file per row.
- **A shared `records` view.** `reports`, `rfc`, `adr`, `prd` and `research`
  now have near-identical CLI halves. A single renderer over a store
  descriptor would remove roughly five hundred lines of near-duplicate Zig,
  at the cost of making each store's genuinely different bits (the PRD's
  status grouping, the RFC's confidence, the ADR's supersede rule) conditional
  rather than local. Worth doing only once a sixth store makes the shape
  obvious.
