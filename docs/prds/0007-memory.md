# PRD — Configurable memory layer (OpenWebUI parity, single-user)

## Status

In progress: the offline builtin path is shipped and wired, now entirely as
a sandboxed WASM tool. The pluggable parts of the design (real embedding
provider, real vector backend, config-driven chunking) were deleted, not
stranded: the host-side `src/memory/` layer this PRD originally specified
(`chunk.zig`, `vector.zig`, `embedder.zig`, `hash_embed.zig`) was removed in
the native-to-WASM migration (commit `fa56dd8`), and the config keys that
gated it (`[memory.chunk]`, `[memory.embedding]`, `vector.backend`) were
removed with it rather than left parsed-and-ignored. Sources of truth: `tools/zig/memory.zig` +
`tools/manifests/memory.tool.json` (the sandboxed guest tool),
`tools/zig/knowledge.zig` (owns the Knowledge chunk cache),
`src/config.zig`'s `Memory` struct and `parseMemory` (config), and
`src/cli.zig`'s `handleRun` + `memorySearch` (the `/api/run` injection
point, which dispatches the guest tool). `src/knowledge/store.zig` no longer
exists either: Knowledge moved to the sandboxed `tools/zig/knowledge.zig`
WASM tool; any reference to `store.zig` elsewhere is stale.

Read this before trusting Design below: `[memory]` now carries only
`backend`, `vector.top_k` and `vector.threshold`. Chunk size, overlap and the
embedder are inputs to a `memory` tool call, not config keys.

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
  `overlap` / `strategy`) is deferred; the `[memory.chunk]` keys are gone
  from config rather than parsed and ignored.
- **Not a pluggable embedder yet.** Former Goal 5 (provider embedder
  trait) is deferred the same way: `[memory.embedding]` is gone until a
  guest-reachable embed path exists.
- **Not a persistent vector index.** The builtin backend re-embeds cached
  chunk text at query time on every search; there is no stored vector. Fine
  at single-user Knowledge scale; building an index is only worth it once
  someone needs corpora large enough for re-embedding to cost something
  measurable, which hasn't been demonstrated.
- **Not real vector-backend swapping, yet.** `muninndb`/`sqlite-vec` are
  named in the manifest's description, but neither has an implementation:
  deliberately deferred, and `vector.backend` is no longer a config key.
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
  alphanumeric runs capped at 128 bytes. The bigram buffer is derived from
  that cap and the maximum-length pair is host-tested (Known issues 1).
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

**Config (`src/config.zig`, `Memory` struct and `parseMemory`).** Every key
the struct carries is read; a deferred Non-goal gets its key when it ships,
not before.

```toml
[memory]
backend = "hybrid"          # hybrid | vector | keyword
vector.top_k = 5            # read by /api/run injection
vector.threshold = 0.35     # read by /api/run injection
```

Parsed with unknown-key warnings, so an old `[memory.chunk]` or
`[memory.embedding]` table now says so instead of being silently ignored.

**Knowledge chunk cache (`tools/zig/knowledge.zig`, `deriveChunks` /
`invalidateChunks`).** `add_doc` calls `deriveChunks`, which runs its own
`chunkMarkdown(doc.id, doc.content, 800, 120)`, hardcoded, and writes `state/knowledge/<id>.chunks.json` as
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

1. **Embedding token truncation.** The builtin embedder intentionally hashes
   at most 128 bytes per alphanumeric run. Its bigram buffer is derived from
   that cap (`2 * 128 + 1`) and the maximum-length pair is host-tested.
2. **Chunking is fixed, not configurable.** `knowledge.zig`'s
   `deriveChunks` hardcodes 800/120 and always uses its own markdown-aware
   chunker; `memory.zig`'s `chunk` action clamps to the same 800/120 and has
   no strategy at all. Callers override per call, not per config.
3. **Post-migration consolidation.** Two chunkers remain
   (`knowledge.zig`'s markdown-aware `chunkMarkdown` and `memory.zig`'s
   fixed windower) and one hash embedder (`memory.zig`'s `hashEmbedInto`).
   The host/guest duplication this issue used to track went away with the
   host side; what is left is a two-chunker split between two guest tools,
   worth either consolidating into a shared source file compiled into both
   or documenting as deliberate (Knowledge owns its cache format).
4. **`src/knowledge/store.zig` no longer exists.** Knowledge moved to the
   sandboxed `tools/zig/knowledge.zig` WASM tool; anything still pointing at
   the old path is stale.

## Failure modes

| Condition | Behaviour |
|---|---|
| `[memory.chunk]`, `[memory.embedding]` or `vector.backend` set | Warned as an unknown key and ignored; no such key exists |
| Two consecutive 128+ char alphanumeric tokens in embedded text | Each token truncates to 128 bytes and the 257-byte bigram embeds safely |
| `state/knowledge/<id>.chunks.json` missing or unreadable | That collection is skipped for vector and keyword injection alike; read/parse errors are swallowed, no partial-collection warning |
| Injected content (Knowledge docs + memory hits) exceeds the 100,000 / 80,000-byte caps | Truncated at the byte boundary, not aligned to a document or chunk edge |
| `memory` tool `search` when the `state/knowledge` listing fails | Returns `ok:true`, empty `hits`, and a `note` naming the error, rather than failing the call |
| `chunk` action input longer than 800 chars x 20 chunks (16,000 chars) | Silently truncated: the loop stops after 20 chunks regardless of remaining text |

## Acceptance criteria

- [x] `[memory]` config parses `backend`/`vector` with unknown-key warnings
      (`src/config.zig`)
- [x] Builtin offline chunk + embed + search path works end to end with no
      network dependency
- [x] `memory` WASM tool: chunk/embed/search, scoped to `state/knowledge`
      (`tools/zig/memory.zig`, `tools/manifests/memory.tool.json`)
- [x] Knowledge `add_doc`/`delete_doc` keeps `.chunks.json` in sync
      (`tools/zig/knowledge.zig`)
- [x] `/api/run` `final_task` injection: vector hits when available, keyword
      fallback for `hybrid`, additive to Knowledge injection, size-capped
      (`src/cli.zig` `handleRun`)
- [ ] A config-driven embedding provider that reaches a real embedding call
      at runtime — deferred (Non-goals); no such key exists today
- [ ] Config-driven chunking — deferred (Non-goals); every call site that
      writes `.chunks.json` uses the fixed 800/120 (Known issues 2)
- [ ] A real `muninndb` or `sqlite-vec` vector backend — deferred (Non-goals)
- [x] Bigram overflow fixed in host-tested `tools/zig/memory_embed.zig`; the
      buffer derives from the token cap and covers two maximum-length tokens
- [ ] The two remaining chunkers consolidated to one, or a documented reason
      each must stay separate (Known issues 3)

## Open questions / future work

- Should chunk re-embedding on every `/api/run` request (no vector cache)
  be replaced by storing embeddings alongside chunk text in `.chunks.json`,
  once a real embedder makes re-embedding non-free? Not worth doing while
  the hash embedder is the only reachable path.
