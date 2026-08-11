// json.ts — a minimal JSON value type, parser, and serializer for
// AssemblyScript tools.
//
// AssemblyScript is not Node: the npm JSON ecosystem does not compile to
// this target, and there is no built-in JSON global the way there is in a
// browser or Node. Any tool that needs to read or write arbitrary JSON
// (not just a fixed input shape) shares this instead of each hand-rolling
// its own parser — json_tool.ts and csv_json.ts both do.
//
// Not a tool itself — excluded from build:all/verify.sh like lib.ts.

export enum JKind {
  Null,
  Bool,
  Num,
  Str,
  Arr,
  Obj,
}

/// A JSON value. One class covers every kind rather than a tagged union of
/// classes so arrays/objects of mixed value kinds (which JSON allows) need
/// no downcasting — `kind` says which fields are meaningful.
export class JValue {
  kind: JKind = JKind.Null;
  b: bool = false;
  n: f64 = 0;
  s: string = "";
  arr: JValue[] = [];
  // Objects keep insertion order in parallel arrays rather than a Map, so a
  // parse-then-serialize round trip reproduces the source's key order —
  // the same reason lib.zig's registry keeps tools in an ordered map.
  keys: string[] = [];
  vals: JValue[] = [];

  static Null(): JValue {
    return new JValue();
  }
  static Bool(v: bool): JValue {
    const j = new JValue();
    j.kind = JKind.Bool;
    j.b = v;
    return j;
  }
  static Num(v: f64): JValue {
    const j = new JValue();
    j.kind = JKind.Num;
    j.n = v;
    return j;
  }
  static Str(v: string): JValue {
    const j = new JValue();
    j.kind = JKind.Str;
    j.s = v;
    return j;
  }
  static Arr(v: JValue[] = []): JValue {
    const j = new JValue();
    j.kind = JKind.Arr;
    j.arr = v;
    return j;
  }
  static Obj(): JValue {
    const j = new JValue();
    j.kind = JKind.Obj;
    return j;
  }

  /// Sets `key`, overwriting an existing one in place (its original
  /// position is kept) rather than appending a duplicate — matches how
  /// JSON.parse resolves a repeated key in the source text.
  set(key: string, val: JValue): void {
    for (let i = 0; i < this.keys.length; i++) {
      if (this.keys[i] == key) {
        this.vals[i] = val;
        return;
      }
    }
    this.keys.push(key);
    this.vals.push(val);
  }

  get(key: string): JValue | null {
    for (let i = 0; i < this.keys.length; i++) {
      if (this.keys[i] == key) return this.vals[i];
    }
    return null;
  }

  push(val: JValue): void {
    this.arr.push(val);
  }
}

export class ParseResult {
  ok: bool = false;
  value: JValue = new JValue();
  errorMsg: string = "";
  /// 1-based line/column of the failure, for a message a human can act on
  /// without counting characters by hand.
  line: i32 = 0;
  col: i32 = 0;
}

class Parser {
  s: string;
  i: i32 = 0;

  constructor(s: string) {
    this.s = s;
  }

  eof(): bool {
    return this.i >= this.s.length;
  }
  peek(): i32 {
    return this.eof() ? -1 : this.s.charCodeAt(this.i);
  }

  skipWs(): void {
    while (!this.eof()) {
      const c = this.peek();
      if (c == 32 || c == 9 || c == 10 || c == 13) this.i++;
      else break;
    }
  }

  parseValue(): JValue | null {
    this.skipWs();
    const c = this.peek();
    if (c == 34) return this.parseString();
    if (c == 123) return this.parseObject();
    if (c == 91) return this.parseArray();
    if (c == 116) return this.parseLiteral("true", JValue.Bool(true));
    if (c == 102) return this.parseLiteral("false", JValue.Bool(false));
    if (c == 110) return this.parseLiteral("null", JValue.Null());
    if (c == 45 || (c >= 48 && c <= 57)) return this.parseNumber();
    return null;
  }

  parseLiteral(word: string, val: JValue): JValue | null {
    if (this.s.length - this.i < word.length) return null;
    for (let k = 0; k < word.length; k++) {
      if (this.s.charCodeAt(this.i + k) != word.charCodeAt(k)) return null;
    }
    this.i += word.length;
    return val;
  }

