/* `copyText` is the page's one copy path, and the label it settles on is the
   only thing a reader gets when the clipboard is not theirs to reach. A
   plain-http origin withholds the clipboard API, so that path is not an
   edge: it is every copy button on the page, every time.

   These cases run against the shipped function under a DOM stub installed
   on the global object, so the fallback's own words are pinned rather than
   assumed. */
import { afterEach, expect, test } from "bun:test";
import { copyText } from "./vendor.js";

/**
 * @typedef {{ addEventListener: (type: string, fn: () => void) => void, attrs: Record<string, string>, className?: string, focus: (options?: { preventScroll?: boolean }) => void, focused?: boolean, listeners: Record<string, () => void>, readOnly?: boolean, remove: () => void, removed?: boolean, select: () => void, selected?: boolean, setAttribute: (key: string, value: string) => void, tabIndex?: number, value?: string }} FakeNode
 * @typedef {{ writeText: (text: string) => Promise<void> }} FakeClipboard
 */

const globals = {
  /** @type {(() => void)[]} */
  restores: [],

  /**
   * Puts each value on the global object for one test; `afterEach` puts the
   * previous descriptors back.
   * @param {Record<string, unknown>} values Global names and their stand-ins.
   */
  install(values) {
    for (const [key, value] of Object.entries(values)) {
      const previous = Object.getOwnPropertyDescriptor(globalThis, key);

      Object.defineProperty(globalThis, key, { configurable: true, value, writable: true });
      globals.restores.push(() => {
        if (previous === undefined) {
          Reflect.deleteProperty(globalThis, key);
        } else {
          Object.defineProperty(globalThis, key, previous);
        }
      });
    }
  },

  /**
   * A DOM just wide enough for `copyText`: element creation, one range, one
   * selection, and timers that run only when the test says so.
   * @param {{ clipboard?: FakeClipboard, secure: boolean }} options The origin's clipboard and whether it is secure.
   */
  fakeDom({ clipboard, secure }) {
    /** @type {FakeNode[]} */
    const created = [],
      range = {
        /** @type {unknown} */
        target: undefined,
        /** @param {unknown} node The node to select. */
        selectNodeContents(node) { range.target = node; },
      },
      selection = {
        /** @type {unknown} */
        added: undefined,
        /** @param {unknown} r The range made current. */
        addRange(r) { selection.added = r; },
        removeAllRanges() { selection.removed = true; },
        removed: false,
      },
      /** @type {(() => void)[]} */
      timers = [];

    globals.install({
      document: {
        body: { append: () => undefined },
        createElement: () => {
          created.push({
            /**
             * @param {string} type Event name.
             * @param {() => void} fn Its listener.
             */
            addEventListener(type, fn) { this.listeners[type] = fn; },
            attrs: {},
            focus() { this.focused = true; },
            listeners: {},
            remove() { this.removed = true; },
            select() { this.selected = true; },
            /**
             * @param {string} key Attribute name.
             * @param {string} value Attribute value.
             */
            setAttribute(key, value) { this.attrs[key] = value; },
          });

          return created.at(-1);
        },
        createRange: () => range,
      },
      getSelection: () => selection,
      isSecureContext: secure,
      navigator: { clipboard },
      /** @param {() => void} fn The callback a real timer would run later. */
      setTimeout: (fn) => { timers.push(fn); },
      window: globalThis,
    });

    return { created, range, selection, timers };
  },
};

afterEach(() => {
  for (const restore of globals.restores.splice(0).toReversed()) { restore(); }
});

test("a copy with nothing to select still hands the reader the value", () => {
  const btn = { textContent: "Share" },
    env = globals.fakeDom({ secure: false });

  copyText("https://example.test/#chat?session=s1", btn, "Share", null);

  // The label must offer a way onward, not a dead end.
  expect(btn.textContent).toBe("Selected: press Ctrl+C");
  // A stale selection would replace the new one.
  expect(env.selection.removed).toBe(true);
  /* A range selects nothing inside an input, and Ctrl+C copies an input's
     text only while it has focus: the field itself must be focused and selected. */
  expect(env.created[0]).toMatchObject({ focused: true, selected: true });
  expect(env.range.target).toBeUndefined();
});

test("the parked field holds the value, is labelled, and leaves the page with focus", () => {
  const btn = { textContent: "Copy link" },
    env = globals.fakeDom({ secure: false });

  copyText("https://example.test/#knowledge/k1", btn, "Copy link", null);

  // A value with no visible node needs one to select, holding the value itself.
  expect(env.created).toHaveLength(1);
  expect(env.created[0]).toMatchObject({
    attrs: { "aria-label": "Copy link" },
    className: "sr-only",
    readOnly: true,
    tabIndex: -1,
    value: "https://example.test/#knowledge/k1",
  });

  // The selection must outlive the label, or a slow Ctrl+C copies nothing.
  for (const fn of env.timers) { fn(); }

  expect(env.created[0]).not.toHaveProperty("removed");

  // The field has to be reclaimed, or every copy leaks a node.
  env.created[0].listeners.blur();
  expect(env.created[0]).toHaveProperty("removed", true);
});

test("a caller that already names a target keeps using it", () => {
  const btn = { textContent: "Copy" },
    env = globals.fakeDom({ secure: false }),
    target = { tagName: "PRE" };

  copyText("body text", btn, "Copy", target);

  // The caller's own node is the one selected, and no second field is parked.
  expect(env.range.target).toBe(target);
  expect(env.created).toEqual([]);
});

test("a secure origin with a working clipboard still says Copied", async () => {
  /** @type {string[]} */
  const btn = { textContent: "Share" },
    written = [];

  globals.fakeDom({
    clipboard: {
      /** @param {string} t The text written. */
      writeText: (t) => {
        written.push(t);

        return Promise.resolve();
      },
    },
    secure: true,
  });

  copyText("https://example.test/#chat", btn, "Share", null);
  await Promise.resolve();
  await Promise.resolve();

  expect(written).toEqual(["https://example.test/#chat"]);
  // The success label is the one the reader needs here.
  expect(btn.textContent).toBe("Copied");
});
