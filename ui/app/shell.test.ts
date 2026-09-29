/*
 * The page shell and the class lists views build it from, pinned against the
 * shipped files. Each case below is a defect that reached a release: the
 * browser recovered from every one of them silently, so only a test notices.
 */
import { expect, test } from "bun:test";
import { isInventoryStatus } from "./core/utils.js";

type Objects = Map<string, Set<string>>;

const DISPLAY = new Set(["hidden", "block", "inline-block", "inline", "flex", "inline-flex", "grid", "inline-grid", "contents", "table"]),
  RAIL = {
    "Set up": ["models", "knowledge", "prompts", "tools", "system"],
    Watch: ["runs", "fleet", "arena", "rooms"],
    Work: ["chat", "kanban"],
  },
  /* A named group's text, or "" when the group did not take part in the match. */
  captured = (m: RegExpMatchArray, key: string): string => m.groups?.[key] ?? "",
  /* The class-list strings a file hands the DOM: literal attributes in HTML, named `*_CLASS` constants in JS. */
  classLists = (text: string): Array<string> => [
    ...Array.from(text.matchAll(/class="(?<list>[^"]*)"/gu), (m) => captured(m, "list")),
    ...Array.from(text.matchAll(/\b[A-Z][A-Z0-9_]*CLASS\s*=\s*"(?<list>[^"]*)"/gu), (m) => captured(m, "list")),
  ],
  /* Two unconditional display utilities in one list, as "file: a b". */
  displayClashes = (file: string, text: string): Array<string> =>
    classLists(text).flatMap((list) => {
      const set = list.split(/\s+/u).filter((c) => DISPLAY.has(c));

      return set.length > 1 ? [`${file}: ${set.join(" ")}`] : [];
    }),
  here = new URL(".", import.meta.url),
  /* `local.key` reads of a core/ui.js object that name a key the object lacks. */
  missingKeys = (file: string, text: string, objects: Objects): Array<string> => {
    const bound = new Map<string, string>();

    for (const m of text.matchAll(/import \{(?<names>[^}]*)\} from "[./]*(?:core\/)?ui\.js"/gu)) {
      for (const spec of (captured(m, "names")).split(",")) {
        const [name = "", alias = name] = spec.trim().split(/\s+as\s+/u);

        bound.set(alias, name);
      }
    }

    for (const m of text.matchAll(/\bvar (?<local>\w+) = (?<source>\w+);/gu)) {
      bound.set(captured(m, "local"), bound.get(captured(m, "source")) ?? "");
    }

    return [...bound].flatMap(([local, name]) => {
      const keys = objects.get(name);

      return keys === undefined
        ? []
        : Array.from(text.matchAll(new RegExp(`(?<![\\w.])${local}\\.(?<key>\\w+)`, "gu")), (m) => captured(m, "key"))
            .filter((key) => !keys.has(key))
            .map((key) => `${file}: ${local}.${key}`);
    });
  },
  /* `classList.add(X_CLASS)` where X_CLASS holds more than one class, as "file: X_CLASS". */
  multiTokenCalls = (file: string, text: string): Array<string> => {
    const lists = new Map(
      Array.from(text.matchAll(/\b(?<name>[A-Z][A-Z0-9_]*CLASS)\s*=\s*"(?<list>[^"]*)"/gu), (m) => [m.groups?.name, captured(m, "list")]),
    );

    return Array.from(text.matchAll(/classList\.(?:add|remove|toggle)\(\s*(?<name>[A-Z][A-Z0-9_]*CLASS)\b/gu), (m) => captured(m, "name")).flatMap(
      (name) => (/\s/u.test(lists.get(name) ?? "") ? [`${file}: ${name}`] : []),
    );
  },
  read = (path: string): Promise<string> => Bun.file(new URL(path, here)).text(),
  /* Each path paired with its text. */
  readAll = (paths: Array<string>): Promise<Array<[string, string]>> => Promise.all(paths.map(async (path): Promise<[string, string]> => [path, await read(path)])),
  /* Every JS file under ui/app a view is built from, relative to ui/app. */
  sources = async (): Promise<Array<string>> => {
    const found: Array<string> = [];

    for await (const path of new Bun.Glob("**/*.js").scan(here.pathname)) {
      found.push(path);
    }

    return found.toSorted();
  },
  /* The keys of each `export var name = { … };` class-list object in core/ui.js. */
  uiObjects = (text: string): Objects =>
    new Map(
      Array.from(text.matchAll(/^export var (?<name>\w+) = \{\n(?<body>[\s\S]*?)^\};/gmu), (m) => [
        captured(m, "name"),
        new Set(Array.from((captured(m, "body")).matchAll(/^ {2}(?<key>\w+)\s*(?:[:,(]|$)/gmu), (k) => captured(k, "key"))),
      ]),
    );

test("the page is a two-row grid: masthead above, rail and shell side by side below", async () => {
  const [css, html] = await Promise.all([read("tailwind.src.css"), read("index.html")]),
    shells = Array.from(css.matchAll(/(?:^|[}/])\s*\.shell\s*\{(?<body>[^}]+)\}/gmu), (m) => captured(m, "body"));

  /*
   * A flex-wrap page wrapped a wide view under the rail, and its full-height
   * rail and shell overflowed the page by the masthead's height. A grid sizes
   * the second row to what is left, and on a phone, where the rail is fixed
   * and out of the flow, the shell takes both columns.
   */
  expect(shells).toHaveLength(1);
  expect(shells.at(0)).toContain("min-width: 0;");
  expect(html).toContain('class="grid h-full min-h-0 flex-1 grid-cols-[auto_minmax(0,1fr)] grid-rows-[auto_minmax(0,1fr)]" id="app-page"');
  expect(html).toContain('<header class="col-span-2 border-b border-rule" id="app-masthead">');
  expect(html).toContain('<aside class="rail row-start-2 ');
  expect(html).toMatch(/<div class="shell col-start-2 row-start-2 [^"]*max-\[640px\]:col-span-2 max-\[640px\]:col-start-1"/u);
});