  parseNumber(): JValue | null {
    const start = this.i;
    if (this.peek() == 45) this.i++; // -
    if (this.eof() || !isDigit(this.peek())) return null;
    if (this.peek() == 48) {
      this.i++; // a lone leading zero
    } else {
      while (!this.eof() && isDigit(this.peek())) this.i++;
    }
    if (!this.eof() && this.peek() == 46) {
      this.i++;
      if (this.eof() || !isDigit(this.peek())) return null;
      while (!this.eof() && isDigit(this.peek())) this.i++;
    }
    if (!this.eof() && (this.peek() == 101 || this.peek() == 69)) {
      this.i++;
      if (!this.eof() && (this.peek() == 43 || this.peek() == 45)) this.i++;
      if (this.eof() || !isDigit(this.peek())) return null;
      while (!this.eof() && isDigit(this.peek())) this.i++;
    }
    const text = this.s.substring(start, this.i);
    return JValue.Num(parseFloat(text));
  }

  parseString(): JValue | null {
    const s = this.parseRawString();
    return s == null ? null : JValue.Str(s);
  }

  /// Consumes a JSON string literal (the caller already knows `"` is next)
  /// and returns its decoded content, or null on a malformed escape or an
  /// unterminated literal.
  parseRawString(): string | null {
    if (this.peek() != 34) return null;
    this.i++;
    let out = "";
    while (true) {
      if (this.eof()) return null;
      const c = this.s.charCodeAt(this.i);
      if (c == 34) {
        this.i++;
        return out;
      }
      if (c == 92) {
        this.i++;
        if (this.eof()) return null;
        const e = this.s.charCodeAt(this.i);
        if (e == 34) out += '"';
        else if (e == 92) out += "\\";
        else if (e == 47) out += "/";
        else if (e == 98) out += "\b";
        else if (e == 102) out += "\f";
        else if (e == 110) out += "\n";
        else if (e == 114) out += "\r";
        else if (e == 116) out += "\t";
        else if (e == 117) {
          if (this.s.length - this.i < 5) return null;
          const hex = this.s.substring(this.i + 1, this.i + 5);
          const code = parseHex4(hex);
          if (code < 0) return null;
          out += String.fromCharCode(code);
          this.i += 4;
        } else return null;
        this.i++;
      } else if (c < 32) {
        return null; // a raw control character is not valid inside a string
      } else {
        out += String.fromCharCode(c);
        this.i++;
      }
    }
  }

  parseArray(): JValue | null {
    this.i++; // [
    const result = JValue.Arr();
    this.skipWs();
    if (!this.eof() && this.peek() == 93) {
      this.i++;
      return result;
    }
    while (true) {
      const v = this.parseValue();
      if (v == null) return null;
      result.push(v);
      this.skipWs();
      if (this.eof()) return null;
      const c = this.peek();
      if (c == 44) {
        this.i++;
        this.skipWs();
        continue;
      }
      if (c == 93) {
        this.i++;
        return result;
      }
      return null;
    }
  }

  parseObject(): JValue | null {
    this.i++; // {
    const result = JValue.Obj();
    this.skipWs();
    if (!this.eof() && this.peek() == 125) {
      this.i++;
      return result;
    }
    while (true) {
      this.skipWs();
      const key = this.parseRawString();
      if (key == null) return null;
      this.skipWs();
      if (this.eof() || this.peek() != 58) return null; // :
      this.i++;
      const v = this.parseValue();
      if (v == null) return null;
      result.set(key, v);
      this.skipWs();
      if (this.eof()) return null;
      const c = this.peek();
      if (c == 44) {
        this.i++;
        continue;
      }
      if (c == 125) {
        this.i++;
        return result;
      }
      return null;
    }
  }
}

function isDigit(c: i32): bool {
  return c >= 48 && c <= 57;
}

function parseHex4(hex: string): i32 {
  let v: i32 = 0;
  for (let i = 0; i < 4; i++) {
    const c = hex.charCodeAt(i);
    let d: i32;
    if (c >= 48 && c <= 57) d = c - 48;
    else if (c >= 97 && c <= 102) d = c - 97 + 10;
    else if (c >= 65 && c <= 70) d = c - 65 + 10;
    else return -1;
    v = v * 16 + d;
  }
  return v;
}

