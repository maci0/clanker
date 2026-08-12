# PRD — Configurable memory layer (OpenWebUI parity, single-user)

## Status

In progress: the offline builtin path is shipped and wired; the pluggable
parts of the design (real embedding provider, real vector backend,
config-driven chunking) are present as code but not reachable at runtime.
Sources of truth: `src/memory/chunk.zig`, `src/memory/vector.zig`,
`src/memory/embedder.zig`, `src/memory/hash_embed.zig` (the host-side
traits), `tools/zig/memory.zig` + `tools/manifests/memory.tool.json` (the
sandboxed guest tool), `tools/zig/knowledge.zig` (owns the Knowledge chunk
cache), `src/config.zig`'s `Memory` struct and `parseMemory` (config), and
`src/cli.zig`'s `handleRun` (the `/api/run` injection point). `src/knowledge/store.zig`
no longer exists: Knowledge moved to the sandboxed `tools/zig/knowledge.zig`
WASM tool; any reference to `store.zig` elsewhere is stale.

Read this before trusting Design below: `embedding.provider`/`embedding.model`
and `chunk.size`/`overlap`/`strategy` are parsed from config but never read by
any code that actually chunks or embeds (see Known issues). The guest
`memory` tool does not call the host traits at all; it reimplements hashing
independently, bugs included.

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
2. Configurable chunking (size, overlap, fixed vs. markdown-aware) exposed
   through `[memory]` config.
3. A sandboxed `memory` WASM tool (chunk/embed/search) usable directly by
   agents and chain steps, scoped to `state/knowledge`.
4. `/api/run`'s `final_task` augmented with top-k memory hits for selected
   Knowledge collections, additive to the existing Knowledge injection and
   size-capped.
5. A pluggable embedder trait so a real provider can replace the hash
   embedder for better recall.

## Non-goals

- **Not a persistent vector index.** The builtin backend re-embeds cached
  chunk text at query time on every search; there is no stored vector. Fine
  at single-user Knowledge scale; building an index is only worth it once
  someone needs corpora large enough for re-embedding to cost something
  measurable, which hasn't been demonstrated.
- **Not real vector-backend swapping, yet.** `muninndb`/`sqlite-vec` are
  named in config and in `vector.zig`'s `Backend` enum, but neither has an
  implementation: deliberately deferred (see Known issues for what that
  means for anyone who sets `vector.backend` to either value today).
- **Not a vendored local embedding model.** `local_onnx` is a stub. Shipping
  a model binary isn't worth it until the hash embedder's recall is a proven
  bottleneck.
- **Not a first-class workflow step type.** `workflows/memory-rag.md`
  documents calling the `memory` tool manually from a chain; there is no
  dedicated `memory.search` pipeline stage.

## Design

**Chunking (`src/memory/chunk.zig`).** `chunkText(arena, doc_id, content,
size, overlap, strategy)` supports fixed windowing and markdown-aware
splitting (breaks on heading boundaries and blank-line separators, then
windows each section), hashing each chunk with sha256. This module is
exercised only by its own unit tests; see Known issues for the two other
chunkers that duplicate it instead of calling it.

**Vector similarity (`src/memory/vector.zig`).** `cosine(a, b) f32` and
`topK(arena, query, ids, vectors, k, threshold) []Hit{chunk_id, score}` are
free functions over caller-supplied parallel arrays, not a stateful store:
there is no `upsert`. `Backend = enum {builtin, muninndb, sqlite_vec}` is
declared but never switched on anywhere in the codebase.

**Embedding (`src/memory/embedder.zig`).** `embedOpenAICompat` is fully
implemented and tested: it POSTs `{base_url}/embeddings` with `{model,
input}` and parses an OpenAI-shaped `{data:[{embedding:[...]}]}` response.
`embedBuiltin` delegates to `hash_embed.embedBatch`. `Provider = enum
{openai_compat, local_onnx, builtin}`; `local_onnx` has no implementation,
enum value only.

