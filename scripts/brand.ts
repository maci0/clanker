/*
 * Builds docs/brand/ and the web UI favicon from their sources: the colour
 * tokens in ui/app/tailwind.src.css, the icon grid in ui/app/core/icons.js,
 * and the mark and wordmark geometry below.
 *
 *   bun scripts/brand.ts           write every output
 *   bun scripts/brand.ts --check   fail when an output differs from a fresh build
 */
import { ICON_PATHS } from "../ui/app/core/icons.js";

type Palette = Map<string, string>;

type Output = { path: string; text: string };

type Glyph = { d: (x: number) => string; width: number };

type Run = { d: string; width: number };

type Pair = { back: string; fore: string; minimum: number; use: string };

const BRAND = "docs/brand",
  CAP = 3.5,
  FAVICON = /<link rel="icon" href="[^"]*">/u,
  GAP = 7,
  /* Centerline geometry of each glyph on a 28-unit cap height: x-height 11..27, ascenders from 1, bowls of radius 8. */
  GLYPHS = {
    a: { d: (x) => `M${x + 16} 19A8 8 0 1 0 ${x} 19A8 8 0 1 0 ${x + 16} 19M${x + 16} 11V27`, width: 16 },
    c: { d: (x) => `M${x + 13.14} 12.87A8 8 0 1 0 ${x + 13.14} 25.13`, width: 13.14 },
    e: { d: (x) => `M${x} 19H${x + 16}A8 8 0 1 0 ${x + 13.66} 24.66`, width: 16 },
    k: { d: (x) => `M${x} 1V27M${x + 12.5} 11L${x} 21.5M${x + 5} 17.5L${x + 13} 27`, width: 13 },
    l: { d: (x) => `M${x} 1V27`, width: 0 },
    n: { d: (x) => `M${x} 11V27M${x} 19A8 8 0 0 1 ${x + 16} 19V27`, width: 16 },
    r: { d: (x) => `M${x} 11V27M${x} 18.5A7.5 7.5 0 0 1 ${x + 7.5} 11H${x + 10}`, width: 10 },
  } satisfies Record<string, Glyph>,
  ICON_CELL = { height: 84, width: 104 },
  ICON_COLUMNS = 8,
  MASTHEAD = /<h1><svg class="logo"[\s\S]*?<\/h1>/u,
  /* The text and signal pairs the UI actually sets, with the WCAG 2.2 AA minimum each must meet. */
  PAIRS: Array<Pair> = [
    { back: "bg", fore: "fg", minimum: 4.5, use: "body text on the page" },
    { back: "surface", fore: "fg", minimum: 4.5, use: "body text on a panel" },
    { back: "surface-2", fore: "fg", minimum: 4.5, use: "body text in a well" },
    { back: "bg", fore: "fg-muted", minimum: 4.5, use: "metadata on the page" },
    { back: "surface", fore: "fg-muted", minimum: 4.5, use: "metadata on a panel" },
    { back: "surface", fore: "accent-text", minimum: 4.5, use: "links on a panel" },
    { back: "accent", fore: "on-accent", minimum: 4.5, use: "primary button label" },
    { back: "surface", fore: "ok", minimum: 4.5, use: "healthy state text" },
    { back: "surface", fore: "warn-text", minimum: 4.5, use: "warning text" },
    { back: "surface", fore: "danger", minimum: 4.5, use: "fault text" },
    { back: "surface", fore: "border", minimum: 3, use: "control boundary (non-text)" },
    { back: "rail-bg", fore: "rail-fg", minimum: 4.5, use: "sidebar destination" },
    { back: "rail-active", fore: "rail-fg", minimum: 4.5, use: "sidebar current page" },
    { back: "rail-bg", fore: "rail-muted", minimum: 4.5, use: "sidebar group label" },
    { back: "rail-active", fore: "rail-mark", minimum: 3, use: "current-page marker (non-text)" },
  ],
  README = `${BRAND}/README.md`,
  README_TABLE = /<!-- contrast:start -->[\s\S]*?<!-- contrast:end -->/u,
  ROOT = new URL("../", import.meta.url),
  SWATCH = { height: 64, width: 132 },
  TOKENS = ["bg", "surface", "surface-2", "border", "rule", "fg", "fg-muted", "accent", "ok", "warn", "danger"],
  WORD = ["c", "l", "a", "n", "k", "e", "r"] satisfies Array<keyof typeof GLYPHS>,
  /* WCAG relative luminance of a #rrggbb colour. */
  brightness = (hex: string): number => {
    const channels = [1, 3, 5].map((at) => Number.parseInt(hex.slice(at, at + 2), 16) / 255),
      linear = channels.map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));

    return 0.2126 * (linear[0] ?? 0) + 0.7152 * (linear[1] ?? 0) + 0.0722 * (linear[2] ?? 0);
  },
  colourOf = (palette: Palette, name: string): string => {
    const value = palette.get(name);

    if (value === undefined) {
      throw new Error(`token --${name} has no hex value in tailwind.src.css`);
    }

    return value;
  },
  /* WCAG contrast ratio of two #rrggbb colours. */
  contrast = (a: string, b: string): number => {
    const [high = 0, low = 0] = [brightness(a), brightness(b)].toSorted((x, y) => y - x);

    return (high + 0.05) / (low + 0.05);
  },
  /* The contrast table the brand guide carries, one row per pair, both themes. */
  contrastTable = (day: Palette, night: Palette): string => {
    const cell = (palette: Palette, pair: Pair): string => {
        const ratio = contrast(colourOf(palette, pair.fore), colourOf(palette, pair.back));

        return `${ratio.toFixed(2)}:1 ${ratio >= pair.minimum ? "pass" : "FAIL"}`;
      },
      rows = PAIRS.map((pair) => `| \`--${pair.fore}\` on \`--${pair.back}\` | ${pair.use} | ${cell(day, pair)} | ${cell(night, pair)} | ${pair.minimum}:1 |`);

    return ["<!-- contrast:start -->", "| Pair | Used for | Day | Night | AA minimum |", "|---|---|---|---|---|", ...rows, "<!-- contrast:end -->"].join("\n");
  },
  /* An SVG as a data URI, escaping only what a URI and an HTML attribute require. */
  dataUri = (text: string): string =>
    `data:image/svg+xml,${text
      .trim()
      .replaceAll(/\s*\n\s*/gu, "")
      .replaceAll('"', "'")
      .replaceAll(/[%#<> ]/gu, (c) => encodeURIComponent(c))}`,
  drawSvg = (width: number, height: number, body: string, label: string): string =>
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${height}" width="${width}" height="${height}" role="img" aria-label="${label}">\n${body}\n</svg>\n`,
  /* The word "clanker" as one centerline path, and its width. */
  glyphRun = (): Run => {
    const parts: Array<string> = [];
    let x = 0;

    for (const letter of WORD) {
      parts.push(GLYPHS[letter].d(x));
      x += GLYPHS[letter].width + GAP;
    }

    return { d: parts.join(""), width: x - GAP };
  },
  iconFile = (paths: ReadonlyArray<string>): string =>
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="square" stroke-linejoin="miter">\n${paths.map((d) => `  <path d="${d}"/>`).join("\n")}\n</svg>\n`,
  /* A standalone page listing every icon at two sizes with its name and file, for browsing outside the repo viewer. */
  iconIndex = (day: Palette): string => {
    const cells = Object.entries(ICON_PATHS)
      .toSorted(([a], [b]) => a.localeCompare(b))
      .map(
        ([name, paths]) =>
          `<li><a href="icons/${name}.svg"><svg viewBox="0 0 24 24" width="32" height="32" aria-hidden="true">${paths.map((d) => `<path d="${d}"/>`).join("")}</svg><svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">${paths.map((d) => `<path d="${d}"/>`).join("")}</svg><code>${name}</code></a></li>`,
      );

    return [
      "<!doctype html>",
      '<html lang="en">',
      "<head>",
      '<meta charset="utf-8">',
      '<meta name="viewport" content="width=device-width, initial-scale=1">',
      "<title>clanker icons</title>",
      "<style>",
      `body{margin:0;padding:2rem 1rem;background:${colourOf(day, "bg")};color:${colourOf(day, "fg")};font:1rem/1.6 ui-sans-serif,system-ui,sans-serif}`,
      "main{max-width:64rem;margin:0 auto}h1{font-size:1.375rem;font-weight:600;margin:0 0 .4rem}p{margin:0 0 1.4rem;max-width:70ch}",
      "ul{list-style:none;margin:0;padding:0;display:grid;grid-template-columns:repeat(auto-fill,minmax(8rem,1fr));gap:.6rem}",
      `a{display:flex;flex-direction:column;align-items:center;gap:.4rem;padding:.9rem .4rem;border:1px solid ${colourOf(day, "rule")};border-radius:4px;background:${colourOf(day, "surface")};color:inherit;text-decoration:none}`,
      `a:hover{border-color:${colourOf(day, "border")}}a:focus-visible{outline:2px solid ${colourOf(day, "accent")};outline-offset:2px}`,
      "svg{fill:none;stroke:currentColor;stroke-width:1.75;stroke-linecap:square;stroke-linejoin:miter}",
      `code{font:.75rem ui-monospace,monospace;color:${colourOf(day, "fg-muted")}}`,
      "</style>",
      "</head>",
      "<body>",
      "<main>",
      "<h1>clanker icons</h1>",
      `<p>${cells.length} icons on one 24-unit grid with a 1.75 stroke. Each links to its SVG, which draws in <code>currentColor</code>. The source is <code>ICON_PATHS</code> in <code>ui/app/core/icons.js</code>.</p>`,
      `<ul>
${cells.join("\n")}
</ul>`,
      "</main>",
      "</body>",
      "</html>",
      "",
    ].join("\n");
  },
  /* Every icon drawn at 32px on a labelled grid. */
  iconSheet = (light: Palette): string => {
    const all = Object.entries(ICON_PATHS).toSorted(([a], [b]) => a.localeCompare(b)),
      cells = all.map(([name, paths], i) => {
        const x = (i % ICON_COLUMNS) * ICON_CELL.width,
          y = Math.floor(i / ICON_COLUMNS) * ICON_CELL.height;

        return [
          `<g transform="translate(${x + (ICON_CELL.width - 32) / 2} ${y + 12}) scale(${32 / 24})" fill="none" stroke="${colourOf(light, "fg")}" stroke-width="1.75" stroke-linecap="square" stroke-linejoin="miter">`,
          ...paths.map((d) => `  <path d="${d}"/>`),
          "</g>",
          `<text x="${x + ICON_CELL.width / 2}" y="${y + 66}" text-anchor="middle" font-family="ui-monospace, monospace" font-size="11" fill="${colourOf(light, "fg-muted")}">${name}</text>`,
        ].join("\n");
      });

    return drawSvg(
      ICON_COLUMNS * ICON_CELL.width,
      Math.ceil(all.length / ICON_COLUMNS) * ICON_CELL.height,
      `<rect width="100%" height="100%" fill="${colourOf(light, "surface")}"/>\n${cells.join("\n")}`,
      "clanker icon library",
    );
  },
  /* The mark: a machined plate, its bezel, a lit signal lamp and a legend strip, on a 32-unit grid. */
  lampMark = (dark: Palette, light: Palette, dome = "dome"): string =>
    [
      "<defs>",
      `  <radialGradient id="${dome}" cx="35%" cy="30%" r="70%"><stop offset="0" stop-color="#ffffff" stop-opacity="0.85"/><stop offset="0.5" stop-color="#ffffff" stop-opacity="0"/><stop offset="0.6" stop-color="${colourOf(dark, "code-bg")}" stop-opacity="0"/><stop offset="1" stop-color="${colourOf(dark, "code-bg")}" stop-opacity="0.5"/></radialGradient>`,
      "</defs>",
      `<rect width="32" height="32" rx="6" fill="${colourOf(dark, "bg")}"/>`,
      `<rect x="2.75" y="2.75" width="26.5" height="26.5" rx="4" fill="none" stroke="${colourOf(dark, "border")}" stroke-width="1.5"/>`,
      `<circle cx="16" cy="14" r="7.25" fill="${colourOf(dark, "code-bg")}"/>`,
      `<circle cx="16" cy="14" r="6" fill="${colourOf(light, "ok")}"/>`,
      `<circle cx="16" cy="14" r="6" fill="url(#${dome})"/>`,
      `<rect x="10" y="24" width="12" height="2.5" rx="1" fill="${colourOf(dark, "fg-muted")}"/>`,
    ].join("\n"),
  /* The mark at 48px beside the wordmark at the same cap height. */
  lockup = (dark: Palette, light: Palette, ink: string): string => {
    const run = glyphRun(),
      scale = 1.25;

    return drawSvg(
      Math.ceil(48 + 16 + (run.width + CAP) * scale),
      48,
      [
        `<g transform="scale(1.5)">\n${lampMark(dark, light)}\n</g>`,
        `<path d="${run.d}" transform="translate(${64 + (CAP * scale) / 2} 4) scale(${scale})" fill="none" stroke="${ink}" stroke-width="${CAP}" stroke-linecap="square"/>`,
      ].join("\n"),
      "clanker",
    );
  },
  /* The masthead's brand: the mark and the wordmark, inked in the theme's text colour. */
  masthead = (dark: Palette, light: Palette): string => {
    const run = glyphRun(),
      width = Math.ceil(run.width + CAP);

    return [
      `<h1><svg class="logo" width="22" height="22" viewBox="0 0 32 32" aria-hidden="true" focusable="false">${lampMark(dark, light, "brand-dome")}</svg>`,
      `<svg class="flex-none" width="${Math.round((width * 16) / 30)}" height="16" viewBox="0 0 ${width} 30" aria-hidden="true" focusable="false"><path d="${run.d}" transform="translate(${CAP / 2} 1)" fill="none" stroke="currentColor" stroke-width="${CAP}" stroke-linecap="square"/></svg><span class="sr-only">clanker</span></h1>`,
    ].join("");
  },
  /* One row of swatches per theme, each named by its token and value. */
  palette = (light: Palette, dark: Palette): string => {
    const bands = [
        { name: "Day shift", tokens: light, top: 0 },
        { name: "Night shift", tokens: dark, top: SWATCH.height + 40 },
      ],
      cells = bands.flatMap((row) => [
        `<text x="0" y="${row.top + 14}" font-family="ui-monospace, monospace" font-size="12" font-weight="600" fill="${colourOf(light, "fg-muted")}" letter-spacing="0.72">${row.name.toUpperCase()}</text>`,
        ...TOKENS.map((token, i) => {
          const x = i * SWATCH.width,
            y = row.top + 22;

          return [
            `<rect x="${x + 0.5}" y="${y + 0.5}" width="${SWATCH.width - 9}" height="${SWATCH.height - 25}" rx="3" fill="${colourOf(row.tokens, token)}" stroke="${colourOf(light, "border")}"/>`,
            `<text x="${x}" y="${y + SWATCH.height - 10}" font-family="ui-monospace, monospace" font-size="11" fill="${colourOf(light, "fg")}">--${token}</text>`,
            `<text x="${x}" y="${y + SWATCH.height + 4}" font-family="ui-monospace, monospace" font-size="11" fill="${colourOf(light, "fg-muted")}">${colourOf(row.tokens, token)}</text>`,
          ].join("\n");
        }),
      ]);

    return drawSvg(
      TOKENS.length * SWATCH.width,
      2 * SWATCH.height + 40 + 22 + 16,
      `<rect width="100%" height="100%" fill="${colourOf(light, "surface")}"/>\n${cells.join("\n")}`,
      "clanker colour tokens",
    );
  },
  plainWordmark = (ink: string): string => {
    const run = glyphRun();

    return drawSvg(
      Math.ceil(run.width + CAP),
      30,
      `<path d="${run.d}" transform="translate(${CAP / 2} 1)" fill="none" stroke="${ink}" stroke-width="${CAP}" stroke-linecap="square"/>`,
      "clanker",
    );
  },
  /* The hex tokens of the first rule in `css` whose selector starts with `selector`. */
  readTokens = (css: string, selector: string): Palette => {
    const at = css.indexOf(selector),
      body = css.slice(at, css.indexOf("}", at));

    if (at === -1) {
      throw new Error(`tailwind.src.css has no ${selector} block`);
    }

    return new Map(
      Array.from(body.matchAll(/--(?<name>[\w-]+):\s*(?<value>#[0-9a-f]{6})/gu), (m) => [
        m.groups?.name ?? "",
        m.groups?.value ?? "",
      ]),
    );
  },
  renderAll = async (): Promise<Array<Output>> => {
    const css = await Bun.file(new URL("ui/app/tailwind.src.css", ROOT)).text(),
      day = readTokens(css, ":root {"),
      guide = await Bun.file(new URL(README, ROOT)).text(),
      html = await Bun.file(new URL("ui/app/index.html", ROOT)).text(),
      night = new Map([...day, ...readTokens(css, ":root:not([data-theme]) {")]),
      plate = drawSvg(32, 32, lampMark(night, day), "clanker");

    return [
      { path: `${BRAND}/mark.svg`, text: plate },
      { path: `${BRAND}/wordmark.svg`, text: plainWordmark(colourOf(day, "fg")) },
      { path: `${BRAND}/wordmark-dark.svg`, text: plainWordmark(colourOf(night, "fg")) },
      { path: `${BRAND}/lockup.svg`, text: lockup(night, day, colourOf(day, "fg")) },
      { path: `${BRAND}/lockup-dark.svg`, text: lockup(night, day, colourOf(night, "fg")) },
      { path: `${BRAND}/palette.svg`, text: palette(day, night) },
      { path: `${BRAND}/icons.svg`, text: iconSheet(day) },
      { path: `${BRAND}/icons.html`, text: iconIndex(day) },
      { path: README, text: guide.replace(README_TABLE, contrastTable(day, night)) },
      ...Object.entries(ICON_PATHS).map(([name, paths]) => ({ path: `${BRAND}/icons/${name}.svg`, text: iconFile(paths) })),
      { path: "ui/app/index.html", text: html.replace(FAVICON, `<link rel="icon" href="${dataUri(plate)}">`).replace(MASTHEAD, masthead(night, day)) },
    ];
  },
  run = async (): Promise<number> => {
    const check = Bun.argv.includes("--check"),
      outputs = await renderAll(),
      stale: Array<string> = [];

    for (const out of outputs) {
      const file = Bun.file(new URL(out.path, ROOT)),
        present = (await file.exists()) ? await file.text() : "";

      if (present !== out.text) {
        stale.push(out.path);
      }

      if (!check && present !== out.text) {
        await Bun.write(file, out.text);
      }
    }

    if (check && stale.length > 0) {
      console.error(`stale brand outputs (run: bun scripts/brand.ts):\n  ${stale.join("\n  ")}`);

      return 1;
    }

    console.log(check ? `brand: ${outputs.length} outputs current` : `brand: wrote ${stale.length} of ${outputs.length} outputs`);

    return 0;
  };

// oxlint-disable-next-line node/no-top-level-await -- a bun entrypoint no module requires; the preset's prefer-top-level-await forbids the alternative
process.exitCode = await run();
