# Workflow: memory RAG (OpenWebUI single-user)

Use configurable memory to augment answers with Knowledge.

1. Add docs to Knowledge (UI or `knowledge` tool).
2. `memory` tool: `chunk` to inspect chunking, `search` to test retrieval (keyword today, vector when embeddings configured).
3. Chat with `#collection` or select collections: `/api/run` injects Knowledge + memory chunk hits into `final_task` (hybrid, top_k, capped 100KB / 80KB for memory).
4. For chain wiring: `memory.search {query}` as a step before `agent.run`; store is the same chunks.json cache so chain/workflow steps share it.

Config: `[memory]` in config.toml — backend hybrid/keyword/vector, chunk.size/overlap/strategy, vector.top_k/threshold, embedding.provider/model.

Swappable vector backends: `builtin` (cosine brute-force), stubs `muninndb` / `sqlite-vec` behind `vector.Backend` trait.
