// lib.ts — shared AssemblyScript host bindings for clanker tools.
//
// Mirrors what tools/zig/lib.zig does for the Zig side: every tool below
// imports the scratch/host_arena/out plumbing from here instead of
// hand-rolling the buffer bookkeeping and byte-copy loops calc_ts.ts wrote
// out in full before this existed. Not a tool itself — no `run` export — so
// it is excluded from package.json's build:all and verify.sh, the same way
// env.d.ts already is.
//
// ABI recap (see calc_ts.ts's header for the fuller version): a tool
// exports scratch(need) -> ptr, host_arena() -> ptr, run(ptr, len) -> u64
// (packed (out_ptr << 32) | out_len), and imports whichever env.ck_* host
// functions it calls.

// ---- host function imports (provided by the harness) ----------------------
@external("env", "ck_log")
declare function ck_log(level: u32, ptr: u32, len: u32): void;
@external("env", "ck_now")
declare function ck_now(): u64;
@external("env", "ck_random")
declare function ck_random(): u64;

const BUF: u32 = 65536;

// Views are held at module scope, not just their addresses: taking
// .dataStart from a temporary leaves nothing referencing the backing
// array, so the collector frees it and the next allocation reuses that
// memory — the host would then be reading/writing through a pointer whose
// backing store is gone. calc_ts.ts hit exactly this before it was noticed.
let scratch_view: Uint8Array | null = null;
let scratch_ptr: usize = 0;
let arena_view: Uint8Array | null = null;
let arena_ptr: usize = 0;
let out_view: Uint8Array | null = null;
let out_ptr: usize = 0;

/// Re-exported by every tool (`export { scratch } from "./lib"`) to satisfy
/// the ABI's scratch() export.
export function scratch(need: u32): u32 {
  if (need > BUF) return 0;
  if (scratch_ptr == 0) {
    scratch_view = new Uint8Array(BUF);
    scratch_ptr = scratch_view!.dataStart;
  }
  return <u32>scratch_ptr;
}

/// Re-exported by every tool to satisfy the ABI's host_arena() export.
export function host_arena(): u32 {
  if (arena_ptr == 0) {
    arena_view = new Uint8Array(BUF);
    arena_ptr = arena_view!.dataStart;
  }
  return <u32>arena_ptr;
}

function ensureOut(): usize {
  if (out_ptr == 0) {
    out_view = new Uint8Array(BUF);
    out_ptr = out_view!.dataStart;
  }
  return out_ptr;
}

export function log(level: u32, msg: string): void {
  const bytes = String.UTF8.encode(msg);
  ck_log(level, changetype<usize>(bytes), bytes.byteLength);
}
export function logInfo(msg: string): void { log(1, msg); }
export function logWarn(msg: string): void { log(2, msg); }
export function logError(msg: string): void { log(3, msg); }

/// Seconds since the Unix epoch. `ck_now` itself is nanoseconds (see
/// src/sandbox/host.zig ckNow and tools/zig/lib.zig nowSeconds, which divides
/// by 1e9 the same way); this is the division so callers never see the raw
/// unit. Do not multiply by 1000 expecting milliseconds of an epoch that was
/// already seconds — that is how id_gen's ULID timestamp overflowed.
export function now(): u64 { return ck_now() / 1000000000; }

/// One host-sourced random u64 per call (not a seeded PRNG stream): fine for
/// building an id, not for anything needing many draws from one seed.
export function randomU64(): u64 { return ck_random(); }

/// Decodes the tool's raw input bytes as UTF-8. `ptr`/`len` are exactly the
/// arguments `run` was called with.
export function readInput(ptr: u32, len: u32): string {
  return String.UTF8.decodeUnsafe(ptr, len);
}

/// Encodes `text`, copies it into the out buffer, and returns the packed
/// (ptr << 32 | len) result every tool's run() must return. Output over BUF
/// is truncated rather than trapped: a tool returning too much is a bug to
/// see and fix, not a crash for the caller.
function packOut(text: string): u64 {
  const bytes = String.UTF8.encode(text);
  const dst = ensureOut();
  const n: i32 = bytes.byteLength > <i32>BUF ? <i32>BUF : bytes.byteLength;
  memory.copy(dst, changetype<usize>(bytes), n);
  return (<u64>dst << 32) | <u64>n;
}

/// Escapes `s` for placement inside a JSON string literal (quote, backslash,
/// control characters). Tools building a bigger JSON document by hand should
/// use json.ts's `stringify` instead — this is only for the flat `text`/
/// `error` fields `okText`/`fail` below produce.
export function jsonEscape(s: string): string {
  let out = "";
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c == 34) out += "\\\"";
    else if (c == 92) out += "\\\\";
    else if (c == 10) out += "\\n";
    else if (c == 13) out += "\\r";
    else if (c == 9) out += "\\t";
    else if (c < 32) out += "\\u" + hex4(c);
    else out += String.fromCharCode(c);
  }
  return out;
}

function hex4(n: i32): string {
  let s = n.toString(16);
  while (s.length < 4) s = "0" + s;
  return s;
}

/// `{"ok":true,"text":"<text>"}` — the shape most tools' successful reply
/// takes (matches lib.zig's okText).
export function okText(text: string): u64 {
  return packOut('{"ok":true,"text":"' + jsonEscape(text) + '"}');
}

/// A JSON document the caller already built (e.g. via json.ts's stringify),
/// returned verbatim rather than wrapped in a "text" string field.
export function okRaw(json: string): u64 {
  return packOut(json);
}

/// `{"ok":false,"error":"<msg>"}`, `msg` escaped (matches lib.zig's fail).
export function fail(msg: string): u64 {
  logError(msg);
  return packOut('{"ok":false,"error":"' + jsonEscape(msg) + '"}');
}
