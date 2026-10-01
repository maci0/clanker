/*
 * Lint ratchet. Every rule in .oxlintrc.json runs at error, and the debt that
 * predates a rule is recorded per file and rule in baseline.json. A run fails
 * when any (file, rule) count rises above its baseline, and when one falls
 * without the baseline following, so paid-down debt cannot quietly return.
 *
 *   bun run lint            check against the baseline
 *   bun run lint:baseline   rewrite the baseline to the current counts
 */

import { z } from "zod";

type Counts = Map<string, Map<string, number>>;

type Drift = { baseline: number; file: string; now: number; rule: string };

type DriftReport = { fell: Array<Drift>; rose: Array<Drift> };

const At = z.object({ span: z.object({ line: z.number() }) }),
  BASELINE = new URL("baseline.json", import.meta.url),
  Counted = z.record(z.string(), z.number().int().nonnegative()),
  Finding = z.object({
    code: z.string().default("parse"),
    filename: z.string(),
    labels: z.array(At).default([]),
    message: z.string(),
  }),
  Report = z.object({ diagnostics: z.array(Finding) }),
  Stored = z.record(z.string(), Counted),
  byKey = ([a]: [string, number], [b]: [string, number]): number => a.localeCompare(b),
  count = (diagnostics: Array<z.infer<typeof Finding>>): Counts => {
    const counts: Counts = new Map();

    for (const d of diagnostics) {
      const rules = counts.get(d.filename) ?? new Map<string, number>();

      rules.set(d.code, (rules.get(d.code) ?? 0) + 1);
      counts.set(d.filename, rules);
    }

    return counts;
  },
  drift = (baseline: Counts, now: Counts): DriftReport => {
    const fell: Array<Drift> = [],
      files = new Set([...baseline.keys(), ...now.keys()]),
      rose: Array<Drift> = [];

    for (const file of files) {
      const rules = new Set([...(baseline.get(file)?.keys() ?? []), ...(now.get(file)?.keys() ?? [])]);

      for (const rule of rules) {
        const is = now.get(file)?.get(rule) ?? 0,
          was = baseline.get(file)?.get(rule) ?? 0;

        if (is > was) {
          rose.push({ baseline: was, file, now: is, rule });
        } else if (is < was) {
          fell.push({ baseline: was, file, now: is, rule });
        }
      }
    }

    return { fell, rose };
  },
  lint = async (): Promise<Array<z.infer<typeof Finding>>> => {
    /*
     * Oxlint has no in-process API, so it runs as a child. The binary is the
     * one package.json pins, resolved out of node_modules rather than through
     * `bunx`: on a checkout with no node_modules `bunx` silently fetches
     * whatever oxlint the registry serves that day, and the ratchet would
     * then compare this tree's findings against tools/oxlint/baseline.json
     * using a linter this project never chose. The pre-commit hook already
     * gates on the same path existing.
     */
    const bin = new URL("../../node_modules/.bin/oxlint", import.meta.url).pathname;

    if (!(await Bun.file(bin).exists())) {
      throw new Error("lint: node_modules/.bin/oxlint is missing; run `bun install --frozen-lockfile`");
    }

    const child = Bun.spawn([bin, "--report-unused-disable-directives-severity=error", "-f", "json"], {
        stderr: "inherit",
        stdout: "pipe",
      }),
      text = await new Response(child.stdout).text(),
      code = await child.exited;

    // A non-zero oxlint can still have written its report — findings are how
    // the ratchet learns about drift — so exit status alone is not a reason to
    // discard `text`. What must never happen is parsing it: oxlint's own
    // plain-text failure ("Failed to parse oxlint configuration file", a
    // panic) is not JSON, and JSON.parse turned that into
    // `SyntaxError: JSON Parse error: Unexpected identifier "Failed"` on top
    // of a stack frame, which named neither the cause nor the remedy while
    // burying the message oxlint had already written to stderr. The status
    // plus the first line of the body is the diagnosis; the usual cause is
    // the preset dependency (@rikalabs/oxlint-standards arrives through a
    // patchedDependencies entry that fails the install outright when it
    // stops applying), which the message above already covers.
    try {
      return Report.parse(JSON.parse(text)).diagnostics;
    } catch {
      console.error(`lint: oxlint exited ${code} without a JSON report; its message was:`);
      console.error(text.split("\n").find((l) => l.trim().length > 0) ?? "(no output)");

      throw new Error("lint: oxlint produced no JSON report (see above; run `bun install --frozen-lockfile`)");
    }
  },
  load = async (): Promise<Counts> => {
    const counts: Counts = new Map(),
      json: unknown = await Bun.file(BASELINE).json();

    for (const [file, rules] of Object.entries(Stored.parse(json))) {
      counts.set(file, new Map(Object.entries(rules)));
    }

    return counts;
  },
  report = (diagnostics: Array<z.infer<typeof Finding>>, { fell, rose }: DriftReport): number => {
    for (const r of rose) {
      console.error(`${r.file}: ${r.rule} rose ${r.baseline} -> ${r.now}`);

      for (const d of diagnostics) {
        if (d.filename === r.file && d.code === r.rule) {
          console.error(`  ${d.filename}:${d.labels.at(0)?.span.line ?? "?"} ${d.message}`);
        }
      }
    }

    for (const f of fell) {
      console.error(`${f.file}: ${f.rule} fell ${f.baseline} -> ${f.now}`);
    }

    if (fell.length > 0) {
      console.error("debt was paid down: run `bun run lint:baseline` and commit tools/oxlint/baseline.json");
    }

    if (rose.length > 0 || fell.length > 0) {
      return 1;
    }

    console.log(`lint: ${diagnostics.length} findings, all recorded in the baseline`);

    return 0;
  },
  toJson = (counts: Counts): string => {
    const json: z.infer<typeof Stored> = {};

    for (const file of [...counts.keys()].toSorted()) {
      json[file] = Object.fromEntries([...(counts.get(file) ?? [])].toSorted(byKey));
    }

    return `${JSON.stringify(json, null, 1)}\n`;
  },
  verify = async (): Promise<number> => {
    const diagnostics = await lint(),
      now = count(diagnostics);

    if (Bun.argv.includes("--update")) {
      await Bun.write(BASELINE, toJson(now));
      console.log(`baseline: ${diagnostics.length} findings recorded`);

      return 0;
    }

    return report(diagnostics, drift(await load(), now));
  };

if (import.meta.main) {
  // oxlint-disable-next-line node/no-top-level-await -- a bun entrypoint no module requires; the preset's prefer-top-level-await forbids the alternative
  process.exitCode = await verify();
}

export { count, drift };
