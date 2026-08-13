# PRD — Web UI model configuration (writes to `config.local.toml`)

## Status

Draft. Roughly the read half already shipped: the Models view, `/api/catalog`,
`/api/providers/models`, `renderModelSnippet`, and the copy-with-fallback flow
in `ui/app/features/models.js` all exist today. What is unbuilt is
the write half: the two endpoints below and the span-replace primitive they
need. Sources of truth once built:
`ui/app/features/models.js` (today read-only — its own header
comment: "Read-only by design: config.toml stays hand-edited, matching
`providers fill`'s own never-writes-config stance"), `src/cli.zig`
(`cmdProvidersFill`, `renderModelSnippet`, `findCatalogProvider`/
`findCatalogModel`), `src/config.zig` (`Provider`, `Model`, `Config.load`'s
base+local merge), `src/util/atomic_write.zig` (the write primitive this
reuses).

## Problem

Two existing, deliberate decisions currently make the web UI's Models view
read-only:

1. `clanker providers fill <name>` prints a ready-to-paste `[models."<provider>/
   <name>"]` block from the models.dev catalog and **never writes
   config.toml**, "reformatting the whole file to insert a few fields risks
   losing whatever hand structure/comment placement it had, so the human
   stays in the loop for the merge" (`src/cli.zig:2083-2085`).
2. The web UI's Models view calls the same rendering logic
   (`renderModelSnippet`) through `/api/catalog` and shows the result as a
   selectable/copyable snippet with a "config.toml" button that only copies
   text to the clipboard (`ui/app/features/models.js:133-161`) — it
   never touches disk either.

Both restrictions exist for the same reason: nothing in the codebase can
*edit* an existing TOML file without risking every hand-written comment and
unrelated table in it. `config.zig` only ever **reads** `config.toml` and
`config.local.toml` and merges them in memory (`Config.load`,
`src/config.zig:563`); the only place either file is ever written from code
is `clanker init` scaffolding a brand-new `config.local.toml` when none
exists yet (`cmdInit`, `src/cli.zig:1548`, via `src/util/atomic_write.zig`).
There is no partial-write path for a file that already has content.

The ask this PRD answers: let the web UI set a default provider/model and
add or update provider/model catalog blocks, with the write landing in
`config.local.toml` (the gitignored, user-specific override file,
`src/config.zig:2` — never `config.toml`, the shared/committed file) —
without reintroducing the "lose the human's hand edits" risk that made both
existing surfaces read-only in the first place.

The copy-only flow is not just less convenient; it degrades outright on the
deployment this server is built for. `navigator.clipboard` exists only in a
secure context, so on a plain-http origin (anything that is not https or
localhost) it is undefined and the Copy button can only tell the user to
select the text by hand (`ui/app/features/models.js:133-137` and
`copySnippet`). A server-side Save button fixes that real limitation, not
just a papercut.

## Goals

1. A host endpoint writes a `[providers.<name>]` or `[models."<provider>/
   <model>"]` block into `config.local.toml`, built from the same
   `renderModelSnippet`/catalog-matching logic `providers fill` and
   `/api/catalog` already use — one definition of "what a model's config
   block looks like", not a second one that can drift from the first (the
   existing comment at `src/cli.zig:2177` already states this as the reason
   `/api/catalog` and `providers fill` share code; this reuses that, not a
   third implementation).
2. A host endpoint sets the top-level `default_provider` / `default_model`
   keys in `config.local.toml`.
3. Both writes are **surgical**: only the exact target table (matched by its
   literal `[section]` header) or the exact target top-level key line is
   touched. Every other line in the file — comments, unrelated tables, a
   hand-written `web.allow`, whatever else is there — passes through
   byte-for-byte unchanged.
4. If the target table or key does not exist yet, it is added (a table is
   appended at end of file; a top-level key is inserted before the first
   `[section]` header, or appended if the file has none). If the file does
   not exist at all, it is created (mirrors `cmdInit`'s existing
   first-write case).
5. The write itself is crash-safe: temp file + atomic rename, via
   `src/util/atomic_write.zig`'s existing `writeFile` (already used for the
   only other place a config file is written in this codebase) — a killed
   process mid-write leaves the old file intact, never a truncated one.
6. The web UI Models view gains a real "Save to config.local.toml" action
   per discovered model, and a "set as default" action, replacing the
   current copy-only snippet flow with one that actually writes — after
   showing the user the exact block that will be written and requiring an
   explicit confirm, matching the confirm-before-write posture the harness
   already applies to its own file-writing tool calls.
