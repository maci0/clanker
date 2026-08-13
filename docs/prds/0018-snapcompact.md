# PRD — Snapcompact

## Status

Draft. No source files yet. Affects `src/agent/loop.zig` (the `maybeCompactMessages`
path). New compaction backend in `src/agent/snapcompact.zig`. Pixel-font renderer
in `src/agent/pixelfont.zig`. Requires a vision-capable model.

## Problem

When conversation history exceeds `compact_threshold_bytes`, `Agent.maybeCompactMessages`
calls the LLM to summarize the truncated portion. This has three costs:
1. The summary turn charges input tokens for the text being summarized plus
   output tokens for the summary itself.
2. The summary adds latency: it is a full LLM completion before the actual turn
   can start.
3. The summarizer can hallucinate: it may misstate a tool result, an error code,
   or a file path from earlier in the session.

omp's snapcompact replaces the LLM summarizer with a deterministic renderer: the
truncated history is rendered to a pixel-font PNG image, which the model reads
back near-verbatim using its vision capability. omp claims approximately 1/3 of
the input price of LLM summarization (the image token count is lower than the
text token count for the same content), zero latency penalty from a summarizer
turn (no extra completion), and zero hallucination risk (the image is the actual
text).

## Goals

1. A new `compaction.strategy = "snapcompact"` config option that replaces the
   LLM summarizer in `maybeCompactMessages`. Default remains `"llm"`.
2. The renderer produces a deterministic PNG: given the same messages JSON, it
   always produces the same bytes. No external deps; a pure-Zig pixel-font
   renderer.
3. The PNG is inserted as a multimodal message (image content block) in place of
   the truncated messages. The image carries a preamble line: `[conversation
   history: <N> messages, rendered at <timestamp>]`.
4. The strategy is skipped (falls back to LLM summarization) if the configured
   model does not support image input. Detection reuses the existing mechanism:
   the model's `capabilities` list (`src/config.zig`) containing `"image_in"`,
   as checked by `imageAttachmentsSupported` (`src/cli.zig`). An empty
   capabilities list means assumed-supported, so snapcompact only falls back
   when a model declares capabilities and omits `image_in`. If the provider
   later rejects the image at request time, fall back to LLM compaction (do not
   fail the turn).
5. Image size is bounded: if the rendered PNG exceeds `snapcompact.max_bytes`
   (default 200000), the renderer splits across multiple images, each as a
   separate content block, up to `snapcompact.max_images` (default 10).
6. Snapcompact is opt-in. `compaction.strategy = "llm"` is the default and
   remains unchanged.

## Non-goals

- Not a general image renderer. The renderer exists only for conversation
  compaction. It is not exposed as a tool or callable from outside the compaction
  path.
- Not using system fonts or any external font library. The pixel font is a
  bitmapped 5x7 or similar fixed-width grid embedded as a Zig comptime literal.
  No TTF loading, no HarfBuzz, no FreeType.
- Not visually styled beyond the fixed dark theme. Default colors are
  `bg = "#1a1a1a"` and `fg = "#e0e0e0"` (decided). The output is a monospace
  grid for maximum information density, not a UI component.
- Not a replacement for `clanker session export`. That feature produces a human-
  readable HTML file; snapcompact produces a machine-readable input for the model.
- Not streaming. The image is produced synchronously before the next turn starts.
  There is no partial-render or progressive loading.
- Not CJK / Latin-Extended bitmap coverage in v1. Non-ASCII bytes render as a
  box glyph.

## Design

**Config.**

```toml
[compaction]
strategy = "llm"           # default; set "snapcompact" to opt in

[snapcompact]
max_bytes    = 200000      # max PNG size before splitting
max_images   = 10          # max split images before falling back to LLM for the rest
font_size    = 5           # pixel width of each character cell (5 or 7)
line_height  = 8           # pixels per text line
fg           = "#e0e0e0"   # text color (hex); decided default
bg           = "#1a1a1a"   # background color; decided default
width        = 1200        # canvas width in pixels
```

