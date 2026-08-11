// json_tool — validate, pretty-print, or minify arbitrary JSON.
// Input:  {"json": "...", "mode": "validate"|"pretty"|"minify"} (mode
//         defaults to "pretty")
// Output: {"ok": true, "text": "<formatted JSON, or \"valid\" for validate>"}
//         {"ok": false, "error": "<message>:<line>:<col>"} on a parse error

import { scratch, host_arena, readInput, okText, fail } from "./lib";
import { parseJSON, stringify, JKind } from "./json";

export { scratch, host_arena };

export function run(ptr: u32, len: u32): u64 {
  const input = readInput(ptr, len);
  const req = parseJSON(input);
  if (!req.ok || req.value.keys.length == 0) {
    // Also accept the bare JSON text itself, unwrapped, the way calc_ts
    // accepts a bare expression alongside {"expr": "..."} — a caller
    // formatting a blob it already has should not have to escape it into a
    // second layer of JSON just to hand it to this tool.
    return runOn(input, "pretty");
  }
  const jsonField = req.value.get("json");
  const modeField = req.value.get("mode");
  const target = jsonField != null && jsonField.kind == JKind.Str ? jsonField.s : input;
  const mode = modeField != null && modeField.kind == JKind.Str ? modeField.s : "pretty";
  return runOn(target, mode);
}

function runOn(target: string, mode: string): u64 {
  const parsed = parseJSON(target);
  if (!parsed.ok) {
    return fail(parsed.errorMsg + " at line " + parsed.line.toString() + ", column " + parsed.col.toString());
  }
  if (mode == "validate") return okText("valid");
  if (mode == "minify") return okText(stringify(parsed.value, -1));
  return okText(stringify(parsed.value, 2));
}