7. The UI states plainly, after a successful write, that the change takes
   effect on the next `clanker serve` restart — not live. Text notice only;
   no in-UI restart action in v1. `Config.load` runs once at process start;
   nothing about this feature adds hot-reload.

## Non-goals

- A general TOML editor that can add or remove a single field from an
  *existing* table while leaving its other fields untouched. This PRD only
  ever replaces a table's **entire** span as one unit (see Design) — editing
  one field inside a hand-customized table is out of scope and would need
  an actual format-preserving TOML parser/serializer, which nothing in this
  codebase has today.
- Writing to `config.toml` (the shared/committed file). Still
  `config.local.toml` only, per the explicit scope decision behind this PRD.
  `providers fill`'s CLI behavior is unchanged — still print-only.
- Deleting or removing a provider/model block from the UI. Add and update
  only.
- Any new auth/access-control model for `clanker serve`. This rides the same
  trust boundary every other state-mutating web UI endpoint already assumes
  (board edits, session edits, plugin enable/disable) — a local, trusted
  operator. Not reopened here.
- Locking against concurrent writers. Two browser tabs saving different
  models at once is a read-modify-write race whose loser's write is
  silently overwritten by whoever writes last — see Failure modes. Building
  a lock or a compare-and-swap check for a single-user local tool is not
  justified by this PRD; noted as an open question if it ever becomes a
  real complaint.
- An in-UI "restart now" control after save. v1 is a text notice only.

## Design

**Where writes land.** `config.local.toml` only, in the current working
directory (matching every other `Config.load` call site). Created fresh if
missing, same as `cmdInit`'s existing first-write case.

**Table replace.** Text-based span replacement, not a TOML round-trip:

