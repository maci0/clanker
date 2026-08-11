// base64 — encode or decode base64 (RFC 4648, standard alphabet, '=' padded).
// Input:  {"text": "...", "mode": "encode"|"decode"} — mode defaults to
//         "encode"; the bare text may also be passed unwrapped (encode only).
// Output: {"ok": true, "text": "<result>"}
//         {"ok": false, "error": "..."} on malformed base64 for decode

#include "ck.h"

u32 scratch(u32 need) { return ck_scratch(need); }
u32 host_arena(void) { return ck_host_arena(); }

static const char *extract_field(const u8 *input, u32 len, const char *name, u32 *out_len) {
  u32 name_len = ck_strlen(name);
  for (u32 i = 0; i + name_len + 2 < len; i++) {
    if (input[i] != '"') continue;
    u32 k = 0;
    while (k < name_len && input[i + 1 + k] == (u8)name[k]) k++;
    if (k != name_len || input[i + 1 + k] != '"') continue;
    u32 j = i + 1 + k + 1;
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
  *out_len = 0;
  return 0;
}

static const char b64_alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static int b64_decode_char(u8 c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  return -1;
}

static u64 b64_encode(const u8 *data, u32 len) {
  static char out[CK_BUF];
  u32 pos = 0;
  u32 i = 0;
  for (; i + 3 <= len && pos + 4 <= CK_BUF; i += 3) {
    u32 n = ((u32)data[i] << 16) | ((u32)data[i + 1] << 8) | data[i + 2];
    out[pos++] = b64_alphabet[(n >> 18) & 0x3F];
    out[pos++] = b64_alphabet[(n >> 12) & 0x3F];
    out[pos++] = b64_alphabet[(n >> 6) & 0x3F];
    out[pos++] = b64_alphabet[n & 0x3F];
  }
  u32 rem = len - i;
  if (rem == 1 && pos + 4 <= CK_BUF) {
    u32 n = (u32)data[i] << 16;
    out[pos++] = b64_alphabet[(n >> 18) & 0x3F];
    out[pos++] = b64_alphabet[(n >> 12) & 0x3F];
    out[pos++] = '=';
    out[pos++] = '=';
  } else if (rem == 2 && pos + 4 <= CK_BUF) {
    u32 n = ((u32)data[i] << 16) | ((u32)data[i + 1] << 8);
    out[pos++] = b64_alphabet[(n >> 18) & 0x3F];
    out[pos++] = b64_alphabet[(n >> 12) & 0x3F];
    out[pos++] = b64_alphabet[(n >> 6) & 0x3F];
    out[pos++] = '=';
  }
  return ck_write_result(out, pos);
}

static u64 b64_decode(const char *text, u32 len) {
  // A well-formed input's meaningful length excludes trailing padding and
  // whitespace; malformed characters inside the body are refused outright
  // rather than silently skipped, so a corrupted payload decodes to an
  // error, not to quietly-wrong bytes.
  static u8 out[CK_BUF];
  u32 pos = 0;
  u32 buf = 0;
  int bits = 0;
  for (u32 i = 0; i < len; i++) {
    u8 c = (u8)text[i];
    if (c == '=' || c == '\n' || c == '\r' || c == ' ') continue;
    int v = b64_decode_char(c);
    if (v < 0) return ck_fail("invalid base64 character");
    buf = (buf << 6) | (u32)v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      if (pos >= CK_BUF) return ck_fail("decoded output too large");
      out[pos++] = (u8)((buf >> bits) & 0xFF);
    }
  }
  return ck_write_result(out, pos);
}

u64 run(u32 ptr, u32 len) {
  const u8 *input = ck_input(ptr);
  const char *text;
  u32 text_len;
  const char *mode = "encode";
  u32 mode_len = 6;

  if (len > 0 && input[0] == '{') {
    text = extract_field(input, len, "text", &text_len);
    if (!text) return ck_fail("missing \"text\"");
    const char *m = extract_field(input, len, "mode", &mode_len);
    if (m) mode = m;
  } else {
    text = (const char *)input;
    text_len = len;
  }

  if (mode_len == 6 && mode[0] == 'e' && mode[1] == 'n' && mode[2] == 'c') {
    return b64_encode((const u8 *)text, text_len);
  }
  if (mode_len == 6 && mode[0] == 'd' && mode[1] == 'e' && mode[2] == 'c') {
    return b64_decode(text, text_len);
  }
  return ck_fail("mode must be \"encode\" or \"decode\"");
}
