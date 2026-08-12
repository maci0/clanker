# PRD — Configurable memory layer (OpenWebUI parity single-user)

## Goal
Pluggable embeddings (openai_compat default via `providers.base_url` + local_onnx ONNX opt-in), pluggable vector backends (builtin brute-force cosine default + muninndb/sqlite-vec behind `VectorStore` trait), markdown/fixed chunking (size/overlap configurable), WASM `memory` tool, wired via `memory_inject` mutator on `/api/run` `final_task` + chain/workflow steps.

## Scope
Only `src/memory/**`, `src/knowledge/store.zig`, `src/config.zig`, `src/cli.zig`, `src/main.zig`, `tools/zig/memory.zig`, `tools/manifests/memory.tool.json`, `docs/prds/0007-memory.md`, `workflows/**`. Do not break existing Knowledge/Prompts/archived/chat history or frontend beyond minimal wiring; keep guest under `lib.out_cap` (2 MiB).

## Config

```toml
[memory]
backend = "hybrid"          # keyword | vector | hybrid
chunk.size = 800
chunk.overlap = 120
chunk.strategy = "markdown" # fixed | markdown
embedding.provider = ""     # "" means default_provider; else explicit provider name
embedding.model = ""        # "" means that provider's default_model
vector.backend = "builtin"  # builtin | muninndb | sqlite-vec
vector.top_k = 5
vector.threshold = 0.35
```

## Traits (swappable)

- `Embedder.embed(texts: []const []const u8) ![][]f32` — openai_compat hits `POST {base_url}/embeddings`, local_onnx is a flagged TODO (ships doc, no model vendored).
- `VectorStore` — `upsert(chunk_ids, vectors)` / `search(query_vec, top_k) []Hit{chunk_id, score}`. `builtin` is cosine brute-force (<10k chunks fine <5ms); `muninndb`/`sqlite-vec` are stubs behind same trait.

## Knowledge hook
`state/knowledge/<id>.json` stays source-of-truth (raw docs). Derived `state/knowledge/<id>.chunks.json` = `{chunk_id, doc_id, text, hash}` (embeddings re-derived on demand for builtin; cached if backend wants). Chunk on `addDoc`/`createCollection`.

## Wiring
- Guest `tools/zig/memory.zig` action=chunk|embed|store|search (thin over traits, `ck_http` for remote, `ck_fs_*` for cache).
- `memory_inject` on `/api/run` final_task: when `knowledge` selected or query length > threshold, `search` top_k and prepend `[Knowledge: title / doc — score]` same slot as current Knowledge injection (additive, capped 100KB).
- Workflows can call `memory.search -> memory.store -> agent.run`.

## Deliverables
1. `src/config.zig` [memory] table
2. `src/memory/*` traits + chunker + builtin vector
3. `src/knowledge/store.zig` hook
4. `tools/zig/memory.zig` + manifest
5. Wire on `/api/run` final_task
6. PRD + workflow example

## Stop rules
- muninndb WASM artifact unavailable → ship builtin-only with stub + TODO
- local_onnx fetch fails → gate behind flag, report, don't fake pass
- If embeddings endpoint unreachable, fall back to keyword hybrid/keyword-only for that request