1. Read `config.local.toml` (empty string if it doesn't exist).
2. Scan lines for one that is *exactly* the literal header text
   `renderModelSnippet` already produces (e.g.
   `[models."<provider>/<model>"]` or `[providers.<name>]`). v1 matching is
   **literal**, not a normalized/format-tolerant parse of the header. A TOML
   table's body is everything from its header line up to (not including) the
   next line that starts with `[`, or EOF; that span is the table's full
   extent.
3. Found: replace the whole span with the freshly rendered block.
   Not found: append the block at EOF (with a leading blank line if the
   file is non-empty and doesn't already end in one).
4. Write the result with `atomic_write.writeFile` (Goal 5) — one full-file
   write, but the content was assembled by copying everything outside the
   target span through unchanged and substituting only the target span, so
   the *effect* is a single-table edit even though the mechanism is a whole-
   file write.

**Duplicate tables: last table wins.** If a hand-edited header uses different
spacing (e.g. `[ models."x/y" ]`) and the literal scan misses it, a second
table with the same effective key is appended. Pin against the vendored TOML
parser: **last table wins**. That outcome is accepted for v1 (the UI-written
block is the one that takes effect after restart). Format-tolerant matching
is deferred; see Open questions.

**Top-level keys (`default_provider`, `default_model`).** Not inside a
table, so the span rule differs: a line matching `^default_provider = ` (or
`default_model`) at the start of a line is replaced in place if found.
Otherwise the new line is inserted immediately before the first line
starting with `[` — TOML requires top-level keys to precede any table
header, since a key written after one belongs to that table, not the root —
or appended at EOF if the file has no table headers at all.

**Endpoints.**

| Endpoint | Body | Effect |
|---|---|---|
| `POST /api/config/model` | `{provider, model}` | Renders the model's block via the existing catalog-match + `renderModelSnippet` path, table-replaces it into `config.local.toml` |
| `POST /api/config/default` | `{provider, model}` | Sets `default_provider`/`default_model` top-level keys in `config.local.toml` |

Both return the exact block/lines written, so the UI can show a
before/after without a second read.

**Confirm-before-write.** The Models view already renders the exact snippet
text today (read-only); this reuses that same rendered preview as the
confirmation step — the user sees precisely what will be written, then
clicks a second "Save" action that fires the endpoint. No silent
one-click write.

**Provider/model name escaping.** `renderModelSnippet` already documents
handling a backslash or quote in a name so the snippet it prints stays valid
TOML (`src/cli.zig`, the comment above `renderModelSnippet`). The table-
header literal match in step 2 above must use that same escaped form when
searching for an existing table, or a name containing a quote would never
match its own prior block and would append a duplicate instead of replacing
it.

**Restart notice.** After a successful write the UI shows a text notice that
the change applies on the next `clanker serve` restart. No "restart now"
button or self-restart in v1.

**Dependencies.**

- Hard: existing `renderModelSnippet` / catalog-match path in `src/cli.zig`
  (shared with `providers fill` and `/api/catalog`); `src/util/atomic_write.zig`
  `writeFile`; vendored TOML parser behavior for duplicate tables (must be
  pinned by test before shipping).
- Soft: [PRD 0024](0024-sampling-profiles.md) / [PRD 0020](0020-auto-thinking.md)
  do not block this; Models write path is independent of sampling.
- Existing: `ui/app/features/models.js` (read-only UI to extend),
  `Config.load` base+local merge (`src/config.zig`).

**Implementation.**

1. Span-replace primitive (host): literal header match against
   `renderModelSnippet` output, replace or append table span; top-level key
   replace/insert-before-first-`[`; write via `atomic_write.writeFile`.
2. Endpoints: `POST /api/config/model` and `POST /api/config/default` in the
   serve path (`src/cli.zig`), reusing catalog-match + `renderModelSnippet`.
3. Pin duplicate-table behavior: unit test that two tables with the same
   header parse as last-wins under the vendored TOML parser.
4. Models UI: confirm-before-write using the existing snippet preview; Save
   calls the endpoint; success response shows text-only restart notice.
5. Tests: surgical replace leaves unrelated lines byte-identical; append when
   missing; top-level key insert before first `[`; crash mid-write leaves
   prior content; quote/backslash names round-trip through the same escaping;
   last-wins duplicate-table pin.

## Failure modes

| Condition | Behavior |
|---|---|
| `config.local.toml` does not exist | Created fresh, containing just the new block or key |
| Target table/key already present, exact header match | Replaced in place; rest of file untouched |
| Target table present but written with different formatting (e.g. `[ models."x/y" ]` with extra spaces) | Literal-match scan misses it; a second table with the same effective key is appended; vendored TOML parser: **last table wins** (pinned by AC test) |
| Provider or model name contains a quote or backslash | Must round-trip through the same escaping `renderModelSnippet` already applies, or the header match silently fails (see Design) |
| Two browser tabs write different models at nearly the same time | Read-modify-write race; the later write's full-file content wins and can silently drop the earlier tab's change. Accepted risk (see Non-goals), not mitigated |
| Process killed mid-write | `atomic_write.writeFile`'s temp+rename leaves the old file intact — no partial/corrupt file |
| File not writable (permissions) | Endpoint returns an error; UI surfaces it; no partial write (nothing is attempted past the failed `createFileAtomic`) |
| Write succeeds | Running `clanker serve` process keeps its already-loaded config; UI shows a text notice to restart; no live apply, no restart button |

## Acceptance criteria

- [ ] `POST /api/config/model` renders the identical block text
      `clanker providers fill` would print for the same provider/model, and
      table-replaces it into `config.local.toml`.
- [ ] `POST /api/config/default` sets `default_provider`/`default_model` as
      top-level keys, inserted before the first table header.
- [ ] Writing a table that already exists in `config.local.toml` leaves
      every other line in the file (including comments and unrelated
      tables) byte-for-byte identical to before the write.
- [ ] Writing a table that doesn't exist yet appends it; writing a
      top-level key that doesn't exist yet inserts it before the first
      `[` header.
- [ ] Header match is literal against `renderModelSnippet` output (spacing
      variants are not treated as the same table).
- [ ] A killed process mid-write (simulated in a test) leaves the previous
      file content intact.
- [ ] The vendored TOML parser's behavior on a file with two tables sharing
      the same header text is pinned by a test as **last table wins**.
- [ ] The Models view shows the exact block to be written and requires an
      explicit second action before the endpoint is called.
- [ ] A successful save's UI response is a text notice that the change
      applies on next restart (no restart button).

## Open questions / future work

- **Format-normalizing the match.** v1 is literal-only. If hand-edited header
  spacing causes duplicate appends often enough to hurt, revisit a normalized
  match. Last-wins makes the duplicate safe; normalization is convenience, not
  a correctness fix.
- **Concurrent-write protection.** Noted as a Non-goal for now; if this
  becomes a real annoyance (multiple tabs, or a user editing
  `config.local.toml` by hand while the web UI is open), the fix is likely
  a compare-and-swap on the file's content hash before writing — the same
  pattern `ck_fs_write_if` already uses for guest tool writes
  (`src/sandbox/host.zig:2624`) — rather than a lock file.
