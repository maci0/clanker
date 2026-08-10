// calc_ts — a clanker tool written in AssemblyScript.
//
// ABI (matches the harness):
//   exports: scratch(need: u32) -> u32, host_arena() -> u32, run(ptr, len) -> u64
//   imports: env.ck_log / env.ck_now (optional; shown for reference)
//
// Input protocol (simple, JSON-free): "<a> <op> <b>" text, e.g. "17*23".
// Output: packed (out_ptr << 32) | out_len of the decimal result string.

// ---- host imports (provided by the clanker harness) -------------------------
@external("env", "ck_log")
declare function ck_log(level: u32, ptr: u32, len: u32): void;

@external("env", "ck_now")
declare function ck_now(): u64;

// ---- buffers ----------------------------------------------------------------
const BUF: u32 = 65536;

let scratch_ptr: usize = 0;
let arena_ptr: usize = 0;
let out_view: Uint8Array | null = null;
let out_ptr: usize = 0;

function ensureScratch(): usize {
  if (scratch_ptr == 0) scratch_ptr = new Uint8Array(BUF).dataStart;
  return scratch_ptr;
}

export function scratch(need: u32): u32 {
  if (need > BUF) return 0;
  return <u32>ensureScratch();
}

export function host_arena(): u32 {
  if (arena_ptr == 0) arena_ptr = new Uint8Array(BUF).dataStart;
  return <u32>arena_ptr;
}

function ensureOut(): usize {
  if (out_ptr == 0) {
    out_view = new Uint8Array(BUF);
    out_ptr = out_view!.dataStart;
  }
  return out_ptr;
}

// ---- helpers -----------------------------------------------------------------
function log(level: u32, msg: string): void {
  const bytes = String.UTF8.encode(msg);
  ck_log(level, changetype<usize>(bytes), bytes.byteLength);
}

function parseInt(s: string): i64 {
  let v: i64 = 0;
  let started = false;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c == 32 || c == 9) { // skip spaces/tabs
      if (started) break;
      continue;
    }
    if (c < 48 || c > 57) return -1; // invalid digit
    started = true;
    v = v * 10 + <i64>(c - 48);
  }
  return started ? v : -1;
}

// ---- tool entry -------------------------------------------------------------
// Crude JSON extraction: accepts either raw "17*23" or {"expr": "17*23"}.
function extractExpr(raw: string): string {
  const idx = raw.indexOf("\"expr\"");
  if (idx < 0) return raw;
  const colon = raw.indexOf(":", idx);
  if (colon < 0) return raw;
  const firstQuote = raw.indexOf("\"", colon);
  if (firstQuote < 0) return raw;
  const endQuote = raw.indexOf("\"", firstQuote + 1);
  if (endQuote < 0) return raw;
  return raw.substring(firstQuote + 1, endQuote);
}

export function run(ptr: u32, len: u32): u64 {
  // copy input bytes into a string
  const input = extractExpr(String.UTF8.decodeUnsafe(ptr, len));

  // parse "<a><op><b>" — find the operator character
  const ops = "+-*/";
  let opIdx = -1;
  for (let i = 0; i < input.length; i++) {
    if (ops.indexOf(input.charAt(i)) >= 0) {
      opIdx = i;
      break;
    }
  }
  if (opIdx <= 0 || opIdx >= input.length - 1) {
    return fail("expected input like 17*23");
  }
  const op = input.charAt(opIdx);
  const a = parseInt(input.substring(0, opIdx));
  const b = parseInt(input.substring(opIdx + 1));
  if (a == -1 || b == -1) return fail("non-numeric operand");

  let result: i64;
  if (op == "+") result = a + b;
  else if (op == "-") result = a - b;
  else if (op == "*") result = a * b;
  else if (op == "/") {
    if (b == 0) return fail("division by zero");
    result = a / b;
  } else return fail("unknown op");

  const outText = result.toString();
  const bytes = String.UTF8.encode(outText);
  const dst = ensureOut();
  for (let i = 0; i < bytes.byteLength; i++) {
    store<u8>(dst + i, load<u8>(changetype<usize>(bytes) + i));
  }
  log(0, "calc_ts: " + input + " = " + outText);
  return (<u64>dst << 32) | <u64>bytes.byteLength;
}

function fail(msg: string): u64 {
  log(2, "calc_ts error: " + msg);
  const errText = "{\"ok\":false,\"error\":\"" + msg + "\"}";
  const bytes = String.UTF8.encode(errText);
  const dst = ensureOut();
  for (let i = 0; i < bytes.byteLength; i++) {
    store<u8>(dst + i, load<u8>(changetype<usize>(bytes) + i));
  }
  return (<u64>dst << 32) | <u64>bytes.byteLength;
}
