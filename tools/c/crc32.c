// crc32 — CRC-32 (IEEE 802.3, the zlib/gzip polynomial) checksum of input
// text, returned as 8 lowercase hex digits. Useful for integrity checks and
// cache-busting keys where a full cryptographic hash (ck_hash) is overkill.
// Input:  {"text": "..."} — the bare text may also be passed unwrapped.
// Output: {"ok": true, "text": "<8 hex digits>"}

#include "ck.h"

CK_EXPORT("scratch") u32 scratch(u32 need) { return ck_scratch(need); }
CK_EXPORT("host_arena") u32 host_arena(void) { return ck_host_arena(); }

static u32 crc32_table[256];
static int crc32_table_ready = 0;

static void crc32_init_table(void) {
  for (u32 i = 0; i < 256; i++) {
    u32 c = i;
    for (int k = 0; k < 8; k++) {
      c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
    }
    crc32_table[i] = c;
  }
  crc32_table_ready = 1;
}

static u32 crc32_compute(const u8 *data, u32 len) {
  if (!crc32_table_ready) crc32_init_table();
  u32 crc = 0xFFFFFFFFu;
  for (u32 i = 0; i < len; i++) {
    crc = crc32_table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFFu;
}

static void hex8(u32 v, char *out) {
  static const char *digits = "0123456789abcdef";
  for (int i = 7; i >= 0; i--) {
    out[i] = digits[v & 0xF];
    v >>= 4;
  }
}

/// Extracts the "text" field from a bare `{"text": "..."}` request, without
/// a general JSON parser: a JSON-string value here can only be a flat run
/// of characters (this tool has no reason to accept escapes in it), so a
/// direct scan for the first quoted span after "text" is enough, and it is
/// what every C/C++ tool here does rather than each hand-rolling a parser.
static const char *extract_text_field(const u8 *input, u32 len, u32 *out_len) {
  // Look for "text" (5 bytes incl. quotes) then a colon then a quote.
  for (u32 i = 0; i + 6 < len; i++) {
    if (input[i] == '"' && input[i + 1] == 't' && input[i + 2] == 'e' &&
        input[i + 3] == 'x' && input[i + 4] == 't' && input[i + 5] == '"') {
      u32 j = i + 6;
      while (j < len && input[j] != ':') j++;
      j++;
      while (j < len && (input[j] == ' ' || input[j] == '\t')) j++;
      if (j < len && input[j] == '"') {
        j++;
        u32 start = j;
        while (j < len && input[j] != '"') j++;
        *out_len = j - start;
        return (const char *)(input + start);
      }
    }
  }
  *out_len = 0;
  return 0;
}

CK_EXPORT("run") u64 run(u32 ptr, u32 len) {
  const u8 *input = ck_input(ptr);
  const char *text;
  u32 text_len;
  if (len > 0 && input[0] == '{') {
    text = extract_text_field(input, len, &text_len);
    if (!text) return ck_fail("missing \"text\"");
  } else {
    text = (const char *)input;
    text_len = len;
  }
  u32 crc = crc32_compute((const u8 *)text, text_len);
  char hex[9];
  hex8(crc, hex);
  hex[8] = 0;
  return ck_ok_text(hex);
}
