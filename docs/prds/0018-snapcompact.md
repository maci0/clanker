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
   LLM summarizer in `maybeCompactMessages`.
2. The renderer produces a deterministic PNG: given the same messages JSON, it
   always produces the same bytes. No external deps; a pure-Zig pixel-font
   renderer.
3. The PNG is inserted as a multimodal message (image content block) in place of
   the truncated messages. The image carries a preamble line: `[conversation
   history — <N> messages — rendered at <timestamp>]`.
4. The strategy is skipped (falls back to LLM summarization) if the configured
   model does not support image input. Detection reuses the existing mechanism:
   the model's `capabilities` list (`src/config.zig`) containing `"image_in"`,
   as checked by `imageAttachmentsSupported` (`src/cli.zig`). An empty
   capabilities list means assumed-supported, so snapcompact only falls back
   when a model declares capabilities and omits `image_in`.
5. Image size is bounded: if the rendered PNG exceeds `snapcompact.max_bytes`
   (default 200000), the renderer splits across multiple images, each as a
   separate content block.
6. Snapcompact is opt-in. `compaction.strategy = "llm"` is the default and
   remains unchanged.

## Non-goals

- Not a general image renderer. The renderer exists only for conversation
  compaction. It is not exposed as a tool or callable from outside the compaction
  path.
- Not using system fonts or any external font library. The pixel font is a
  bitmapped 5x7 or similar fixed-width grid embedded as a Zig comptime literal.
  No TTF loading, no HarfBuzz, no FreeType.
- Not visually styled. The output is a dark-on-light (or configurable) monospace
  grid, maximum information density, no padding beyond what readability requires.
  It is a transcript image, not a UI component.
- Not a replacement for `clanker session export`. That feature produces a human-
  readable HTML file; snapcompact produces a machine-readable input for the model.
- Not streaming. The image is produced synchronously before the next turn starts.
  There is no partial-render or progressive loading.

## Design

**Config.**

```toml
[compaction]
strategy = "snapcompact"   # "llm" (default) or "snapcompact"

[snapcompact]
max_bytes    = 200000      # max PNG size before splitting
font_size    = 5           # pixel width of each character cell (5 or 7)
line_height  = 8           # pixels per text line
fg           = "#e0e0e0"   # text color (hex)
bg           = "#1a1a1a"   # background color
width        = 1200        # canvas width in pixels
```

**Pixel font.** A bitmapped 5×7 (or 7×9) font covering printable ASCII (0x20–
0x7e). The bitmap is a `[96][7]u8` comptime array where each `u8` is a row of
5 bits (MSB-first). Non-ASCII bytes are rendered as a small box glyph. The font
data is embedded at compile time so there are no file I/O reads at runtime.

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
6. Blit each character from the font bitmap at the correct offset.
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
capabilities list means assumed-supported, so snapcompact proceeds; if the
provider then rejects the image, that surfaces as a turn error the same way
any unsupported image attachment does today.

**Fallback.** Any error in the renderer (allocation failure, encoding error) falls
back to LLM summarization and logs the error. The session continues; no crash.

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

## Failure modes

| Condition | Behaviour |
|---|---|
| Model declares `capabilities` without `image_in` | Falls back to LLM summarization; logs a `[snapcompact disabled: no image_in]` warning |
| Renderer allocation failure | Falls back to LLM summarization; logs the error |
| Rendered PNG exceeds `max_bytes` after splitting reaches 10 images | Falls back to LLM summarization for the remaining messages; logs the limit hit |
| Model cannot read the image (returns a generic "I see an image" response) | No special handling; the model's next turn will have less context than expected. The session log shows the compact event so a human can diagnose |
| `strategy = "snapcompact"` but `compaction.strategy` key is misspelled in config | Config parse error at startup; clanker refuses to start |

## Acceptance criteria

- [ ] `compaction.strategy = "snapcompact"` in config activates the new path;
      `"llm"` (default) is unchanged.
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
- [ ] An oversized transcript is split across multiple images, each under
      `max_bytes`.
- [ ] `clanker stats` shows `compact_snap` events with `image_bytes` and
      `messages_compacted`.
- [ ] Unit tests cover: font bitmap blit (spot-check a known character), PNG
      chunk structure (IHDR/IDAT/IEND), image split logic, vision capability
      detection logic.

## Open questions / future work

- **Token cost measurement.** The claim that snapcompact uses ~1/3 the tokens of
  LLM summarization is from omp's benchmarks on a different codebase with
  different models. Measuring the actual cost difference on clanker's own sessions
  is necessary before recommending it as the default.
- **Font fidelity.** A 5×7 bitmapped font at 1200px width holds approximately
  240 characters per line. For long tool outputs (JSON blobs, stack traces) this
  may require many lines and large images. A narrower font (3×5) or smaller
  line_height would fit more text per image.
- **Color inversion for light-mode providers.** Some model providers process
  images with assumptions about light backgrounds. Whether `bg = "#1a1a1a"` (dark)
  is better or worse for model comprehension than `bg = "#ffffff"` is not known;
  this should be a measured config option, not a hardcoded choice.
- **Non-ASCII content.** Tool results often contain Unicode (paths, model output).
  The current plan renders non-ASCII as box glyphs. A CJK extension or a Latin-
  Extended subset in the bitmap font would improve handling of common characters.
- **Progressive compaction.** Currently the whole truncated window is rendered at
  once. Incrementally appending new compacted messages to an existing image (re-
  rendering only the new rows) would reduce per-compaction cost, at the expense
  of more complex state tracking.
