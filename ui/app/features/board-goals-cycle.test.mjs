// The board and the goals view are one workflow in two files: a goal is a
// board card (`card.goal`), moving a card moves its goal, and creating a goal
// mirrors a card. So `features/board.js` and `features/goals.js` each needed
// the other, and each imported the other.
//
// That is not a style complaint. Two ESM modules that import each other are
// instantiated in link order, so a module body's read of the other's top-level
// state is whatever ran before it — here `board` (the exported card list
// object) and `goalState` (a signal). Which of the two initialised first was a
// property of the import graph, and a new import added to either side could
// move it without changing any line that reads it. The two seams both modules
// already had for exactly this purpose — `bindBoard(deps)` and `bindGoals(deps)`
// — carry the hand-off instead, so `goals -> board` is the only edge left.
//
// This suite pins the property rather than the prose: it walks the shipped
// relative imports under `ui/` and fails on any cycle, so a later mutual
// import anywhere in the surface is caught even if both sides look reachable
// today. It also pins the seam itself, since a cycle-free pair that no longer
// hands over `board` compiles fine and then does nothing at runtime.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve, relative } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const uiRoot = join(here, "..", "..");
const boardPath = join(here, "board.js");
const goalsPath = join(here, "goals.js");
const appPath = join(here, "..", "app.js");

// `import x from "./y.js"` and `import { a, b as c } from "./y.js"`, plus the
// bare `import "./y.js"` side-effect form. Dynamic `import("./y.js")` is
// included: it resolves the same module and creates the same edge.
const IMPORT_RE = /(?:^|[\s;}])(?:import|export)\s*(?:[\s\S]*?)\bfrom\s*["'](\.[^"']+)["']|(?:^|[\s;}])import\s*\(\s*["'](\.[^"']+)["']\s*\)/g;

function walk(dir, out) {
  for (const name of readdirSync(dir)) {
    if (name === "node_modules" || name === "vendor" || name === "dist") continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (p.endsWith(".js") || p.endsWith(".mjs") || p.endsWith(".ts")) out.push(p);
  }
  return out;
}

function resolveFrom(fromFile, spec) {
  const base = resolve(dirname(fromFile), spec);
  for (const candidate of [base, base + ".js", base + ".mjs", base + ".ts", join(base, "index.js")]) {
    try {
      if (statSync(candidate).isFile()) return candidate;
    } catch { /* not a file; try the next shape */ }
  }
  return null;
}

function graph() {
  const g = new Map();
  for (const file of walk(uiRoot, [])) {
    const src = readFileSync(file, "utf8");
    const edges = new Set();
    for (const m of src.matchAll(IMPORT_RE)) {
      const target = resolveFrom(file, m[1] || m[2]);
      if (target) edges.add(target);
    }
    g.set(file, edges);
  }
  return g;
}

// Tarjan, iterative: a deep chain here would blow the recursive form's stack.
function cyclesIn(g) {
  const index = new Map();
  const low = new Map();
  const onStack = new Set();
  const stack = [];
  const found = [];
  let n = 0;
  const nodes = [...g.keys()].sort();

  for (const start of nodes) {
    if (index.has(start)) continue;
    const work = [[start, [...(g.get(start) || [])].sort()]];
    index.set(start, n);
    low.set(start, n);
    n += 1;
    stack.push(start);
    onStack.add(start);

    while (work.length) {
      const frame = work[work.length - 1];
      const node = frame[0];
      let descended = false;
      while (frame[1].length) {
        const w = frame[1].shift();
        if (!index.has(w)) {
          index.set(w, n);
          low.set(w, n);
          n += 1;
          stack.push(w);
          onStack.add(w);
          work.push([w, [...(g.get(w) || [])].sort()]);
          descended = true;
          break;
        }
        if (onStack.has(w)) low.set(node, Math.min(low.get(node), index.get(w)));
      }
      if (descended) continue;
      work.pop();
      if (work.length) {
        const parent = work[work.length - 1][0];
        low.set(parent, Math.min(low.get(parent), low.get(node)));
      }
      if (low.get(node) === index.get(node)) {
        const comp = [];
        for (;;) {
          const w = stack.pop();
          onStack.delete(w);
          comp.push(w);
          if (w === node) break;
        }
        if (comp.length > 1) found.push(comp.sort());
      }
    }
  }
  return found;
}

// The two feature modules import core/ui.js, which imports the vendored signals
// library through the browser's import map (`/webui/vendor/...`). Node has no
// import map, so that specifier is rewritten here to the file under ui/vendor/.
// Only the harness does this; the browser resolves it from index.html.
const vendorRoot = join(uiRoot, "vendor") + "/";

try {
  const { plugin } = await import("bun");

  plugin({
    name: "webui-import-map",
    setup(build) {
      build.onResolve({ filter: /^\/webui\// }, (args) => ({
        path: vendorRoot + args.path.slice("/webui/vendor/".length),
      }));
    },
  });
} catch {
  // Not bun: the seam test below needs the resolver and will say so.
}

