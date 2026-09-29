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
    /* Oxlint has no in-process API, so the pinned binary runs as a child. */
    const child = Bun.spawn(["bunx", "oxlint", "--report-unused-disable-directives-severity=error", "-f", "json"], {
        stderr: "inherit",
        stdout: "pipe",
      }),
      text = await new Response(child.stdout).text();

    await child.exited;

    return Report.parse(JSON.parse(text)).diagnostics;
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
