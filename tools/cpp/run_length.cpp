// run_length — run-length encode or decode text. Encoding always emits a
// count before each character (e.g. "aaabbbbc" -> "3a4b1c"), which keeps
// decoding unambiguous without a separate escape for literal digits in the
// input, at the cost of the encoding sometimes being longer than its input
// (a good tradeoff for typically-repetitive input like sparse data dumps or
// simple bitmaps, and simplicity beats a smarter but fiddlier variable-width
// scheme for an example tool).
// Input:  {"text": "...", "mode": "encode"|"decode"} — mode defaults to
//         "encode"; the bare text may also be passed unwrapped (encode
//         only).
// Output: {"ok": true, "text": "<result>"}
//         {"ok": false, "error": "..."} on malformed input for decode

#include "../c/ck.h"

class RunLength {
 public:
  static u64 Encode(const char *text, u32 len) {
    static char out[CK_BUF];
    u32 pos = 0;
    u32 i = 0;
    while (i < len && pos < CK_BUF) {
      char c = text[i];
      u32 run = 1;
      while (i + run < len && text[i + run] == c) run++;
      pos = AppendCount(out, pos, run);
      if (pos < CK_BUF) out[pos++] = c;
      i += run;
    }
    return ck_write_result(out, pos);
  }

  /// Returns a negative sentinel via *ok=false rather than throwing: this
  /// build has no exception support (freestanding wasm32, no runtime).
  static u64 Decode(const char *text, u32 len, bool *ok) {
    static char out[CK_BUF];
    u32 pos = 0;
    u32 i = 0;
    *ok = true;
    while (i < len) {
      if (text[i] < '0' || text[i] > '9') {
        *ok = false;
        return 0;
      }
      u32 count = 0;
      while (i < len && text[i] >= '0' && text[i] <= '9') {
        count = count * 10 + (u32)(text[i] - '0');
        i++;
      }
      if (i >= len) {
        *ok = false; // a count with no character after it
        return 0;
      }
      char c = text[i++];
      for (u32 k = 0; k < count && pos < CK_BUF; k++) out[pos++] = c;
    }
    return ck_write_result(out, pos);
  }

 private:
  static u32 AppendCount(char *out, u32 pos, u32 v) {
    char tmp[12];
    u32 n = 0;
    if (v == 0) tmp[n++] = '0';
    while (v > 0) {
      tmp[n++] = (char)('0' + (v % 10));
      v /= 10;
    }
    while (n > 0 && pos < CK_BUF) out[pos++] = tmp[--n];
    return pos;
  }
};

static const char *ExtractField(const u8 *input, u32 len, const char *name, u32 *out_len) {
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

extern "C" {

CK_EXPORT("scratch") u32 scratch(u32 need) { return ck_scratch(need); }
CK_EXPORT("host_arena") u32 host_arena() { return ck_host_arena(); }

CK_EXPORT("run") u64 run(u32 ptr, u32 len) {
  const u8 *input = ck_input(ptr);
  const char *text;
  u32 text_len;
  const char *mode = "encode";
  u32 mode_len = 6;

  if (len > 0 && input[0] == '{') {
    text = ExtractField(input, len, "text", &text_len);
    if (!text) return ck_fail("missing \"text\"");
    const char *m = ExtractField(input, len, "mode", &mode_len);
    if (m) mode = m;
  } else {
    text = (const char *)input;
    text_len = len;
  }

  if (mode_len == 6 && mode[0] == 'e' && mode[1] == 'n' && mode[2] == 'c') {
    return RunLength::Encode(text, text_len);
  }
  if (mode_len == 6 && mode[0] == 'd' && mode[1] == 'e' && mode[2] == 'c') {
    bool ok;
    u64 result = RunLength::Decode(text, text_len, &ok);
    if (!ok) return ck_fail("malformed run-length data: expected <digits><char> pairs");
    return result;
  }
  return ck_fail("mode must be \"encode\" or \"decode\"");
}

}  // extern "C"