/* Installs just enough of the browser's global surface for the two feature
   modules to evaluate and for a view to render into: core/ui.js reads
   `document` and `Node` while it builds. Installed at module scope, not around
   the import, because a view renders when a signal fires rather than during
   module evaluation. bun runs each test file in its own realm, so none of this
   reaches another suite. */
const stubElement = () => ({
  appendChild() {}, addEventListener() {}, style: {},
  classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
  value: "", textContent: "", dataset: {}, children: [],
  querySelector: () => null, querySelectorAll: () => [],
  setAttribute() {}, getAttribute: () => null, removeAttribute() {},
});

globalThis.document = {
  createElement: stubElement,
  createTextNode: (t) => ({ nodeType: 3, textContent: String(t) }),
  getElementById: () => null, querySelectorAll: () => [], addEventListener() {},
  body: { appendChild() {}, classList: { add() {} } },
};
globalThis.window = { addEventListener() {}, matchMedia: () => ({ matches: false, addEventListener() {} }) };
globalThis.localStorage = { getItem: () => null, setItem() {}, removeItem() {} };
globalThis.fetch = () => Promise.reject(new Error("test: no network"));
globalThis.Node = class Node {};
globalThis.HTMLElement = class HTMLElement {};

async function loadFeatureModules() {
  const boardModule = await import(join(here, "board.js"));
  const goalsModule = await import(join(here, "goals.js"));

  return { boardModule, goalsModule };
}
test("nothing under ui/ imports itself back through a cycle", function () {
  const found = cyclesIn(graph());
  assert.deepEqual(
    found.map((c) => c.map((f) => relative(uiRoot, f)).join(" -> ")),
    [],
    "a cycle between ES modules resolves in link order, so a read of the other side's top-level state is whichever ran first"
  );
});

test("board and goals each take the other at bind, not by import", function () {
  const board = readFileSync(boardPath, "utf8");
  const goals = readFileSync(goalsPath, "utf8");

  // Anchored to the start of a line, so the seam comments that quote the import
  // they replaced do not read as one.
  assert.doesNotMatch(board, /^import[^\n]*from\s*["']\.\/goals\.js["']/m, "board.js imports the goals module");
  assert.doesNotMatch(goals, /^import[^\n]*from\s*["']\.\/board\.js["']/m, "goals.js imports the board module");

  // The hand-off, so a cycle-free pair cannot silently stop talking.
  assert.match(board, /_goals\s*=\s*deps\.goals/);
  assert.match(goals, /_board\s*=\s*deps\.board/);
});

test("app.js hands each view the other's module when the Kanban view opens", function () {
  const app = readFileSync(appPath, "utf8");
  const kanban = app.slice(app.indexOf("kanban () {"), app.indexOf("  models () {"));

  assert.match(kanban, /loadGoalsModule\(\)/, "the goals module is loaded on the board's first open");
  assert.ok(kanban.includes("goals: gm"), "board is handed the goals module");
  assert.ok(kanban.includes("board: m"), "goals is handed the board module");
});test("the goal->board seam reads the card list the board module exports", async function () {
  // The one shape fact a cycle hid and a text assertion cannot see: the seam is
  // the board module's namespace, and the card list is that namespace's `board`
  // export. Reading `_board.cards` instead yields undefined, so every mirror
  // silently finds no cards -- no error, no post, a board that stops tracking
  // goals. Driving the real modules catches that; grepping for it does not.
  const { boardModule, goalsModule } = await loadFeatureModules();

  const elStub = new Proxy({}, {
    get: () => ({
      appendChild() {}, addEventListener() {}, style: {},
      classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
      value: "", textContent: "", dataset: {},
      querySelector: () => null, querySelectorAll: () => [],
      setAttribute() {}, getAttribute: () => null,
    }),
  });

  goalsModule.bindGoals({
    el: elStub, showView() {}, getSessionId: () => "", switchSession() {},
    board: boardModule,
  });

  // The very list the board module renders from.
  const cards = boardModule.board.cards;
  cards.length = 0;
  cards.push({ id: "card-1", title: "ship it", column: "doing", goal: "goal-9" });
  goalsModule.goalState.val = [{ id: "goal-9", objective: "ship it", status: "active", created: 1700000000 }];

  const mirror = goalsModule.mirrorCardForObjective("ship it");
  assert.ok(mirror, "no mirror card through the seam: the card list is not read from the board module's own export");
  assert.equal(mirror.id, "card-1");

  // The board side asks goals for the id from the card it already holds, so a
  // move never has to wait on the seam.
  assert.equal(goalsModule.goalIdForCard(cards[0]), "goal-9");
  assert.equal(goalsModule.goalIdForCard(null), null);
  // A card predating the durable link falls back to the title match.
  assert.equal(goalsModule.goalIdForCard({ id: "card-0", title: "ship it", column: "ready" }), "goal-9");
});