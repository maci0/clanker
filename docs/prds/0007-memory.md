# PRD — Configurable memory layer (OpenWebUI parity, single-user)

## Status

In progress: the offline builtin path is shipped and wired, now entirely as
a sandboxed WASM tool. The pluggable parts of the design (real embedding
provider, real vector backend, config-driven chunking) were deleted, not
stranded: the host-side `src/memory/` layer this PRD originally specified
(`chunk.zig`, `vector.zig`, `embedder.zig`, `hash_embed.zig`) was removed in
the native-to-WASM migration (commit `fa56dd8`), while the config keys that
gated it (`embedding.provider`/`embedding.model`, `vector.backend`) remain
parsed and unused. Sources of truth: `tools/zig/memory.zig` +
`tools/manifests/memory.tool.json` (the sandboxed guest tool),
`tools/zig/knowledge.zig` (owns the Knowledge chunk cache),
`src/config.zig`'s `Memory` struct and `parseMemory` (config), and
`src/cli.zig`'s `handleRun` + `memorySearch` (the `/api/run` injection
point, which dispatches the guest tool). `src/knowledge/store.zig` no longer
exists either: Knowledge moved to the sandboxed `tools/zig/knowledge.zig`
WASM tool; any reference to `store.zig` elsewhere is stale.

Read this before trusting Design below: `embedding.provider`/`embedding.model`
and `chunk.size`/`overlap`/`strategy` are parsed from config but never read by
any code that actually chunks or embeds (see Known issues).

## Problem

OpenWebUI-style single-user chat needs retrieval-augmented answers over
uploaded Knowledge without standing up an embeddings service. Clanker has no
server to mediate, so whatever backend memory uses by default must work
fully offline, and only reach out to a real embedding provider when one is
explicitly configured. Knowledge collections already run as a sandboxed WASM
tool scoped to `state/knowledge`; memory needed a way to rank and inject
relevant chunks into `/api/run` without widening that guest's reach or adding
a second, differently-scoped store.

## Goals

1. A deterministic, fully offline default: chunk stored Knowledge docs,
   embed with a zero-dependency hash embedder, rank by cosine similarity,
   for useful recall with no network call.
2. A sandboxed `memory` WASM tool (chunk/embed/search) usable directly by
   agents and chain steps, scoped to `state/knowledge`.
3. `/api/run`'s `final_task` augmented with top-k memory hits for selected
   Knowledge collections, additive to the existing Knowledge injection and
   size-capped.

## Non-goals

- **Not configurable chunking yet.** Former Goal 2 (`chunk.size` /
  `overlap` / `strategy`) is deferred. Config keys remain for
  forward-compat until deleted; nothing reads them (Known issues).
- **Not a pluggable embedder yet.** Former Goal 5 (provider embedder
  trait) is deferred the same way: `embedding.provider` / `embedding.model`
  stay parsed and unused until a guest-reachable embed path exists.
- **Not a persistent vector index.** The builtin backend re-embeds cached
  chunk text at query time on every search; there is no stored vector. Fine
  at single-user Knowledge scale; building an index is only worth it once
  someone needs corpora large enough for re-embedding to cost something
  measurable, which hasn't been demonstrated.
- **Not real vector-backend swapping, yet.** `muninndb`/`sqlite-vec` are
  named in config (and in the manifest's description), but neither has an
  implementation: deliberately deferred (see Known issues for what that
  means for anyone who sets `vector.backend` to either value today).
- **Not a vendored local embedding model.** `local_onnx` is named only in
  the manifest's description; no implementation exists. Shipping a model
  binary isn't worth it until the hash embedder's recall is a proven
  bottleneck.
- **Not a first-class workflow step type.** `workflows/memory-rag.md`
  documents calling the `memory` tool manually from a chain; there is no
  dedicated `memory.search` pipeline stage.

## Design

**One guest module owns chunking, embedding and search
(`tools/zig/memory.zig`).** The host-side `src/memory/*` traits this section
used to describe (a configurable `chunkText`, `cosine`/`topK` free
functions, an `embedOpenAICompat` provider embedder, and the
`Backend`/`Provider` enums naming the pluggable seams) were deleted in the
WASM migration; nothing with those shapes exists any more. What the guest
tool actually implements:

- **Chunking** (`chunk` action): simple fixed windowing only, size clamped
  to at most 800 and overlap to at most 120 whatever the request asks, at
  most 20 chunks, each trimmed of surrounding whitespace. No markdown-aware
  strategy exists here; the markdown-aware chunker is
  `tools/zig/knowledge.zig`'s `chunkMarkdown` (below).
- **Hash embedding** (`hashEmbedInto`): token-bag plus adjacent-bigram
  hashing via Wyhash into `dim` dimensions (default 384, clamped to
  16..1024), L2-normalized, deterministic, offline. Tokens are lowercased
  alphanumeric runs capped at 128 bytes. The bigram construction still
  carries a buffer overflow (Known issues 1).
- **Scoring**: `cosine` over two vectors (f64 accumulation) for vector mode;
  `keywordScore` for keyword mode, the fraction of the query's tokens (two
  or more chars) found as case-insensitive substrings of the chunk text.

