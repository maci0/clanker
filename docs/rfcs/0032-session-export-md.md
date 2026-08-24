# RFC 0032 — How session export grows a markdown form

## Status

Decided — 2026-08-21. ADR 0044

## Overview

Kimi Code /export-md writes a human-readable markdown file. Clanker session export is HTML-only. Decide a second renderer that does not re-parse untrusted text as HTML.

## Options considered

Sources opened: kimi docs/en/guides/sessions.md Exporting a session (2026-08-21); tools/zig/session_export_logic.zig (HTML, escape, no markdown re-render).

### Option A — format=md on the existing session_export guest, preformatted text

What it is: second renderer in session_export_logic.zig. Role headings plus fenced bodies. Escape is not HTML entities; markdown special chars in untrusted text stay literal inside fences. No CommonMark parse of model output.

How it would fit: session_export op format html|md; clanker session export --format md; TUI /export-md later.

Pros: one guest; HTML path unchanged; host-tested.

Cons: two renderers to keep in lockstep on new message fields.

Cost to adopt: format switch + tests with hostile <script> and ```. Cost to leave: drop md.

Evidence: session_export_logic.zig doc comment; sessions.md /export-md.

### Option B — a new export_md guest

What it is: second tool.

Pros: HTML guest untouched.

Cons: two implementations of session shape.

### Option C — status quo

What it is: HTML only.

Pros: one escaper.

Cons: no markdown share.

### Option D — out of the box: session_search + copy

What it is: humans copy from the TUI.

Pros: zero code.

Cons: not a file.

## Implications by horizon

### Short term
- **If A:** clanker session export --format md writes a .md file.
- **If B:** extra guest.
- **If status quo:** HTML remains.

### Medium term
- **If A:** TUI /export-md.
- **If B:** drift.
- **If status quo:** operators convert HTML by hand.

### Long term
- **If A:** HTML stays the safe share; md is the readable one.
- **If B:** two guests forever.
- **If status quo:** fine for file:// HTML.

## Next steps / action items

- [ ] ADR: markdown export is a second renderer in the same guest
- [ ] PRD: format=md phase 1 on the CLI; TUI later

## Recommendation

**Recommended option:** Adopt Option A: format=md on the existing session_export guest, preformatted text

**Confidence:** 9/10

**Rationale.** One guest, HTML unchanged, no CommonMark parse of untrusted text. A second guest would duplicate session shape.

## References

- Research: [Research — Kimi Code CLI feature inventory for clanker](../research/kimi-code-features.md) — read 2026-08-21. Its claims are unverified here until each is checked against the source it cites (the URL, repository, or file — the note itself is not the source).

