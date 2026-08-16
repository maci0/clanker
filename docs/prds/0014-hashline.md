# PRD — Hashline edit format

## Status

Shipped. `read_file` accepts `hashes: true`; `edit_file` accepts
`op: "hashline"` with hunks of `{anchor_hash, anchor_line, old_count,
new_lines}`. Hashing and apply live in `tools/zig/hashline.zig` (host-
tested). Tolerance is the v1 default ±10. Sources of truth:
`tools/zig/hashline.zig`, `tools/zig/read_file.zig`,
`tools/zig/edit_file.zig`, and the two manifests.

## Problem

`edit_file`'s exact-text replacement (`{path, old, new}`) requires the model to
reproduce the anchor text verbatim. On long files the model often drifts by a
space, a comment, or a line ending. The resulting "the `old` text does not
appear in the file" error is the most frequent `edit_file` failure recorded in
`state/autolearn.jsonl` (dozens of no-exact-match failures at the time of
writing, and the log grows). The model retries, burning more tokens and often
making the same mistake.

omp's hashline format sidesteps this by replacing exact anchor text with 4-hex
xxHash32 digests of each line. The model emits hashes it read from the file; the
host verifies them before patching. Stale patches (the file changed since the
model read it) are rejected with a clear error rather than silently applying to
the wrong location. omp's own benchmarks show Grok 4 Fast used -61% output
tokens in the hashline mode and Grok Code Fast improved pass@1 from 6.7% to
68.3%.

## Goals

1. `read_file` gains a `hashes: true` option that annotates each output line with
   a 4-hex xxHash32 digest of that line's bytes (before the line ending).
2. `edit_file` gains an `op` field dispatching to a new `hashline` operation
   where anchor lines are identified by their hash tag rather than their text
   content. Today's `edit_file` has no `op` field and no modes (its schema is
   `{path, old, new, create, content, overwrite}`), so introducing the `op`
   dispatch is itself a design step this PRD takes, not an extension of an
   existing one.
3. The host validates that every anchor hash in a `hashline` patch matches the
   current file before applying any hunk; a single mismatch rejects the entire
   patch with a message naming the line number and the expected vs. actual hash.
4. The format is backwards-compatible: `read_file` without `hashes: true` and
   `edit_file` calls using the existing `{path, old, new}` replacement (no `op`
   field) are unchanged.
5. Hash computation uses the xxHash32 algorithm (already available via the Zig
   standard library's `std.hash.XxHash32`) formatted as exactly 4 lowercase hex
   characters (lower 16 bits, zero-padded). v1 is 4-hex only; no wide-hash mode.
6. On a successful `hashline` edit, the tool returns the new 4-hex hashes (and
   line numbers) for the written region so the model can chain a follow-up edit
   without re-reading the whole file.
7. System prompt / tool manifests always mention `hashes: true` and the
   `hashline` op so the model knows the pairing exists without requesting it.

## Non-goals

- Not replacing the existing `{path, old, new}` replacement. Both coexist; the
  system prompt recommends `hashline` for any file read via `read_file` with
  `hashes: true`.
- Not a general diff format. Hashline anchors identify lines to replace; the
  replacement content is still plain text. Structural merge (3-way, patch hunks)
  is out of scope.
- Not covering binary files. Hashline is for text files only. `read_file` with
  `hashes: true` on a binary file returns the same error it returns today for
  large binaries.
- Not a version-control primitive. Hashline detects staleness within a single
  agent turn; it is not a substitute for git-level conflict detection across
  concurrent writers.
- Not 8-hex / full 32-bit hashes in v1. Width stays 4 hex chars; a wider mode
  is future work only if false-positive anchors show up in practice.

## Design

**Hash format (decided: 4-hex only).** xxHash32 over the line's bytes (not
including `\n` or `\r\n`), lower 16 bits, formatted as exactly four lowercase
hex digits. Example: `a3f1`. The 16-bit truncation keeps the output short (omp
uses 4 hex chars) while remaining sufficient to catch accidental mismatches in
practice; a deliberate collision attack is irrelevant here because the attacker
is the LLM itself and would have to corrupt its own patch.

**Tolerance (decided).** Search window is ±10 lines around `anchor_line`,
hardcoded in v1 (not per call). A `edit.hashline_tolerance` config key is still
open if a later eval needs it retuned.

**`read_file` output with `hashes: true`.**

```
0001 a3f1  fn main() void {
0002 c7de      std.debug.print("hello\n", .{});
0003 0012  }
```

Format per line: `{line_number:04} {hash:4}  {content}`. The line number and
hash are separated from content by two spaces so a human can visually parse them.
The hash covers only `content` (the bytes after the two-space separator are not
part of the hash input; `content` is the raw file bytes for that line).

**`edit_file` hashline operation.** Input JSON:

```json
{
  "op": "hashline",
  "path": "src/main.zig",
  "hunks": [
    {
      "anchor_hash": "a3f1",
      "anchor_line": 1,
      "old_count": 3,
      "new_lines": [
        "fn main() void {",
        "    std.debug.print(\"world\\n\", .{});",
        "}"
      ]
    }
  ]
}
```

