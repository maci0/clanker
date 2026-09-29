/*
 * The Music dock's first-visit state. With nothing stored it starts as its
 * small note button: an empty expanded player took a sixth of a phone screen.
 */
import { expect, test } from "bun:test";

type Node = {
  addEventListener: () => void;
  appendChild: (child: Node) => Node;
  attributes: Map<string, string>;
  children: Array<Node>;
  className: string;
  dataset: Record<string, string>;
  id: string;
  isConnected: boolean;
  setAttribute: (name: string, value: string) => void;
  style: Record<string, string>;
  textContent: string;
};

type Api = { icon: () => Node; showView: () => void; storage: { get: () => null; set: () => void } };

class FakeAudio {
  public currentTime = 0;

  public paused = true;

  public preload = "";

  public addEventListener(): this {
    return this;
  }
}

const blank = (): Node => ({
    addEventListener: () => undefined,
    appendChild(child) {
      this.children.push(child);
      child.isConnected = true;

      return child;
    },
    attributes: new Map(),
    children: [],
    className: "",
    dataset: {},
    id: "",
    isConnected: false,
    setAttribute(name, value) {
      this.attributes.set(name, value);
    },
    style: {},
    textContent: "",
  }),
  /* Boots app.js against stub globals and empty storage; returns the body it drew into. */
  boot = async (): Promise<Node> => {
    const body = blank(),
      stubs = {
        Audio: FakeAudio,
        clanker: {
          registerView: (spec: { boot: (api: Api) => void }) => {
            spec.boot({ icon: blank, showView: () => undefined, storage: { get: () => null, set: () => undefined } });
          },
        },
        document: { body, createElement: blank, documentElement: blank(), querySelector: () => null, querySelectorAll: () => [] },
      };

    Object.assign(globalThis, stubs, { window: globalThis });
    /* A classic script, not a module: loaded for its side effect on the stubbed globals. */
    await import(new URL("app.js", import.meta.url).href);

    return body;
  };

test("with nothing stored, the dock starts collapsed", async () => {
  const body = await boot(),
    dock = body.children.at(0);

  expect(dock?.id).toBe("music-dock");
  expect(dock?.attributes.get("data-collapsed")).toBe("true");
});