test("no class list sets two unconditional display utilities", async () => {
  /* Tailwind orders display utilities by its own table, so `inline-flex hidden` is always inline-flex. */
  const all = ["index.html", ...(await sources())],
    bodies = await readAll(all),
    clashes = bodies.flatMap(([file, text]) => displayClashes(file, text));

  expect(clashes).toEqual([]);
});

test("no classList call is handed a whole class list as one token", async () => {
  /* DOMTokenList.add throws on a token containing a space; the Kanban board failed on load. */
  const all = await sources(),
    bodies = await readAll(all),
    offenders = bodies.flatMap(([file, text]) => multiTokenCalls(file, text));

  expect(all).toContain("features/board.js");
  expect(offenders).toEqual([]);
});

test("every class-list key a view reads from core/ui.js exists there", async () => {
  /* A key read under the wrong object is undefined, which the DOM writes as the class "undefined". */
  const api = uiObjects(await read("core/ui.js")),
    everything = await sources(),
    files = everything.filter((file) => file !== "core/ui.js"),
    gathered = await readAll(files),
    missing = gathered.flatMap(([file, text]) => missingKeys(file, text, api));

  expect(api.get("toolRow")).toContain("tag");
  expect(files).toContain("features/fleet.js");
  expect([...new Set(missing)]).toEqual([]);
});

test("each rail list names its group, and plugin tabs have somewhere to land", async () => {
  /* The tab placement in core/plugins.js reads `data-rail-group`; the rail port dropped the old hook and no plugin tab rendered. */
  const html = await read("index.html"),
    lists = Array.from(html.matchAll(/<ul\b[^>]*data-rail-group="(?<group>[^"]+)"[^>]*>(?<body>[\s\S]*?)<\/ul>/gu), (m) => ({
      body: captured(m, "body"),
      group: captured(m, "group"),
    })),
    placed = Object.fromEntries(
      lists.map((l) => [l.group, Array.from(l.body.matchAll(/id="tab-(?<view>[\w-]+)"/gu), (m) => captured(m, "view"))]),
    );

  expect(lists.map((l) => l.group)).toEqual(["Work", "Watch", "Set up"]);
  expect(placed).toEqual(RAIL);
});

test("Arena and Compare announce their status instead of printing it under their empty state", async () => {
  const [html, compare] = await Promise.all([read("index.html"), read("../plugins/compare/app.js")]);

  expect(html).toContain('<p class="sr-only" id="arena-status" role="status"');
  expect(compare).toContain('var status = api.el("p", "sr-only");');
});

test("an inventory line is a count or an empty list, never an error or a result", () => {
  const inventory = ["7 skills.", "No prompts.", "43 items.", "0 collections.", "No log files yet.", "1,204 runs."],
    other = ["Could not load tools: 500", "Saved prompt.", "No provider answered: timeout after 30s", "Copied 3 lines", ""];

  expect(inventory.map((line) => isInventoryStatus(line))).toEqual(inventory.map(() => true));
  expect(other.map((line) => isInventoryStatus(line))).toEqual(other.map(() => false));
});

test("each folding rail group draws its caret", async () => {
  /* The caret is `.rail-fold > summary.rail-group::after`; the rail port dropped both classes, so Watch and Set up read as bare labels. */
  const [css, html] = await Promise.all([read("tailwind.src.css"), read("index.html")]),
    folds = Array.from(html.matchAll(/<details class="(?<list>[^"]*)" id="rail-fold-(?<name>\w+)">\s*<summary class="(?<summary>[^"]*)"/gu), (m) => ({
      details: captured(m, "list").split(" "),
      summary: captured(m, "summary").split(" "),
    }));

  expect(css).toContain(".rail-fold > summary.rail-group::after");
  expect(folds).toHaveLength(2);
  expect(folds.map((f) => [f.details.includes("rail-fold"), f.summary.includes("rail-group")])).toEqual([
    [true, true],
    [true, true],
  ]);
});

test("the rail scrolls as a whole before the conversation list collapses", async () => {
  /* With both folds open the list shrank to nothing and Set up drew over its only row. */
  const html = await read("index.html");

  expect(html).toMatch(/<aside class="rail [^"]*\boverflow-y-auto\b/u);
  expect(html).toMatch(/<div class="[^"]*\bmin-h-fit\b[^"]*" data-rail-section="context" id="rail-context"/u);
  expect(html).toMatch(/<ul class="mt-4 flex min-h-24 flex-1 list-none/u);
});
