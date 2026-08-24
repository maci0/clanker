# RFC 0002: Chat file upload into Knowledge / memory

## Status

Decided, 2026-08-16. Choice recorded in
[ADR 0014](../adrs/0014-chat-uploads-land-in-knowledge.md).

## Overview

An operator drops a file on Chat and expects later turns to retrieve it.
Today that file never becomes Knowledge. Images ride the vision path.
`@file` chips name a workspace path as `[File: path]` for this turn only.
The Knowledge view is a different surface: paste or pick a text file, or
sync a server folder. Memory search (`PRD 0007`) only ranks documents
already in `state/knowledge/`. The missing edge is Chat -> that store.

**Decision to make.** When a file is uploaded in Chat, how does it become
a Knowledge document that memory can retrieve?

**Why now.** The composer already has an attachments row and file chips,
and `/api/run` already injects selected collections plus memory hits.
Without a declared ingest path, the next Chat UX change will either dump
bytes into the prompt (no later retrieval) or invent a second store next
to Knowledge.

**Drivers.**

- One store. Uploaded chat files land in `state/knowledge/` through the
  existing `knowledge` guest (`add_doc` already chunks). Do not add a
  parallel `state/chat-files/` that memory cannot see.
- Retrieved text stays untrusted. Hits keep the
  `<retrieved_knowledge>` / `<retrieved_memory_hits>` fences
  (`src/cli.zig` `handleRun`). An upload is not an instruction.
- WASM by default. Ingest is `knowledge.add_doc` (and its chunk cache).
  The host does not grow a second parser.
- Chat attach today is two things: images (vision, cap 4) and workspace
  path chips (`[File: path]`). An upload is a third: the browser has the
  bytes, the server does not yet have a file.
- The Knowledge guest's `fs_prefixes` are `state/knowledge` only. Folder
  sync is already the one host-side exception (`handleKnowledgeSync`).
- Text first. Knowledge `add_doc` is a name plus string content. The
  Knowledge UI already refuses files over 500 KB and accepts
  `.txt/.md/.json/.csv,text/*`. Binary, PDF, and office formats are not
  a second store; they are a later extract step or a refuse.
- RFC 0001: if a workspace is selected, the collection is tagged to that
  workspace the way sessions are. Empty-id (cwd) still works.

**Out of scope.** Pluggable embedders and real vector indexes (PRD 0007
non-goals). PDF/OCR extract. REPL/TUI attach (PRD 0005 still open).
Images as Knowledge (they stay on the vision path). Mesh replica of
Knowledge. Auto-ingest of every `@file` workspace path (that path is
already on disk; the operator can sync the folder).

## Current state

| Surface | What it does today | Does it become Knowledge? |
|---|---|---|
| Chat image drop | `core/attachments.js`, up to 4 images, vision on `/api/run` | no |
| Chat `@file` / `/doc` | chip or `[File: path]` prefix; agent is told to `read_file` | no |
| Knowledge "Or attach a text file" | FileReader in the page, POST JSON `{name,content}` to `/api/knowledge/<id>/docs` | yes, if the operator already opened a collection |
| Knowledge folder sync | host reads a server path, upserts `.md/.txt/.json/.csv/.log` | yes |
| Memory search | `memory` guest over `state/knowledge/*.chunks.json`, only if `req.knowledge` is non-empty | only for collections already selected |

`/doc <path>` in the composer explicitly does **not** read the file. The
comment in `ui/app/app.js` (`handleSlashDocFile`) says the sandbox cannot
see a browser-local file, so it only prefixes `[File: path]`. That is
correct for a workspace path and the wrong answer for a drag-drop upload,
where the browser already has the bytes.

There is no ADR for this edge. PRD 0007 assumes documents are already in
Knowledge. PRD 0006 lists image attach, not document ingest from Chat.

## Options considered

### Option A: Chat upload writes `knowledge.add_doc` into a well-known collection

- **What it is:** dropping or picking a text file on Chat POSTs it through
  the existing Knowledge API into one collection the chat owns (workspace
  `uploads`, or `uploads` under the empty-id workspace). That collection is
  added to `req.knowledge` for this session so memory search runs. The
  Knowledge view still lists and deletes the doc.
- **Maturity:** `add_doc` + `deriveChunks` + `/api/run` injection already
  ship. The missing piece is the composer calling the same POST the
  Knowledge form uses, plus a rule for which collection receives the doc.