/// Parses `input` as a single JSON value with no trailing content. On
/// failure, `errorMsg` names what was expected and `line`/`col` locate it.
export function parseJSON(input: string): ParseResult {
  const p = new Parser(input);
  const v = p.parseValue();
  const r = new ParseResult();
  if (v == null) {
    r.ok = false;
    r.errorMsg = "invalid JSON value";
    positionOf(input, p.i, r);
    return r;
  }
  p.skipWs();
  if (!p.eof()) {
    r.ok = false;
    r.errorMsg = "trailing content after the JSON value";
    positionOf(input, p.i, r);
    return r;
  }
  r.ok = true;
  r.value = v;
  return r;
}

function positionOf(input: string, pos: i32, r: ParseResult): void {
  let line: i32 = 1;
  let col: i32 = 1;
  const stop = pos < input.length ? pos : input.length;
  for (let i = 0; i < stop; i++) {
    if (input.charCodeAt(i) == 10) {
      line++;
      col = 1;
    } else {
      col++;
    }
  }
  r.line = line;
  r.col = col;
}

function escapeString(s: string): string {
  let out = '"';
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c == 34) out += '\\"';
    else if (c == 92) out += "\\\\";
    else if (c == 10) out += "\\n";
    else if (c == 13) out += "\\r";
    else if (c == 9) out += "\\t";
    else if (c < 32) {
      let h = c.toString(16);
      while (h.length < 4) h = "0" + h;
      out += "\\u" + h;
    } else out += String.fromCharCode(c);
  }
  return out + '"';
}

/// Renders `n` the way JSON expects: no exponent for ordinary magnitudes,
/// and integral values print without a trailing ".0" so round-tripping an
/// integer through parse/stringify does not change its printed form.
function numberToJson(n: f64): string {
  if (isNaN(n) || isFinite(n) == false) return "0";
  if (n == Math.floor(n) && Math.abs(n) < 1e15) {
    return (<i64>n).toString();
  }
  return n.toString();
}

/// Serializes `v`. `indent < 0` minifies (no whitespace at all); `indent
/// >= 0` pretty-prints with that many spaces per nesting level.
export function stringify(v: JValue, indent: i32 = -1): string {
  return stringifyAt(v, indent, 0);
}

function stringifyAt(v: JValue, indent: i32, depth: i32): string {
  const pretty = indent >= 0;
  switch (v.kind) {
    case JKind.Null:
      return "null";
    case JKind.Bool:
      return v.b ? "true" : "false";
    case JKind.Num:
      return numberToJson(v.n);
    case JKind.Str:
      return escapeString(v.s);
    case JKind.Arr: {
      if (v.arr.length == 0) return "[]";
      const pad = pretty ? repeat(" ", indent * (depth + 1)) : "";
      const closePad = pretty ? repeat(" ", indent * depth) : "";
      const sep = pretty ? ",\n" : ",";
      let out = pretty ? "[\n" : "[";
      for (let i = 0; i < v.arr.length; i++) {
        if (i > 0) out += sep;
        out += pad + stringifyAt(v.arr[i], indent, depth + 1);
      }
      out += pretty ? "\n" + closePad + "]" : "]";
      return out;
    }
    case JKind.Obj: {
      if (v.keys.length == 0) return "{}";
      const pad = pretty ? repeat(" ", indent * (depth + 1)) : "";
      const closePad = pretty ? repeat(" ", indent * depth) : "";
      const sep = pretty ? ",\n" : ",";
      const colon = pretty ? ": " : ":";
      let out = pretty ? "{\n" : "{";
      for (let i = 0; i < v.keys.length; i++) {
        if (i > 0) out += sep;
        out += pad + escapeString(v.keys[i]) + colon + stringifyAt(v.vals[i], indent, depth + 1);
      }
      out += pretty ? "\n" + closePad + "}" : "}";
      return out;
    }
    default:
      return "null";
  }
}

function repeat(s: string, n: i32): string {
  let out = "";
  for (let i = 0; i < n; i++) out += s;
  return out;
}
