// text_diff — a unified diff between two text blobs.
// Input:  {"a": "...", "b": "...", "context": 3, "a_name": "a", "b_name": "b"}
//         context (lines of context per hunk) defaults to 3; a_name/b_name
//         default to "a"/"b" and label the --- / +++ header lines.
// Output: {"ok": true, "text": "<unified diff, or \"(identical)\">"}
//         {"ok": false, "error": "..."} if either side exceeds the line cap
//
// Line-based LCS diff (dynamic programming, O(n*m) time and table size).
// The table is the memory cost that matters here, so both sides are capped
// at max_lines: past that, the guest's 16 MiB linear memory budget (see
// runtime.zig's max_memory_pages) is the wrong place to find out the table
// did not fit.

import { scratch, host_arena, readInput, okText, fail } from "./lib";
import { parseJSON, JKind } from "./json";

export { scratch, host_arena };

const max_lines: i32 = 800;

export function run(ptr: u32, len: u32): u64 {
  const input = readInput(ptr, len);
  const req = parseJSON(input);
  if (!req.ok || req.value.kind != JKind.Obj) return fail("expected a JSON object with \"a\" and \"b\"");

  const aField = req.value.get("a");
  const bField = req.value.get("b");
  if (aField == null || aField.kind != JKind.Str) return fail('missing "a" (string)');
  if (bField == null || bField.kind != JKind.Str) return fail('missing "b" (string)');

  let context: i32 = 3;
  const c = req.value.get("context");
  if (c != null && c.kind == JKind.Num) context = <i32>c.n;
  if (context < 0) context = 0;

  let aName = "a";
  let bName = "b";
  const an = req.value.get("a_name");
  if (an != null && an.kind == JKind.Str) aName = an.s;
  const bn = req.value.get("b_name");
  if (bn != null && bn.kind == JKind.Str) bName = bn.s;

  const aLines = splitLines(aField.s);
  const bLines = splitLines(bField.s);
  if (aLines.length > max_lines || bLines.length > max_lines) {
    return fail("input has more than " + max_lines.toString() + " lines; diff a smaller range");
  }

  const diff = unifiedDiff(aLines, bLines, aName, bName, context);
  return okText(diff.length == 0 ? "(identical)" : diff);
}

function splitLines(s: string): string[] {
  if (s.length == 0) return [];
  // A trailing newline does not produce a spurious empty final line, the
  // same convention `diff` itself uses.
  const body = s.endsWith("\n") ? s.substring(0, s.length - 1) : s;
  return body.split("\n");
}

// Op values: 0 = equal, 1 = delete (in a, not b), 2 = insert (in b, not a).
const OP_EQUAL: i32 = 0;
const OP_DEL: i32 = 1;
const OP_INS: i32 = 2;

/// Longest-common-subsequence line diff, returned as parallel op/text
/// arrays in output order (a's deletions and b's insertions already
/// interleaved the way a human reading a diff expects).
function diffOps(a: string[], b: string[]): Array<i32[]> {
  const n = a.length;
  const m = b.length;
  const width = m + 1;
  const dp = new Int32Array((n + 1) * width);
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      if (a[i] == b[j]) {
        dp[i * width + j] = dp[(i + 1) * width + (j + 1)] + 1;
      } else {
        const down = dp[(i + 1) * width + j];
        const right = dp[i * width + (j + 1)];
        dp[i * width + j] = down >= right ? down : right;
      }
    }
  }

  const ops: i32[] = [];
  const idxs: i32[] = []; // index into a (for del/equal) or b (for ins)
  let i: i32 = 0;
  let j: i32 = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      ops.push(OP_EQUAL);
      idxs.push(i);
      i++;
      j++;
    } else if (dp[(i + 1) * width + j] >= dp[i * width + (j + 1)]) {
      ops.push(OP_DEL);
      idxs.push(i);
      i++;
    } else {
      ops.push(OP_INS);
      idxs.push(j);
      j++;
    }
  }
  while (i < n) {
    ops.push(OP_DEL);
    idxs.push(i);
    i++;
  }
  while (j < m) {
    ops.push(OP_INS);
    idxs.push(j);
    j++;
  }
  return [ops, idxs];
}

function unifiedDiff(a: string[], b: string[], aName: string, bName: string, context: i32): string {
  const result = diffOps(a, b);
  const ops = result[0];
  const idxs = result[1];
  const n = ops.length;

  const changedPos: i32[] = [];
  for (let k = 0; k < n; k++) if (ops[k] != OP_EQUAL) changedPos.push(k);
  if (changedPos.length == 0) return "";

  // Merge changed positions into hunk ranges: consecutive changes within
  // 2*context of each other share one hunk (the rule `diff -u` itself
  // uses, so two nearby edits do not print as two overlapping hunks).
  const hunkStarts: i32[] = [];
  const hunkEnds: i32[] = [];
  let curStart = changedPos[0];
  let curEnd = changedPos[0];
  for (let k = 1; k < changedPos.length; k++) {
    const p = changedPos[k];
    if (p - curEnd <= context * 2) {
      curEnd = p;
    } else {
      hunkStarts.push(curStart);
      hunkEnds.push(curEnd);
      curStart = p;
      curEnd = p;
    }
  }
  hunkStarts.push(curStart);
  hunkEnds.push(curEnd);

  let out = "--- " + aName + "\n+++ " + bName + "\n";
  for (let h = 0; h < hunkStarts.length; h++) {
    let start = hunkStarts[h] - context;
    if (start < 0) start = 0;
    let end = hunkEnds[h] + context;
    if (end > n - 1) end = n - 1;
    out += hunkHeader(ops, idxs, start, end);
    for (let p = start; p <= end; p++) {
      const text = ops[p] == OP_INS ? b[idxs[p]] : a[idxs[p]];
      const prefix = ops[p] == OP_EQUAL ? " " : ops[p] == OP_DEL ? "-" : "+";
      out += prefix + text + "\n";
    }
  }
  return out;
}

function hunkHeader(ops: i32[], idxs: i32[], start: i32, end: i32): string {
  let aStart: i32 = -1;
  let aCount: i32 = 0;
  let bStart: i32 = -1;
  let bCount: i32 = 0;
  for (let p = start; p <= end; p++) {
    if (ops[p] == OP_DEL || ops[p] == OP_EQUAL) {
      if (aStart < 0) aStart = idxs[p];
      aCount++;
    }
    if (ops[p] == OP_INS || ops[p] == OP_EQUAL) {
      if (bStart < 0) bStart = idxs[p];
      bCount++;
    }
  }
  if (aStart < 0) aStart = 0;
  if (bStart < 0) bStart = 0;
  return "@@ -" + (aStart + 1).toString() + "," + aCount.toString() +
    " +" + (bStart + 1).toString() + "," + bCount.toString() + " @@\n";
}