**Guest tool surface (`tools/zig/memory.zig`, `fs_prefixes:
["state/knowledge"]`).** Actions `chunk`, `embed`, `search`. `search` takes
`query`, `mode` (`"vector"`, the default, or `"keyword"`), `top_k` (default
5), `threshold`, `dim`, and optional `collection_ids`; it lists
`state/knowledge/*.chunks.json`, re-embeds every chunk's text per call in
vector mode (no cache), scores with `keywordScore` in keyword mode, filters
by `collection_ids` if given, and returns top-k with each hit's text
truncated to 2000 chars, plus a `note` field naming the error when the
listing itself fails rather than failing the call.

**Manifest (`tools/manifests/memory.tool.json`).** `fs_prefixes:
["state/knowledge"]`, `wasm: zig-out/tools/memory.wasm`; describes the three
actions above, including `search`'s `mode` (vector, the default, or
keyword), and matches the guest tool's accepted fields.

**Config (`src/config.zig`, `Memory` struct and `parseMemory`).**

> **Parsed only / unused:** `embedding.provider`, `embedding.model`,
> `chunk.size`, `chunk.overlap`, `chunk.strategy`, and `vector.backend` are
> accepted by the parser and ignored at runtime (Known issues). Kept for
> forward-compat until a real guest-reachable embed/chunk path exists; do
> not implement fake backends that pretend to honor them.

```toml
[memory]
backend = "hybrid"          # hybrid | vector | keyword — actually read
chunk.size = 800            # parsed only / unused
chunk.overlap = 120         # parsed only / unused
chunk.strategy = "markdown" # parsed only / unused (markdown | fixed)
embedding.provider = ""     # parsed only / unused
embedding.model = ""        # parsed only / unused
vector.backend = "builtin"  # parsed only / unused; only builtin path exists
vector.top_k = 5            # read by /api/run injection
vector.threshold = 0.35     # read by /api/run injection
```

Parsed with unknown-key warnings. Live keys today: `backend`,
`vector.top_k`, `vector.threshold`. Everything else in this block is dead
config until the deferred Non-goals ship.

**Knowledge chunk cache (`tools/zig/knowledge.zig`, `deriveChunks` /
`invalidateChunks`).** `add_doc` calls `deriveChunks`, which runs its own
`chunkMarkdown(doc.id, doc.content, 800, 120)`, hardcoded and independent of
`[memory].chunk.*`, and writes `state/knowledge/<id>.chunks.json` as
`[{chunk_id, doc_id, idx, text, hash}, ...]`. `delete_doc` filters that
doc's chunks out via `invalidateChunks`; deleting the collection removes the
file outright.

**`/api/run` injection (`src/cli.zig`, `handleRun` + `memorySearch`).** Fires
only on the HTTP path, only when `req.knowledge` is non-empty and
`cfg.memory.backend` is `hybrid`/`vector`/`keyword`. It goes through the
sandboxed guest, not around it: `memorySearch` builds a `search` request
(query truncated to 4000 bytes, `top_k` from `vector.top_k`, `threshold`
from `vector.threshold`) and dispatches the `memory` WASM tool via
`toolJson`. `mode` is `"keyword"` when the backend is `keyword`, otherwise
`"vector"`; for `hybrid`, a vector pass that returns nothing is retried once
with `mode: "keyword"`. The tool re-embeds every cached chunk per request
(no vector cache). Hits are capped at 80,000 bytes and prepended to the task
inside an untrusted `<retrieved_memory_hits>` block, additive to the raw
Knowledge document injection (itself capped at 100,000 bytes).

## Known issues

1. **Bigram buffer overflow — still live, unfixed.** One copy remains after
   the migration: `tools/zig/memory.zig`'s `hashEmbedInto` copies up to 257
   bytes (`prev_buf` up to 128, one separator byte, `token_buf` up to 128)
   into a `bigram: [256]u8` buffer. Two consecutive 128+ character
   alphanumeric runs (reachable single-user input) trigger it. This is a
   real memory-safety bug awaiting a code fix; deleting `hash_embed.zig`'s
   duplicate removed the second copy, not the bug.
