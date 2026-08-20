// id_gen — generate identifiers: UUID v4, ULID, or a short random hex id.
// Input:  {"kind": "uuid4"|"ulid"|"short", "count": 1, "length": 8}
//         kind defaults to "uuid4"; count defaults to 1 (max 100); length
//         (only for "short") defaults to 8 hex chars, max 64.
// Output: {"ok": true, "text": "<id>"} for count 1,
//         {"ok": true, "text": "<id1>\n<id2>\n..."} for count > 1

import { scratch, host_arena, readInput, randomU64, now, okText, fail } from "./lib";
import { parseJSON, JKind } from "./json";

export { scratch, host_arena };

const HEX = "0123456789abcdef";
const CROCKFORD32 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

export function run(ptr: u32, len: u32): u64 {
  const input = readInput(ptr, len);
  let kind = "uuid4";
  let count: i32 = 1;
  let length: i32 = 8;

  if (input.length > 0) {
    const req = parseJSON(input);
    if (req.ok && req.value.kind == JKind.Obj) {
      const k = req.value.get("kind");
      if (k != null && k.kind == JKind.Str) kind = k.s;
      const c = req.value.get("count");
      if (c != null && c.kind == JKind.Num) count = <i32>c.n;
      const l = req.value.get("length");
      if (l != null && l.kind == JKind.Num) length = <i32>l.n;
    }
  }

  if (count < 1) count = 1;
  if (count > 100) return fail("count must be 100 or fewer per call");
  if (length < 1) length = 8;
  if (length > 64) return fail("length must be 64 or fewer");

  let out = "";
  for (let i = 0; i < count; i++) {
    if (i > 0) out += "\n";
    if (kind == "uuid4") out += uuid4();
    else if (kind == "ulid") out += ulid();
    else if (kind == "short") out += shortId(length);
    else return fail('unknown kind "' + kind + '": use uuid4, ulid, or short');
  }
  return okText(out);
}

function randHex(nibbles: i32): string {
  let out = "";
  let bits: u64 = 0;
  let have: i32 = 0;
  for (let i = 0; i < nibbles; i++) {
    if (have == 0) {
      bits = randomU64();
      have = 16; // one u64 covers 16 hex nibbles
    }
    out += HEX.charAt(<i32>(bits & 0xf));
    bits = bits >> 4;
    have--;
  }
  return out;
}

/// RFC 4122 version 4 (random): xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx,
/// version nibble fixed to 4 and the variant nibble fixed to 8-b.
function uuid4(): string {
  const hex = randHex(32);
  let variant = hex.charAt(16);
  const vbits = HEX.indexOf(variant) & 0x3 | 0x8; // 8, 9, a, or b
  variant = HEX.charAt(vbits);
  return (
    hex.substring(0, 8) + "-" +
    hex.substring(8, 12) + "-4" +
    hex.substring(13, 16) + "-" + variant +
    hex.substring(17, 20) + "-" +
    hex.substring(20, 32)
  );
}

/// ULID: 48-bit millisecond timestamp + 80 bits of randomness, both
/// Crockford base32, lexically sortable by creation time. `now()` is
/// seconds (see lib.ts), so it is widened to milliseconds — coarser than a
/// true millisecond clock, but still monotonic-enough ordering within the
/// same tool call for what an id generator needs. (It used to be multiplied
/// from raw nanoseconds, overflowing the 48-bit field and destroying the
/// sort order; the host's ck_now is nanoseconds, `now()` divides.)
function ulid(): string {
  const ms: u64 = now() * 1000;
  let t = "";
  let tv = ms;
  for (let i = 0; i < 10; i++) {
    t = CROCKFORD32.charAt(<i32>(tv & 0x1f)) + t;
    tv = tv >> 5;
  }
  // 80 bits of randomness, 16 Crockford base32 characters. One host draw
  // per character rather than packing bits across draws: this tool is
  // called rarely enough that the extra host calls cost nothing, and
  // packing correctly across 64-bit-word boundaries is exactly the kind of
  // bookkeeping worth trading away for it.
  let r = "";
  for (let i = 0; i < 16; i++) {
    r += CROCKFORD32.charAt(<i32>(randomU64() & 0x1f));
  }
  return t + r;
}

function shortId(length: i32): string {
  return randHex(length);
}
