/*
 * WCAG 2.2 AA contrast for every palette the web UI ships: the day and night
 * cabinet in tailwind.src.css and each named theme in themes/. Text pairs need
 * 4.5:1; a control's edge needs 3:1 against both surfaces it sits on (1.4.11),
 * which every palette but two failed before this suite existed.
 */
import { expect, test } from "bun:test";

type Tokens = Map<string, string>;

type Pair = { back: string; fore: string; minimum: number };

const PAIRS: Array<Pair> = [
    { back: "--bg", fore: "--fg", minimum: 4.5 },
    { back: "--surface", fore: "--fg", minimum: 4.5 },
    { back: "--bg", fore: "--fg-muted", minimum: 4.5 },
    { back: "--surface", fore: "--fg-muted", minimum: 4.5 },
    { back: "--surface", fore: "--accent-text", minimum: 4.5 },
    { back: "--accent", fore: "--on-accent", minimum: 4.5 },
    { back: "--surface", fore: "--danger", minimum: 4.5 },
    { back: "--surface", fore: "--border", minimum: 3 },
    { back: "--bg", fore: "--border", minimum: 3 },
  ],
  ROOT = new URL("../../", import.meta.url),
  brightness = (hex: string): number => {
    const linear = [1, 3, 5]
      .map((at) => Number.parseInt(hex.slice(at, at + 2), 16) / 255)
      .map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));

    return 0.2126 * (linear[0] ?? 0) + 0.7152 * (linear[1] ?? 0) + 0.0722 * (linear[2] ?? 0);
  },
  /* A token's hex value, following `var(--x)` aliases; "" when it is not a plain hex colour. */
  colourOf = (tokens: Tokens, name: string, depth = 0): string => {
    const raw = tokens.get(name) ?? "",
      target = /^var\((?<next>--[\w-]+)\)$/u.exec(raw)?.groups?.next;

    return target !== undefined && depth < 8 ? colourOf(tokens, target, depth + 1) : (/^#[0-9a-f]{6}$/iu.exec(raw)?.[0] ?? "");
  },
  contrast = (a: string, b: string): number => {
    const [high = 0, low = 0] = [brightness(a), brightness(b)].toSorted((x, y) => y - x);

    return (high + 0.05) / (low + 0.05);
  },
  cssTokens = (css: string, selector: string): Tokens => {
    const at = css.indexOf(selector),
      body = css.slice(at, css.indexOf("}", at));

    return new Map(Array.from(body.matchAll(/(?<name>--[\w-]+):\s*(?<value>[^;]+);/gu), (m) => [m.groups?.name ?? "", (m.groups?.value ?? "").trim()]));
  },
  /* Every pair below its minimum, as "palette: fore on back ratio". */
  failures = (palette: string, tokens: Tokens): Array<string> =>
    PAIRS.flatMap((pair) => {
      const back = colourOf(tokens, pair.back),
        fore = colourOf(tokens, pair.fore),
        ratio = back === "" || fore === "" ? pair.minimum : contrast(fore, back);

      return ratio < pair.minimum ? [`${palette}: ${pair.fore} on ${pair.back} ${ratio.toFixed(2)}:1`] : [];
    }),
  themePaths = async (): Promise<Array<string>> => {
    const paths: Array<string> = [];

    for await (const path of new Bun.Glob("themes/*.json").scan(ROOT.pathname)) {
      paths.push(path);
    }

    return paths.toSorted();
  },
  themeTokens = async (path: string): Promise<Tokens> => {
    const json: unknown = await Bun.file(path).json(),
      tokens = json instanceof Object && "tokens" in json && json.tokens instanceof Object ? json.tokens : {};

    return new Map(Object.entries(tokens).map(([name, value]) => [name, String(value)]));
  };

test("the day and night cabinet meet WCAG AA for every text and control pair", async () => {
  const css = await Bun.file(new URL("ui/app/tailwind.src.css", ROOT)).text(),
    day = cssTokens(css, ":root {"),
    night = new Map([...day, ...cssTokens(css, ":root:not([data-theme]) {")]);

  expect(colourOf(day, "--border")).not.toBe("");
  expect([...failures("day", day), ...failures("night", night)]).toEqual([]);
});

test("every named theme meets WCAG AA for every text and control pair", async () => {
  const names = await themePaths(),
    palettes = await Promise.all(names.map(async (path): Promise<[string, Tokens]> => [path, await themeTokens(new URL(path, ROOT).pathname)]));

  expect(names.length).toBeGreaterThan(5);
  expect(palettes.flatMap(([path, tokens]) => failures(path, tokens))).toEqual([]);
});