**Pixel font.** A bitmapped 5×7 (or 7×9) font covering printable ASCII (0x20–
0x7e). The bitmap is a `[96][7]u8` comptime array where each `u8` is a row of
5 bits (MSB-first). Non-ASCII bytes are rendered as a small box glyph (decided
for v1). The font data is embedded at compile time so there are no file I/O
reads at runtime.

**Renderer (`src/agent/snapcompact.zig`).** Steps:

1. Serialise the truncated messages to a plain-text transcript format:
   `[role] content\n` per message, tool calls as `[tool: name] args\n[result]
   result\n`. This is the same visual format as `clanker session export`'s
   `<pre>` block, but that renderer lives in a WASM guest
   (`tools/zig/session_export.zig`) and is not callable from host code, so
   snapcompact carries its own serializer (or the renderer is extracted into
   shared code both can build against).
2. Break the text into lines at `width / (font_size + 1)` characters.
3. Compute canvas height: `line_height * line_count + 4` (top/bottom margin).
4. Allocate an RGBA pixel buffer (4 bytes per pixel).
5. Fill with `bg` color.
6. Blit each character from the font bitmap at the correct offset (box glyph for
   non-ASCII).
7. Encode as PNG using Zig's `std.compress.zlib` (raw deflate) with a minimal
   PNG chunk structure (IHDR, IDAT, IEND). No libpng dependency.

The PNG encoder is a direct implementation of PNG's chunk format:
`IHDR` (width, height, 8-bit depth, RGBA), `IDAT` (zlib-compressed filtered
rows), `IEND`. Filter type 0 (None) on every row keeps the implementation simple
at the cost of some compression ratio.

**Message insertion.** The compacted messages are replaced by one (or more, if
split) `{"role": "user", "content": [{"type": "image", "source": {"type":
"base64", "media_type": "image/png", "data": "<base64>"}}]}` messages, followed
by a `{"role": "assistant", "content": "I can see the conversation history
image."}` placeholder to keep the message sequence valid for providers that
require alternating roles.

The preamble line at the top of the image reads:
`[history: N messages, compacted <ISO8601 timestamp>]`

**Vision capability detection.** Before using snapcompact, the host runs the
existing `imageAttachmentsSupported` check (`src/cli.zig`) against the active
model's `capabilities` list (`src/config.zig`). A model whose capabilities
include `"image_in"` gets snapcompact. A model that declares capabilities but
omits `"image_in"` falls back to LLM compaction with a log warning. An empty
capabilities list means assumed-supported, so snapcompact proceeds.

**Provider reject → LLM fallback (decided).** If snapcompact proceeds (assumed
or declared support) and the provider rejects the image attachment at request
time, catch that error and fall back to LLM compaction for that compaction
event. Do not fail the user turn solely because the image was rejected. Log the
fallback clearly.

**Split limit.** When splitting, stop at `snapcompact.max_images` (default 10).
If content remains past that limit, fall back to LLM summarization for the
remaining messages and log the limit hit.

**Other renderer errors.** Allocation failure or encoding error falls back to
LLM summarization and logs the error. The session continues; no crash.

Memory/knowledge injection (PRD 0007) happens at `/api/run` task assembly,
before compaction runs, and is unaffected by this design.

**Stats integration.** `state/token_stats.jsonl` records are the closed `Record`
struct in `src/stats/tokens.zig` (ts, provider, model, token counts, cache
hit/miss, cost, duration), appended at a single choke point in
`src/llm/client.zig`; there is no event-type field today. Recording snapcompact
therefore requires a schema change: an optional `event` field on `Record` (set
to `"compact_snap"` here), plus optional `image_bytes` and `messages_compacted`
fields, all omitted when unset so existing records and readers are unaffected.
LLM-summarization compactions are ordinary LLM records today; distinguishing
them means tagging them `event = "compact_llm"` under the same schema change.
`clanker stats` shows both.

**Dependencies.**

- `maybeCompactMessages` path in `src/agent/loop.zig`.
- `imageAttachmentsSupported` / model `capabilities` (`src/cli.zig`,
  `src/config.zig`).