- **How it would fit:** `ui/app/app.js` / `core/attachments.js` grow a
  document drop next to images. Create-or-reuse collection via
  `POST /api/knowledge`. `add_doc` as today. Session or localStorage
  remembers the collection id the way `clanker.knowledge` already
  remembers Include-in-chat. No new guest.
- **Pros:**
  - One store, one chunker, one inject path.
  - Later turns retrieve the file without the operator opening Knowledge.
  - Deleting the doc is the existing Knowledge UI.
- **Cons:**
  - Auto-ingest can put a secret or a huge paste into RAG. Needs a visible
    chip ("saved to Knowledge: name") and a remove that deletes the doc,
    not only the chip.
  - Collection identity (one global `uploads` vs per-session vs per
    workspace) has to be picked or uploads from two projects mix.
- **Cost to adopt:** composer upload + create-or-reuse collection +
  auto-select. Caps and accept-list copy the Knowledge form (500 KB, text).
- **Cost to leave:** delete the docs that landed in `uploads`; the
  collection id can stay unused.
- **Evidence:** `knowledge.js` file input (500 KB, `readAsText`, POST
  docs); `handleRun` injects `req.knowledge` then `memorySearch`;
  `add_doc` writes chunks (`tools/zig/knowledge.zig` `deriveChunks`).

### Option B: Attach is this-turn only; Keep is explicit

- **What it is:** a dropped file is inlined or sent as this-turn context
  only. A "Keep in Knowledge" control (or `/keep`) copies it into a
  collection the operator names.
- **Maturity:** matches how `@file` already works (this turn, no store).
- **How it would fit:** composer holds the text until submit; Keep is a
  second click that POSTs `add_doc`. Memory does not see the file unless
  Keep ran.
- **Pros:**
  - No surprise ingest. Secrets dropped for one question stay out of RAG.
  - Collection choice is explicit.
- **Cons:**
  - The stated want is "upload into chat, then it is in memory." Keep is
    a second step the operator will skip, and later turns will not
    retrieve the file.
  - Two chips (pending attach vs saved doc) on a composer that already
    has images and `@file`.
- **Cost to adopt:** inline-this-turn is small; Keep is Option A plus a
  confirm.
- **Cost to leave:** drop the Keep control; inlined turns stay in the
  session transcript only.
- **Evidence:** `@file` / `prependPendingFiles` never call Knowledge;
  OpenWebUI-style RAG usually ingest-on-upload, not ingest-on-confirm
  (unverified product survey; we have not opened their source this turn).

### Option C: status quo

- **What it is:** Chat stays images + path chips. Knowledge stays a
  separate view. Memory only ranks what that view already holds.
- **Pros:** zero work; no accidental ingest.
- **Cons:** the operator journey the RFC is about does not exist. People
  will paste 20 pages into the composer or abuse `@file` and hope the
  agent rereads the path every turn.
- **Cost to adopt:** zero now; later a one-off ingest will be guessed in
  the composer.
- **Evidence:** two attachment hosts in `index.html` (`#attachments`,
  `#file-chips`); Knowledge create/add is only under `#view-knowledge`.

### Option D: out of the box: drop into a linked folder and Sync

- **What it is:** write the upload to a workspace path (or a configured
  docs folder) and call the existing `POST /api/knowledge/<id>/sync`.
  No new ingest API.
- **Maturity:** folder sync already upserts top-level text files
  (`handleKnowledgeSync` in `src/cli.zig`).
- **How it would fit:** the browser cannot write the server disk. Serve
  would need a new "write this upload into the linked folder" host path,
  or the operator saves the file by hand and clicks Sync. The first is a
  new write into the sandbox root; the second is not Chat upload.
- **Pros:** reuses sync, prune, and file names as document ids.
- **Cons:**
  - Sync is host-side because the knowledge guest cannot read the folder.
    Chat upload would either widen that exception or ask the operator to
    leave the page.
  - Mixing chat dumps into a source folder is a bad default (untracked
    files in the checkout).
  - Sync is top-level only; no subdirs.
- **Cost to adopt:** a new host write, or no real Chat UX.
- **Cost to leave:** stop writing into the folder; synced docs remain
  until prune.
- **Evidence:** `handleKnowledgeSync` comment: guest scope is
  `state/knowledge/` only; serve reads the folder and feeds `add_doc`.

## Implications by horizon

### Short term (this release / 0–3 months)

- **If A:** Chat drop of a text file creates-or-reuses `uploads` (per
  workspace when one is selected), POSTs `add_doc`, selects that
  collection for the session, shows a chip that can delete the doc.