`anchor_hash` is the 4-hex hash of the first line of the replaced region.
`anchor_line` is advisory (the model's recollection of the line number) and is
used to narrow the search, not as the authoritative location. The host:

1. Opens the file and computes hashes for all lines.
2. For each hunk, searches for `anchor_hash` starting at `anchor_line` with
   a hardcoded ±10 window to handle minor shifts.
3. Verifies that `old_count` consecutive lines starting at the found anchor all
   match the hashes the model would have seen (recomputed from the file's current
   bytes).
4. If all anchors verify: applies the hunks in reverse line-number order (largest
   offset first) so earlier hunks do not shift later anchors.
5. If any anchor fails: rejects the entire patch without writing anything.
6. On success: returns the new hashes and line numbers for each applied region
   (write-back), so a chained edit can proceed without a full re-read.

**Success response (decided: write-back hashes).** Example:

```json
{
  "ok": true,
  "hunks": [
    {
      "start_line": 1,
      "hashes": ["a3f1", "b91c", "0012"]
    }
  ]
}
```

**Rejection message.** On mismatch:

```
hashline mismatch at line 3: expected hash c7de, got 9a12
(file may have changed since it was read)
```

This is the same error style as the existing replacement's "the `old` text does
not appear in the file": actionable enough for the model to re-read and retry.

**Multi-hunk atomicity.** All hunks are validated before any write. A partial
write (first hunk applied, second fails) is not possible.

**System / manifest mention (decided: always).** Both tool manifests'
`llm_description` (and the default system prompt) always describe `hashes: true`
and `op: "hashline"`. The pairing is not gated on the model "requesting" an
edit first.

**Manifest changes.** Both tools stay WASM with the same sandbox policy. The
manifests gain a new `hashline` entry in their `description` and the
model-facing text in each manifest's `llm_description` field is updated to
mention `hashes: true` and the `hashline` operation.

**Config.** v1 has no config key: the ±10 tolerance is hardcoded in
`tools/zig/edit_file.zig` (see Tolerance above).

**Dependencies.**

- `tools/zig/read_file.zig` and `tools/zig/edit_file.zig` (and their manifests).
- `std.hash.XxHash32` (already in the Zig stdlib); no new hash dependency.
- Default system prompt / tool description injection path so hashline is always
  advertised.
- Existing `edit_file` `{path, old, new}` path must keep working unchanged
  (regression surface for evals).

**Implementation.**

1. **Hash helper**: shared xxHash32 → 4-hex formatting used by both tools;
   unit-test against a known input/output pair.
2. **`read_file`**: add `hashes: true` output format; binary-file error path
   unchanged.
3. **`edit_file`**: add `op` dispatch; implement `hashline` validate-then-apply
   with the hardcoded ±10 window; return write-back hashes on success.
4. **Manifests + system prompt**: always mention hashes/hashline.
5. **Config**: no config key in v1; the ±10 window is hardcoded (see Tolerance).
6. **Tests / evals**: tolerance window, multi-hunk reverse apply, mismatch
   rejection, returned hashes, no regression on plain edits.

## Failure modes

| Condition | Behaviour |
|---|---|
| Anchor hash not found within tolerance window | Patch rejected; message names the missing hash and the search range |
| `old_count` extends past end of file | Patch rejected; message names the hunk and file length |
| Multiple lines match the anchor hash | First match within the tolerance window is used; if two are equally near, the one closest to `anchor_line` wins |
| File modified between `read_file` and `edit_file` calls | Hash mismatch detected and patch rejected with a staleness message |
| `hashes: true` on a file with lines longer than 1 MB | Line is hashed normally; no special treatment (the hash covers the raw bytes regardless of length) |
| `op: "hashline"` on a file that was not read with `hashes: true` | No error; the model just has to supply correct hashes. If it supplies wrong hashes it gets a mismatch error |

## Acceptance criteria

- [x] `read_file` with `{"hashes": true}` returns output annotated with
      `{line:04} {hash:4}  {content}` for every line.
- [x] Hash computation is `xxHash32(line_bytes) & 0xFFFF` formatted as 4-char
      lowercase hex, verified by a unit test against a known input/output pair.
- [x] `edit_file` with `op: "hashline"` applies a valid patch to a file and
      produces the correct result.
- [x] A successful `hashline` edit returns new hashes (and start line) for each
      applied hunk so a follow-up edit can proceed without re-reading.
- [x] A hunk with a wrong `anchor_hash` is rejected with an error naming the
      line and the hash mismatch; the file is not modified.
- [x] A multi-hunk patch with one valid and one invalid hunk is rejected in
      full; the file is not modified.
- [x] Plain `{path, old, new}` edits and plain `read_file` (no `hashes`)
      continue to work unchanged; no regression in existing eval coverage.
- [x] Hash-tag anchoring (Goal 2) tolerates ±10 lines of drift: an anchor that
      shifted 5 lines from `anchor_line` still resolves. v1 hardcodes ±10; an
      `edit.hashline_tolerance` key remains open if an eval later needs it
      retuned.
- [x] System prompt and tool manifests always mention `hashes: true` /
      `hashline` (not opt-in advertising).
- [x] Unit tests cover: hash computation, read output format, single-hunk apply,
      multi-hunk apply in reverse order, mismatch rejection, tolerance-window
      search, write-back hash response.

## Open questions / future work

- **Wide hash mode.** An 8-hex / `wide_hash` option if 4-hex false positives
  appear in dense files.
- **Auto-upgrade transform.** A skill or transform that upgrades a plain
  read-then-edit sequence to hashline automatically remains future work.
- **Tolerance retune.** Revisit `edit.hashline_tolerance` (±10) only if evals
  show systematic misses or wrong-anchor hits.