- Stats `Record` schema change in `src/stats/tokens.zig` (optional `event`,
  `image_bytes`, `messages_compacted`).
- Vision-capable provider for real use; LLM strategy remains the safe default.
- Optional shared transcript serializer with `session_export` (nice-to-have, not
  blocking).

**Implementation.**

1. **Pixel font + PNG encoder** (`pixelfont.zig` / encoder helpers): ASCII blit,
   box glyph for non-ASCII, deterministic IHDR/IDAT/IEND.
2. **`snapcompact.zig`**: transcript serialize → layout → render → split by
   `max_bytes` / `max_images`.
3. **Config**: `compaction.strategy` default `"llm"`; `[snapcompact]` with
   decided color defaults and `max_images = 10`.
4. **Loop integration**: strategy switch in `maybeCompactMessages`; capability
   check; provider-reject catch → LLM fallback.
5. **Stats**: optional `event` / `image_bytes` / `messages_compacted` on
   `Record`.
6. **Tests**: determinism, preamble pixels, split logic, capability fallback,
   provider-reject fallback, `max_images` limit.
7. **Deferred:** cost measurement vs LLM; narrower fonts; progressive
   re-render; expanded Unicode coverage.

## Failure modes

| Condition | Behaviour |
|---|---|
| Model declares `capabilities` without `image_in` | Falls back to LLM summarization; logs a `[snapcompact disabled: no image_in]` warning |
| Provider rejects image attachment at request time | Falls back to LLM summarization for that compaction; logs the reject; turn continues |
| Renderer allocation failure | Falls back to LLM summarization; logs the error |
| Rendered PNG exceeds `max_bytes` after splitting reaches `max_images` | Falls back to LLM summarization for the remaining messages; logs the limit hit |
| Model cannot read the image (returns a generic "I see an image" response) | No special handling; the model's next turn will have less context than expected. The session log shows the compact event so a human can diagnose |
| `strategy = "snapcompact"` but `compaction.strategy` key is misspelled in config | Config parse error at startup; clanker refuses to start |

## Acceptance criteria

- [ ] `compaction.strategy = "snapcompact"` in config activates the new path;
      `"llm"` (default) is unchanged.
- [ ] Default colors are `bg = "#1a1a1a"` and `fg = "#e0e0e0"`.
- [ ] Non-ASCII bytes render as a box glyph.
- [ ] The renderer produces a valid PNG for a 10-message transcript; the PNG
      opens in a standard image viewer and the text is readable.
- [ ] Determinism: two calls with identical input produce byte-for-byte identical
      PNGs.
- [ ] A session that hits `compact_threshold_bytes` with snapcompact configured
      inserts an image content block into the session messages instead of a
      summary text.
- [ ] The `[history: N messages, ...]` preamble is the first line of the
      rendered image text (verify by decoding the PNG pixels in a test).
- [ ] A model with a non-empty `capabilities` list omitting `image_in` falls
      back to LLM compaction; no PNG is generated. A model with an empty
      capabilities list proceeds with snapcompact (assumed-supported).
- [ ] A provider image rejection after assumed/declared support falls back to
      LLM compaction rather than failing the turn.
- [ ] An oversized transcript is split across multiple images, each under
      `max_bytes`, capped by `snapcompact.max_images` (default 10).
- [ ] `clanker stats` shows `compact_snap` events with `image_bytes` and
      `messages_compacted`.
- [ ] Unit tests cover: font bitmap blit (spot-check a known character), PNG
      chunk structure (IHDR/IDAT/IEND), image split logic, vision capability
      detection logic, provider-reject fallback.

## Open questions / future work

- **Non-ASCII glyph coverage.** CJK / Latin-Extended beyond the v1 box glyph
  remain future work.
- **Token cost measurement.** Measure real cost vs LLM summarization on
  clanker sessions before recommending snapcompact as a default.
- **Font fidelity.** Narrower fonts (3×5) or smaller `line_height` for denser
  tool output remain future tuning.
- **Progressive compaction.** Incrementally appending new rows to an existing
  image remains future work.