**Hash embedder (`src/memory/hash_embed.zig`).** Token-bag plus
adjacent-bigram hashing into `dim` dimensions (default 384) via Wyhash,
L2-normalized, deterministic, offline. `embed()` has a known buffer overflow
in its bigram construction (see Known issues); not fixed as part of this PRD.

**Guest tool (`tools/zig/memory.zig`, `fs_prefixes: ["state/knowledge"]`).**
Actions `chunk`, `embed`, `search`. Does not import `src/memory/*.zig`: the
guest/host sandbox boundary means WASM code can't call host-only modules, so
it reimplements token-bag/bigram hashing and cosine independently (the same
buffer-overflow bug included). `chunk` ignores the `strategy` argument
entirely: always simple fixed windowing, capped at size 800 / overlap 120,
capped at 20 chunks. `search` lists `state/knowledge/*.chunks.json`,
re-embeds every chunk's text per call (no cache), filters by
`collection_ids` if given, and returns top-k by cosine with a `note` field
naming the error when the listing itself fails rather than failing the call.

**Manifest (`tools/manifests/memory.tool.json`).** `fs_prefixes:
["state/knowledge"]`, `wasm: zig-out/tools/memory.wasm`; describes the three
actions above and matches the guest tool's accepted fields.

**Config (`src/config.zig`, `Memory` struct and `parseMemory`).**

```toml
[memory]
backend = "hybrid"          # hybrid | vector | keyword
chunk.size = 800
chunk.overlap = 120
chunk.strategy = "markdown" # markdown | fixed
embedding.provider = ""     # "" or "builtin" is the only path that runs
embedding.model = ""
vector.backend = "builtin"  # only "builtin" is implemented
vector.top_k = 5
vector.threshold = 0.35
```

Parsed with unknown-key warnings. Which of these fields anything downstream
actually reads is narrower than the table suggests; see Known issues.

**Knowledge chunk cache (`tools/zig/knowledge.zig`, `deriveChunks` /
`invalidateChunks`).** `add_doc` calls `deriveChunks`, which runs its own
`chunkMarkdown(doc.id, doc.content, 800, 120)`, hardcoded and independent of
`[memory].chunk.*`, and writes `state/knowledge/<id>.chunks.json` as
`[{chunk_id, doc_id, idx, text, hash}, ...]`. `delete_doc` filters that
doc's chunks out via `invalidateChunks`; deleting the collection removes the
file outright.

**`/api/run` injection (`src/cli.zig`, `handleRun`).** Fires only on the HTTP
path, only when `req.knowledge` is non-empty and `cfg.memory.backend` is
`hybrid`/`vector`/`keyword`. Host-side, not through the WASM tool: imports
`memory/hash_embed.zig` and `memory/vector.zig` directly. `want_vector =
backend != "keyword"`. `use_hash = want_vector and embedding_provider is ""
or "builtin" and vector_backend == "builtin"` (the only branch that ever
actually runs; see Known issues). When it runs: embeds `task_text` and every
cached chunk with the hash embedder (re-embedding on every request, no
cache), ranks with `topK`, and for `hybrid` falls back to substring/token
keyword scoring over the same chunk cache if the vector pass returns nothing.
Memory hits are capped at 80,000 bytes; the raw Knowledge document block
injected ahead of them is capped at 100,000; both are prepended to
`task_text` separated by `---`.

## Known issues

1. **Bigram buffer overflow.** `hash_embed.zig`'s `embed()` (bigram
   construction) and `memory.zig`'s duplicate `hashEmbedInto()` both copy
   into a `bigram: [256]u8` buffer, but the previous and current token can
   each be up to 128 bytes (their own buffer caps) plus one separator byte:
   worst case 257 bytes into a 256-byte buffer. Two consecutive 128+
   character alphanumeric runs (reachable single-user input) trigger it.
   Both copies need the fix, or de-duplication first so there's one copy to
   fix.
