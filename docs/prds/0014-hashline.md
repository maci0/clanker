# PRD — Hashline edit format

## Status

Draft. No source files yet. Affects `tools/zig/read_file.zig`,
`tools/zig/edit_file.zig`, and their manifests
(`tools/manifests/read_file.tool.json`, `tools/manifests/edit_file.tool.json`).

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
   characters (lower 16 bits, zero-padded).

## Non-goals

- Not replacing the existing `{path, old, new}` replacement. Both coexist; the
  system prompt can recommend `hashline` for any file read via `read_file` with
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

## Design

**Hash format.** xxHash32 over the line's bytes (not including `\n` or `\r\n`),
lower 16 bits, formatted as exactly four lowercase hex digits. Example:
`a3f1`. The 16-bit truncation keeps the output short (omp uses 4 hex chars) while
remaining sufficient to catch accidental mismatches in practice; a deliberate
collision attack is irrelevant here because the attacker is the LLM itself and
would have to corrupt its own patch.

**`read_file` output with `hashes: true`.**

```
0001 a3f1  fn main() void {
0002 c7de      std.debug.print("hello\n", .{});
0003 0012  }
```

Format per line: `{line_number:04} {hash:4}  {content}`. The line number and
hash are separated from content by two spaces so a human can visually parse them.
The hash covers only `content` (the bytes after the two-space separator are not
part of the hash input — `content` is the raw file bytes for that line).

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
2. For each hunk, searches for `anchor_hash` starting at `anchor_line - 1` (with
   a small tolerance window, default ±10 lines) to handle minor shifts.
3. Verifies that `old_count` consecutive lines starting at the found anchor all
   match the hashes the model would have seen (recomputed from the file's current
   bytes).
4. If all anchors verify: applies the hunks in reverse line-number order (largest
   offset first) so earlier hunks do not shift later anchors.
5. If any anchor fails: rejects the entire patch without writing anything.

**Rejection message.** On mismatch:

```
hashline mismatch at line 3: expected hash c7de, got 9a12
(file may have changed since it was read)
```

This is the same error style as the existing replacement's "the `old` text does
not appear in the file": actionable enough for the model to re-read and retry.

**Multi-hunk atomicity.** All hunks are validated before any write. A partial
write (first hunk applied, second fails) is not possible.

**Manifest changes.** Both tools stay WASM with the same sandbox policy. The
manifests gain a new `hashline` entry in their `description` and the
model-facing text in each manifest's `llm_description` field is updated to
mention `hashes: true` and the `hashline` operation.

## Failure modes

| Condition | Behaviour |
|---|---|
| Anchor hash not found within tolerance window | Patch rejected; message names the missing hash and the search range |
| `old_count` extends past end of file | Patch rejected; message names the hunk and file length |
| Multiple lines match the anchor hash | First match within the tolerance window is used; if two are equally near, the one closest to `anchor_line` wins |
| File modified between `read_file` and `edit_file` calls | Hash mismatch detected and patch rejected with a staleness message |
| `hashes: true` on a file with lines longer than 1 MB | Line is hashed normally; no special treatment — the hash covers the raw bytes regardless of length |
| `op: "hashline"` on a file that was not read with `hashes: true` | No error; the model just has to supply correct hashes. If it supplies wrong hashes it gets a mismatch error |

## Acceptance criteria

- [ ] `read_file` with `{"hashes": true}` returns output annotated with
      `{line:04} {hash:4}  {content}` for every line.
- [ ] Hash computation is `xxHash32(line_bytes) & 0xFFFF` formatted as 4-char
      lowercase hex, verified by a unit test against a known input/output pair.
- [ ] `edit_file` with `op: "hashline"` applies a valid patch to a file and
      produces the correct result.
- [ ] A hunk with a wrong `anchor_hash` is rejected with an error naming the
      line and the hash mismatch; the file is not modified.
- [ ] A multi-hunk patch with one valid and one invalid hunk is rejected in
      full; the file is not modified.
- [ ] Plain `{path, old, new}` edits and plain `read_file` (no `hashes`)
      continue to work unchanged; no regression in existing eval coverage.
- [ ] The tolerance window (default ±10) finds an anchor that shifted by 5
      lines from `anchor_line`.
- [ ] Unit tests cover: hash computation, read output format, single-hunk apply,
      multi-hunk apply in reverse order, mismatch rejection, tolerance-window
      search.

## Open questions / future work

- **Tolerance window size.** ±10 is a guess. omp's choice is unknown. Too wide
  risks matching the wrong anchor in dense repetitive files; too narrow breaks on
  files with many preceding edits. Worth measuring against the existing `evals/`
  edit cases.
- **Hash width.** 16 bits gives 1/65536 false-positive rate per line. For files
  with tens of thousands of identical-hash lines (highly unlikely in practice),
  this could cause wrong-anchor matches. A `wide_hash: true` option emitting
  full 32-bit (8 hex chars) could address this if it becomes a real issue.
- **System prompt recommendation.** Should the default system prompt always
  include the `read_file` + `hashline` pairing, or only when the model requests
  an edit? A skill or transform that automatically upgrades a plain read-then-
  edit sequence is worth exploring.
- **Write-back hash update.** After a successful `hashline` edit, should the
  tool return the new hashes for the affected lines so the model can chain a
  second edit without re-reading? This would save one `read_file` call per
  multi-pass edit.