- **If B:** drop inlines for this turn; Keep is optional. Memory stays
  empty unless Keep is used.
- **If status quo:** nothing. Operators keep pasting or using Knowledge.
- **If D:** Chat still does not upload; Sync stays a Knowledge-view verb.

### Medium term (3–12 months)

- **If A:** session and workspace both retrieve prior chat uploads.
  Binary/PDF extract can feed the same `add_doc` later.
- **If B:** most files never reach memory; people ask for A again.
- **If status quo:** a one-off composer hack appears, probably inlining
  the whole file into `final_task` and blowing the cap.
- **If D:** checkout dirt and sync-prune accidents.

### Long term (12+ months)

- **If A:** chat uploads are just Knowledge documents. RFC 0001 can tag
  the collection to the workspace like sessions. No second corpus.
- **If B:** two operator habits (Keep vs not) forever.
- **If status quo:** Knowledge and Chat stay two products.
- **If D:** the docs folder becomes a junk drawer.

## Recommendation

**Recommended option:** Option A, Chat upload through `knowledge.add_doc`
into a well-known collection (`uploads`, or `uploads-<workspace>` when a
workspace is selected), auto-included in `req.knowledge` for that session.

**Confidence:** 7/10

**Why this confidence.** The store, chunker, and `/api/run` inject path
already exist; this RFC is which door Chat uses. Confidence rises if a
spike shows create-or-reuse of `uploads` plus auto-select without mixing
two workspaces' files. It sinks if auto-ingest of secrets is unacceptable
and B's Keep is required, or if text-only is too narrow and the first
upload is a PDF we refuse.

**Rationale.** The operator asked for upload-in-chat then memory. B makes
memory optional and will be skipped. D pretends Sync is Chat. Status quo
leaves a hole next to a finished inject path. A reuses `add_doc` so there
is still one corpus, one untrusted fence, and one delete UI. The surprise
ingest risk is handled by a visible chip and a 500 KB text cap, not by a
second store.

**Reversibility.** Additive. Docs in `uploads` can be deleted. The
collection id is not a public API. The point of no return is teaching
operators that a Chat drop is durable; reversing that is a UX change, not
a migration.

## Open questions

1. **Collection key.** One global `uploads`, one per workspace
   (`uploads-<ws>`), or one per session? Bias: per workspace, and
   `uploads` for the empty-id cwd, so two projects do not share a corpus.
   Who: this RFC.
2. **Does remove-chip delete the Knowledge doc?** Bias: yes, if this
   session created it and no other session has selected the collection
   for a later run. Safer: remove from `req.knowledge` this turn and
   leave the doc; delete stays on the Knowledge view. Who: implementer.
3. **Non-text files.** Refuse with the Knowledge accept-list, or stash
   bytes and extract later? Bias: refuse in v1 (same 500 KB / text/*
   as the Knowledge form). Who: this RFC.
4. **CLI / REPL.** `clanker run` has no upload. Bias: out of scope; a
   path argument can keep using `@file` / `read_file`. Who: PRD 0005.
5. **Should `@file` of a workspace path also ingest?** Bias: no. The
   bytes are already on disk; folder sync is the ingest for trees.

## Next steps / action items

- [x] Comment on collection key (question 1) and chip-delete (question 2).
- [ ] Spike: composer text-file drop -> create-or-reuse `uploads` ->
      `add_doc` -> session `req.knowledge` includes it; next turn's
      `memorySearch` returns a hit on that doc.
- [ ] Visible chip: filename, collection, remove.
- [ ] Do not change image attach or `@file` path chips.
- [x] Write the ADR once the decision is made.

## References

- [ADR 0014: Chat file uploads land in Knowledge through add_doc](../adrs/0014-chat-uploads-land-in-knowledge.md)
- [PRD 0007 — Configurable memory layer](../prds/0007-memory.md)
- [PRD 0006 — Web UI](../prds/0006-webui.md) (image attach, not document ingest)
- [RFC 0001 — Workspace, room, board, and folder hierarchy](0001-workspace-room-board-hierarchy.md)
  (workspace-tagged collections)
- `tools/zig/knowledge.zig` (`add_doc`, `deriveChunks`)
- `tools/zig/memory.zig` (`search`)
- `src/cli.zig` (`handleRun` knowledge + `memorySearch`; `handleKnowledgeSync`)
- `ui/app/features/knowledge.js` (500 KB text file -> POST docs)
- `ui/app/app.js` (`[File: path]`, `pendingFiles`, `handleSlashDocFile`)
- `ui/app/core/attachments.js` (images only)
