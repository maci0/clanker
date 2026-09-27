import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

// The component kit's own logic: the class merge, the variant table, and the
// promise that every class the table names exists in a sheet the page ships.
// That last one is not hypothetical — a variant is a string in a table here,
// not a class in an element, so nothing else in the suite would notice a typo
// until a view rendered with no styling at all.
const here = dirname(fileURLToPath(import.meta.url));

// kit.js imports core/ui.js, which imports the vendored signals module by URL;
// the two pure helpers are lifted out and run against a stub `document`, the
// shape ui/app/lib/dom-stub.mjs uses for the same reason.
async function loadKit() {
  const src = readFileSync(join(here, "kit.js"), "utf8")
    .replace(/import \{ T \} from "\.\/ui\.js";/, "const T = globalThis.__T;");
  globalThis.__T = { button: function (attrs) { return { attrs: attrs }; } };
  const url = "data:text/javascript;base64," + Buffer.from(src).toString("base64");
  return import(url);
}

test("cn drops the empty class lists and keeps the order", async function () {
  const kit = await loadKit();
  assert.equal(kit.cn("a", "", null, undefined, "b"), "a b");
  assert.equal(kit.cn(), "");
});

test("variants fills a missing prop from defaults and appends the caller's class", async function () {
  const kit = await loadKit();
  const cls = kit.variants({
    base: "base",
    defaults: { variant: "secondary" },
    variants: { variant: { primary: "primary", secondary: "secondary" } },
  });
  assert.equal(cls({}), "base secondary");
  assert.equal(cls({ variant: "primary" }), "base primary");
  assert.equal(cls({ variant: "primary", class: "extra" }), "base primary extra");
  // An unknown variant name contributes nothing rather than throwing.
  assert.equal(cls({ variant: "no-such" }), "base");
});

test("the button table's every class exists in a shipped sheet", async function () {
  const kit = await loadKit();
  const sheets = ["app.css", "views.css", "tailwind.css"]
    .map((f) => readFileSync(join(here, "..", f), "utf8")).join("\n");
  const plain = sheets.replace(/\\(.)/g, "$1");
  for (const variant of ["primary", "secondary", "danger", "secondary-danger"]) {
    const classes = kit.buttonVariants({ variant });
    assert.ok(classes, `buttonVariants({variant:"${variant}"}) names a class`);
    for (const token of classes.split(/\s+/)) {
      assert.ok(plain.includes("." + token), `${variant} names .${token}, which no sheet defines`);
    }
  }
});

test("button defaults to type=button and forwards the rest as props", async function () {
  const kit = await loadKit();
  const made = kit.button({ variant: "primary", id: "go", disabled: true }, "Run");
  assert.equal(made.attrs.type, "button");
  assert.equal(made.attrs.id, "go");
  assert.equal(made.attrs.disabled, true);
  assert.equal(made.attrs.class, "primary");
  assert.doesNotMatch(made.attrs.class, /variant/);
});
