// hexdump — a hex + ASCII dump of input bytes, 16 bytes per row, the way
// `xxd`/`hexdump -C` render one. Useful for inspecting opaque or partly
// binary tool output (a hash, a compressed blob, a file with an unclear
// encoding) that would otherwise print as unreadable or invisible bytes.
// Input:  {"text": "...", "max_bytes": 4096} — the bare text may also be
//         passed unwrapped; max_bytes caps how much is dumped (default and
//         ceiling 4096, keeping the rendered output bounded: each byte
//         costs roughly 4 rendered characters).
// Output: {"ok": true, "text": "<hex dump>"}

#include "ck.h"

CK_EXPORT("scratch") u32 scratch(u32 need) { return ck_scratch(need); }
CK_EXPORT("host_arena") u32 host_arena(void) { return ck_host_arena(); }

static const char *extract_text_field(const u8 *input, u32 len, u32 *out_len) {
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

static int extract_max_bytes(const u8 *input, u32 len) {
  const char *key = "\"max_bytes\"";
  u32 kn = ck_strlen(key);
  for (u32 i = 0; i + kn < len; i++) {
    int match = 1;
    for (u32 k = 0; k < kn; k++) {
      if (input[i + k] != (u8)key[k]) {
        match = 0;
        break;
      }
    }
    if (!match) continue;
    u32 j = i + kn;
    while (j < len && input[j] != ':') j++;
    j++;
    while (j < len && (input[j] == ' ' || input[j] == '\t')) j++;
    int v = 0;
    int saw_digit = 0;
    while (j < len && input[j] >= '0' && input[j] <= '9') {
      v = v * 10 + (input[j] - '0');
      j++;
      saw_digit = 1;
    }
    return saw_digit ? v : -1;
  }
  return -1;
}

static char hex_nibble(u8 v) {
  return v < 10 ? (char)('0' + v) : (char)('a' + (v - 10));
}

CK_EXPORT("run") u64 run(u32 ptr, u32 len) {
  const u8 *input = ck_input(ptr);
  const u8 *data;
  u32 data_len;
  u32 max_bytes = 4096;

  if (len > 0 && input[0] == '{') {
    u32 text_len;
    const char *text = extract_text_field(input, len, &text_len);
    if (!text) return ck_fail("missing \"text\"");
    data = (const u8 *)text;
    data_len = text_len;
    int mb = extract_max_bytes(input, len);
    if (mb > 0 && (u32)mb < max_bytes) max_bytes = (u32)mb;
  } else {
    data = input;
    data_len = len;
  }
  if (data_len > max_bytes) data_len = max_bytes;

  // Each row: 8-digit offset + ": " + 16*"XX " + " " + 16 ASCII chars +
  // "\n" — comfortably under CK_BUF for max_bytes's own ceiling (4096
  // bytes -> 256 rows -> well under 64 KiB).
  static char out[CK_BUF];
  u32 pos = 0;
  for (u32 row = 0; row < data_len; row += 16) {
    if (pos + 80 > CK_BUF) break; // one row's worth of headroom
    u32 off = row;
    for (int shift = 28; shift >= 0; shift -= 4) out[pos++] = hex_nibble((u8)((off >> shift) & 0xF));
    out[pos++] = ':';
    out[pos++] = ' ';
    u32 row_end = row + 16 < data_len ? row + 16 : data_len;
    for (u32 i = row; i < row + 16; i++) {
      if (i < row_end) {
        out[pos++] = hex_nibble(data[i] >> 4);
        out[pos++] = hex_nibble(data[i] & 0xF);
      } else {
        out[pos++] = ' ';
        out[pos++] = ' ';
      }
      out[pos++] = ' ';
    }
    out[pos++] = ' ';
    for (u32 i = row; i < row_end; i++) {
      u8 c = data[i];
      out[pos++] = (c >= 0x20 && c < 0x7F) ? (char)c : '.';
    }
    out[pos++] = '\n';
  }
  return ck_write_result(out, pos);
}
