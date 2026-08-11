// levenshtein — edit distance between two strings (single-character insert,
// delete, substitute). Useful for fuzzy "did you mean" matching — comparing
// a typo'd tool name, file path, or identifier against known candidates.
// Input:  {"a": "...", "b": "..."}
// Output: {"ok": true, "text": "<distance>"}
//
// No STL: EditDistance owns a fixed-capacity row pair on the stack (both
// inputs are capped well under it) rather than std::vector, matching the
// no-runtime discipline every tool in tools/c and tools/cpp follows.

#include "../c/ck.h"

class EditDistance {
 public:
  static const u32 kMaxLen = 2000;

  /// -1 if either input exceeds kMaxLen (the two-row DP table is O(len),
  /// so the cap is about staying inside the guest's linear memory budget,
  /// not correctness).
  static int Compute(const char *a, u32 a_len, const char *b, u32 b_len) {
    if (a_len > kMaxLen || b_len > kMaxLen) return -1;
    static u32 prev[kMaxLen + 1];
    static u32 cur[kMaxLen + 1];
    for (u32 j = 0; j <= b_len; j++) prev[j] = j;
    for (u32 i = 1; i <= a_len; i++) {
      cur[0] = i;
      for (u32 j = 1; j <= b_len; j++) {
        u32 cost = (a[i - 1] == b[j - 1]) ? 0 : 1;
        u32 del = prev[j] + 1;
        u32 ins = cur[j - 1] + 1;
        u32 sub = prev[j - 1] + cost;
        u32 m = del < ins ? del : ins;
        cur[j] = m < sub ? m : sub;
      }
      for (u32 j = 0; j <= b_len; j++) prev[j] = cur[j];
    }
    return (int)prev[b_len];
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

static void IntToDecimalText(int v, char *out, u32 *out_len) {
  char tmp[12];
  u32 n = 0;
  u32 uv = (u32)v;
  if (uv == 0) tmp[n++] = '0';
  while (uv > 0) {
    tmp[n++] = (char)('0' + (uv % 10));
    uv /= 10;
  }
  u32 pos = 0;
  while (n > 0) out[pos++] = tmp[--n];
  *out_len = pos;
}

extern "C" {

CK_EXPORT("scratch") u32 scratch(u32 need) { return ck_scratch(need); }
CK_EXPORT("host_arena") u32 host_arena() { return ck_host_arena(); }

CK_EXPORT("run") u64 run(u32 ptr, u32 len) {
  const u8 *input = ck_input(ptr);
  u32 a_len, b_len;
  const char *a = ExtractField(input, len, "a", &a_len);
  const char *b = ExtractField(input, len, "b", &b_len);
  if (!a) return ck_fail("missing \"a\" (string)");
  if (!b) return ck_fail("missing \"b\" (string)");

  int d = EditDistance::Compute(a, a_len, b, b_len);
  if (d < 0) return ck_fail("input longer than 2000 characters");

  char out[16];
  u32 out_len;
  IntToDecimalText(d, out, &out_len);
  out[out_len] = 0;
  return ck_ok_text(out);
}

}  // extern "C"