2. **`embedding.provider`/`embedding.model` are dead config.** Parsed, and
   nothing reads either any more: the `embedOpenAICompat` implementation was
   deleted with `src/memory/`, so there is no provider embedding path in the
   tree at all. Setting them changes nothing, with no error or log.
3. **`chunk.size`/`overlap`/`strategy` are dead config.** No chunking call
   site reads them. `knowledge.zig`'s `deriveChunks` hardcodes 800/120 and
   always uses its own markdown-aware chunker; `memory.zig`'s `chunk` action
   clamps to the same 800/120 and has no strategy at all.
4. **`vector.backend` is dead config.** Parsed, and nothing reads it; the
   `Backend` enum it used to select over was deleted with `vector.zig`.
   Setting `"muninndb"` or `"sqlite-vec"` changes nothing: only the builtin
   hash+cosine path exists.
5. **Post-migration consolidation.** Two chunkers remain
   (`knowledge.zig`'s markdown-aware `chunkMarkdown` and `memory.zig`'s
   fixed windower) and one hash embedder (`memory.zig`'s `hashEmbedInto`).
   The host/guest duplication this issue used to track went away with the
   host side; what is left is a two-chunker split between two guest tools,
   worth either consolidating into a shared source file compiled into both
   or documenting as deliberate (Knowledge owns its cache format).
6. **`src/knowledge/store.zig` no longer exists.** Knowledge moved to the
   sandboxed `tools/zig/knowledge.zig` WASM tool; anything still pointing at
   the old path is stale.

## Failure modes

| Condition | Behaviour |
|---|---|
| `embedding.provider` set to anything but `""`/`"builtin"` | Ignored: nothing reads the key; no error or log (Known issues 2) |
| `vector.backend` set to `"muninndb"`/`"sqlite-vec"` | Ignored the same way; neither backend is implemented and nothing reads the key (Known issues 4) |
| Two consecutive 128+ char alphanumeric tokens in embedded text | Bigram buffer overflow (Known issues 1) |
| `state/knowledge/<id>.chunks.json` missing or unreadable | That collection is skipped for vector and keyword injection alike; read/parse errors are swallowed, no partial-collection warning |
| Injected content (Knowledge docs + memory hits) exceeds the 100,000 / 80,000-byte caps | Truncated at the byte boundary, not aligned to a document or chunk edge |
| `memory` tool `search` when the `state/knowledge` listing fails | Returns `ok:true`, empty `hits`, and a `note` naming the error, rather than failing the call |
| `chunk` action input longer than 800 chars x 20 chunks (16,000 chars) | Silently truncated: the loop stops after 20 chunks regardless of remaining text |

## Acceptance criteria

- [x] `[memory]` config parses `backend`/`chunk`/`embedding`/`vector` with
      unknown-key warnings (`src/config.zig`)
- [x] Builtin offline chunk + embed + search path works end to end with no
      network dependency
- [x] `memory` WASM tool: chunk/embed/search, scoped to `state/knowledge`
      (`tools/zig/memory.zig`, `tools/manifests/memory.tool.json`)
- [x] Knowledge `add_doc`/`delete_doc` keeps `.chunks.json` in sync
      (`tools/zig/knowledge.zig`)
- [x] `/api/run` `final_task` injection: vector hits when available, keyword
      fallback for `hybrid`, additive to Knowledge injection, size-capped
      (`src/cli.zig` `handleRun`)
- [ ] A configured `embedding.provider` actually reaches a real embedding
      call at runtime — deferred (Non-goals); keys stay unused on purpose
      (Known issues 2)
- [ ] `chunk.size`/`overlap`/`strategy` actually govern chunking — deferred
      (Non-goals); currently ignored by every call site that writes
      `.chunks.json` (Known issues 3)
- [ ] A real `muninndb` or `sqlite-vec` vector backend — deferred; currently
      nothing reads `vector.backend` at all (Known issues 4)
- [ ] Bigram buffer overflow fixed in `tools/zig/memory.zig`'s
      `hashEmbedInto`, the one remaining copy; still unfixed (Known issues 1)
- [ ] The two remaining chunkers consolidated to one, or a documented reason
      each must stay separate (Known issues 5)

## Open questions / future work

- Should chunk re-embedding on every `/api/run` request (no vector cache)
  be replaced by storing embeddings alongside chunk text in `.chunks.json`,
  once a real embedder makes re-embedding non-free? Not worth doing while
  the hash embedder is the only reachable path. (Dead `embedding.*` /
  `chunk.*` / `vector.backend` keys stay documented-unused until that path
  exists — see Non-goals / Design.)