2. **`embedding.provider`/`embedding.model` are dead config.** Parsed, but
   the only place either is read is a single string comparison in
   `handleRun` that checks for `""`/`"builtin"`; nothing calls
   `embedOpenAICompat` at runtime. Setting `embedding.provider` to anything
   else silently downgrades `/api/run` memory injection to keyword-only
   scoring, with no error or log. The openai_compat embedder is implemented
   and tested but unreachable from any caller.
3. **`chunk.size`/`overlap`/`strategy` are dead config.** No chunking call
   site reads them. `knowledge.zig`'s `deriveChunks` hardcodes 800/120 and
   always uses its own markdown-aware chunker; `memory.zig`'s `chunk` action
   clamps to the same 800/120 and ignores `strategy` outright.
   `src/memory/chunk.zig`'s configurable `chunkText` is exercised only by
   its own tests.
4. **`vector.backend` accepts values with no implementation.** Setting it to
   `"muninndb"` or `"sqlite-vec"` fails `handleRun`'s `use_hash` check (which
   requires `"builtin"`) and silently falls back to keyword scoring: the
   same user-visible effect as issue 2, a different config knob.
5. **Three chunkers, two hash embedders, no shared code.**
   `src/memory/chunk.zig`, `knowledge.zig`'s `chunkMarkdown`, and
   `memory.zig`'s inline windower each reimplement chunking; `hash_embed.zig`
   and `memory.zig`'s `hashEmbedInto` each reimplement hashing. A fix to one
   does not propagate to the others (issue 1 is the concrete cost of this).
   The guest/host split explains the WASM-side duplication (guest code
   cannot import host-only `src/memory/*.zig`); it does not explain the
   `knowledge.zig` vs. `chunk.zig` split, which are both host-side.
6. **`src/knowledge/store.zig` no longer exists.** Knowledge moved to the
   sandboxed `tools/zig/knowledge.zig` WASM tool; anything still pointing at
   the old path is stale.

## Failure modes

| Condition | Behaviour |
|---|---|
| `embedding.provider` set to anything but `""`/`"builtin"` | Silent fallback to keyword-only scoring; no error surfaced (Known issues 2) |
| `vector.backend` set to `"muninndb"`/`"sqlite-vec"` | Same silent keyword-only fallback; neither backend is implemented (Known issues 4) |
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
- [ ] A configured `embedding.provider` actually reaches `embedOpenAICompat`
      at runtime; currently dead code (Known issues 2)
- [ ] `chunk.size`/`overlap`/`strategy` actually govern chunking; currently
      ignored by every call site that writes `.chunks.json` (Known issues 3)
- [ ] A real `muninndb` or `sqlite-vec` `VectorStore` backend; currently
      unimplemented behind the `Backend` enum (Known issues 4)
- [ ] Bigram buffer overflow fixed in both `hash_embed.zig` and `memory.zig`
      (Known issues 1)
- [ ] The three chunkers and two hash embedders consolidated to one, or a
      documented reason each must stay separate (Known issues 5)

## Open questions / future work

- Should the guest `memory` tool share a chunking/embedding module with the
  host instead of duplicating it, or is the duplication load-bearing because
  guest code can't cross the sandbox boundary into host-only
  `src/memory/*.zig`? If the latter, the fix is a shared source file
  compiled into both targets, not a runtime import; worth deciding before
  touching Known issue 5, since it determines where the fix goes.
- Is openai_compat embedding actually wanted on the `/api/run` path, or was
  the trait built ahead of a real caller? If wanted, `handleRun` needs a
  branch that calls `embedOpenAICompat` when `embedding.provider` names a
  real provider; if not, the dead code and the config keys gating it should
  come out together rather than imply a feature that doesn't run.
- Should chunk re-embedding on every `/api/run` request (no vector cache)
  be replaced by storing embeddings alongside chunk text in `.chunks.json`,
  once a real embedder makes re-embedding non-free? Not worth doing while
  the hash embedder is the only reachable path.
