// roman_numeral — convert between an integer (1-3999) and a Roman numeral.
// Input:  {"value": 1994} to convert int -> numeral, or
//         {"text": "MCMXCIV"} to convert numeral -> int (the bare numeral
//         text may also be passed unwrapped).
// Output: {"ok": true, "text": "<numeral, or the decimal value>"}
//
// No STL, no exceptions, no RTTI (the whole toolchain here is freestanding
// wasm32 with no runtime to support them) — RomanNumeral is a small value
// class over a fixed-size C array, not std::string.

#include "../c/ck.h"

class RomanNumeral {
 public:
  static bool ToText(int value, char *out, u32 *out_len) {
    if (value < 1 || value > 3999) return false;
    static const int values[] = {1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1};
    static const char *symbols[] = {"M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"};
    u32 pos = 0;
    for (int i = 0; i < 13 && value > 0; i++) {
      while (value >= values[i]) {
        const char *s = symbols[i];
        for (u32 k = 0; s[k]; k++) out[pos++] = s[k];
        value -= values[i];
      }
    }
    *out_len = pos;
    return true;
  }

  /// Returns the value, or -1 for a malformed numeral (an unrecognized
  /// letter, or a subtractive pair that classical Roman numerals do not
  /// use — this parses standard form only, not every historical variant).
  static int FromText(const char *text, u32 len) {
    int total = 0;
    u32 i = 0;
    while (i < len) {
      int v = ValueOf(text[i]);
      if (v < 0) return -1;
      if (i + 1 < len) {
        int next = ValueOf(text[i + 1]);
        if (next > v) {
          if (!IsValidSubtractive(v, next)) return -1;
          total += next - v;
          i += 2;
          continue;
        }
      }
      total += v;
      i++;
    }
    if (total < 1 || total > 3999) return -1;
    return total;
  }

 private:
  static int ValueOf(char c) {
    switch (c) {
      case 'I': return 1;
      case 'V': return 5;
      case 'X': return 10;
      case 'L': return 50;
      case 'C': return 100;
      case 'D': return 500;
      case 'M': return 1000;
      default: return -1;
    }
  }

  static bool IsValidSubtractive(int smaller, int larger) {
    if (smaller == 1) return larger == 5 || larger == 10;
    if (smaller == 10) return larger == 50 || larger == 100;
    if (smaller == 100) return larger == 500 || larger == 1000;
    return false;
  }
};

static const char *ExtractTextField(const u8 *input, u32 len, u32 *out_len) {
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

static int ExtractValueField(const u8 *input, u32 len) {
  const char *key = "\"value\"";
  u32 kn = ck_strlen(key);
  for (u32 i = 0; i + kn < len; i++) {
    bool match = true;
    for (u32 k = 0; k < kn; k++) {
      if (input[i + k] != (u8)key[k]) {
        match = false;
        break;
      }
    }
    if (!match) continue;
    u32 j = i + kn;
    while (j < len && input[j] != ':') j++;
    j++;
    while (j < len && (input[j] == ' ' || input[j] == '\t')) j++;
    bool neg = false;
    if (j < len && input[j] == '-') {
      neg = true;
      j++;
    }
    int v = 0;
    bool saw_digit = false;
    while (j < len && input[j] >= '0' && input[j] <= '9') {
      v = v * 10 + (input[j] - '0');
      j++;
      saw_digit = true;
    }
    return saw_digit ? (neg ? -v : v) : -1000000;
  }
  return -1000000;
}

static void IntToDecimalText(int v, char *out, u32 *out_len) {
  char tmp[12];
  u32 n = 0;
  bool neg = v < 0;
  u32 uv = neg ? (u32)(-v) : (u32)v;
  if (uv == 0) tmp[n++] = '0';
  while (uv > 0) {
    tmp[n++] = (char)('0' + (uv % 10));
    uv /= 10;
  }
  u32 pos = 0;
  if (neg) out[pos++] = '-';
  while (n > 0) out[pos++] = tmp[--n];
  *out_len = pos;
}

extern "C" {

u32 scratch(u32 need) { return ck_scratch(need); }
u32 host_arena() { return ck_host_arena(); }

u64 run(u32 ptr, u32 len) {
  const u8 *input = ck_input(ptr);

  if (len > 0 && input[0] == '{') {
    int value = ExtractValueField(input, len);
    if (value != -1000000) {
      char out[16];
      u32 out_len;
      if (!RomanNumeral::ToText(value, out, &out_len)) {
        return ck_fail("value must be between 1 and 3999");
      }
      out[out_len] = 0;
      return ck_ok_text(out);
    }
    u32 text_len;
    const char *text = ExtractTextField(input, len, &text_len);
    if (text) {
      int v = RomanNumeral::FromText(text, text_len);
      if (v < 0) return ck_fail("not a valid Roman numeral");
      char out[16];
      u32 out_len;
      IntToDecimalText(v, out, &out_len);
      out[out_len] = 0;
      return ck_ok_text(out);
    }
    return ck_fail("expected \"value\" (int) or \"text\" (numeral)");
  }

  // Bare input: a numeral text, unwrapped (mirrors calc_ts's bare-input
  // convention).
  int v = RomanNumeral::FromText((const char *)input, len);
  if (v < 0) return ck_fail("not a valid Roman numeral");
  char out[16];
  u32 out_len;
  IntToDecimalText(v, out, &out_len);
  out[out_len] = 0;
  return ck_ok_text(out);
}

}  // extern "C"
