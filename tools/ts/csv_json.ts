// csv_json — convert between CSV and a JSON array.
// Input:  {"csv": "...", "mode": "to_json"} — first row is the header;
//         each following row becomes a {header: value} object.
//         {"json": "...", "mode": "to_csv"} — an array of objects (union of
//         keys becomes the header row, in first-seen order) or an array of
//         arrays (rows written as-is, no header).
//         mode is inferred from which of "csv"/"json" is present if omitted.
// Output: {"ok": true, "text": "<JSON array, or CSV text>"}
//
// RFC 4180-ish: quoted fields may contain commas, quotes ("" escapes one),
// and newlines; both CRLF and bare LF row endings are accepted on the way
// in, and LF is always written on the way out.

import { scratch, host_arena, readInput, okText, fail } from "./lib";
import { parseJSON, stringify, JValue, JKind } from "./json";

export { scratch, host_arena };

export function run(ptr: u32, len: u32): u64 {
  const input = readInput(ptr, len);
  const req = parseJSON(input);
  if (!req.ok || req.value.kind != JKind.Obj) return fail("expected a JSON object with \"csv\" or \"json\"");

  const csvField = req.value.get("csv");
  const jsonField = req.value.get("json");
  let mode = "";
  const modeField = req.value.get("mode");
  if (modeField != null && modeField.kind == JKind.Str) mode = modeField.s;

  if (mode == "to_json" || (mode == "" && csvField != null)) {
    if (csvField == null || csvField.kind != JKind.Str) return fail('missing "csv" (string)');
    return okText(stringify(csvToJson(csvField.s), 2));
  }
  if (mode == "to_csv" || (mode == "" && jsonField != null)) {
    if (jsonField == null || jsonField.kind != JKind.Str) return fail('missing "json" (string)');
    const parsed = parseJSON(jsonField.s);
    if (!parsed.ok) return fail("invalid \"json\": " + parsed.errorMsg + " at line " + parsed.line.toString() + ", column " + parsed.col.toString());
    if (parsed.value.kind != JKind.Arr) return fail('"json" must be an array of objects or an array of arrays');
    return okText(jsonToCsv(parsed.value));
  }
  return fail('specify "csv" (to convert to JSON) or "json" (to convert to CSV)');
}

// ---- CSV parsing -----------------------------------------------------------

function parseCsvRows(s: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let inQuotes = false;
  let i: i32 = 0;
  let sawAnyField = false;

  while (i < s.length) {
    const c = s.charCodeAt(i);
    if (inQuotes) {
      if (c == 34 /* " */) {
        if (i + 1 < s.length && s.charCodeAt(i + 1) == 34) {
          field += '"';
          i += 2;
        } else {
          inQuotes = false;
          i++;
        }
      } else {
        field += String.fromCharCode(c);
        i++;
      }
      continue;
    }
    if (c == 34) {
      inQuotes = true;
      sawAnyField = true;
      i++;
    } else if (c == 44 /* , */) {
      row.push(field);
      field = "";
      sawAnyField = true;
      i++;
    } else if (c == 13 /* \r */) {
      i++; // paired \n (if any) ends the row on the next iteration
    } else if (c == 10 /* \n */) {
      row.push(field);
      rows.push(row);
      row = [];
      field = "";
      sawAnyField = false;
      i++;
    } else {
      field += String.fromCharCode(c);
      sawAnyField = true;
      i++;
    }
  }
  if (sawAnyField || field.length > 0 || row.length > 0) {
    row.push(field);
    rows.push(row);
  }
  return rows;
}

function csvToJson(csv: string): JValue {
  const rows = parseCsvRows(csv);
  const out = JValue.Arr();
  if (rows.length == 0) return out;
  const header = rows[0];
  for (let r = 1; r < rows.length; r++) {
    const row = rows[r];
    const obj = JValue.Obj();
    for (let c = 0; c < header.length; c++) {
      obj.set(header[c], JValue.Str(c < row.length ? row[c] : ""));
    }
    out.push(obj);
  }
  return out;
}

// ---- CSV writing ------------------------------------------------------------

function csvField(s: string): string {
  let needsQuote = false;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c == 44 || c == 34 || c == 10 || c == 13) {
      needsQuote = true;
      break;
    }
  }
  if (!needsQuote) return s;
  let out = "";
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c == 34) out += '""';
    else out += String.fromCharCode(c);
  }
  return '"' + out + '"';
}

/// A JSON value flattened to the plain text a CSV cell holds: strings pass
/// through, everything else is its JSON form (an object/array cell is rare
/// but should not silently become "[object Object]").
function cellText(v: JValue): string {
  if (v.kind == JKind.Str) return v.s;
  if (v.kind == JKind.Null) return "";
  return stringify(v, -1);
}

function jsonToCsv(arr: JValue): string {
  if (arr.arr.length == 0) return "";
  const first = arr.arr[0];
  let out = "";
  if (first.kind == JKind.Obj) {
    // Union of keys across every row, in first-seen order, so a row
    // missing a key some other row has still gets a column (empty cell)
    // instead of silently shifting every column after it.
    const keys: string[] = [];
    for (let i = 0; i < arr.arr.length; i++) {
      const row = arr.arr[i];
      if (row.kind != JKind.Obj) continue;
      for (let k = 0; k < row.keys.length; k++) {
        let found = false;
        for (let e = 0; e < keys.length; e++) if (keys[e] == row.keys[k]) found = true;
        if (!found) keys.push(row.keys[k]);
      }
    }
    for (let k = 0; k < keys.length; k++) {
      out += (k > 0 ? "," : "") + csvField(keys[k]);
    }
    out += "\n";
    for (let i = 0; i < arr.arr.length; i++) {
      const row = arr.arr[i];
      for (let k = 0; k < keys.length; k++) {
        const cell = row.kind == JKind.Obj ? row.get(keys[k]) : null;
        out += (k > 0 ? "," : "") + csvField(cell == null ? "" : cellText(cell));
      }
      out += "\n";
    }
    return out;
  }
  // An array of arrays: rows written as-is, no header.
  for (let i = 0; i < arr.arr.length; i++) {
    const row = arr.arr[i];
    if (row.kind != JKind.Arr) {
      out += csvField(cellText(row)) + "\n";
      continue;
    }
    for (let c = 0; c < row.arr.length; c++) {
      out += (c > 0 ? "," : "") + csvField(cellText(row.arr[c]));
    }
    out += "\n";
  }
  return out;
}
