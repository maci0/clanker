import { count, drift } from "./ratchet.ts";
import { expect, test } from "bun:test";

test("count groups findings by file and rule", () => {
  const counts = count([
    { code: "eslint(curly)", filename: "a.js", labels: [], message: "" },
    { code: "eslint(curly)", filename: "a.js", labels: [], message: "" },
    { code: "parse", filename: "b.js", labels: [], message: "unexpected token" },
  ]);

  expect(counts).toEqual(
    new Map([
      ["a.js", new Map([["eslint(curly)", 2]])],
      ["b.js", new Map([["parse", 1]])],
    ]),
  );
});

test("drift reports a new rule, a rise, and a fall, and nothing for a match", () => {
  const baseline = new Map([
      [
        "a.js",
        new Map([
          ["curly", 2],
          ["no-var", 3],
        ]),
      ],
      ["gone.js", new Map([["curly", 1]])],
    ]),
    now = new Map([
      [
        "a.js",
        new Map([
          ["curly", 2],
          ["eqeqeq", 1],
          ["no-var", 4],
        ]),
      ],
    ]);

  expect(drift(baseline, now)).toEqual({
    fell: [{ baseline: 1, file: "gone.js", now: 0, rule: "curly" }],
    rose: [
      { baseline: 3, file: "a.js", now: 4, rule: "no-var" },
      { baseline: 0, file: "a.js", now: 1, rule: "eqeqeq" },
    ],
  });
  expect(drift(now, now)).toEqual({ fell: [], rose: [] });
});
