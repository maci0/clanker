/* The Chat search box is fed by an HTTP call, so it is the one search in the
   page that can answer out of order: the input handler debounces, a second
   query is sent before the first comes back, and the first answer then lands
   on top of the second. Nothing said which query the panel was showing, so
   the reader saw "3 matches" for a phrase they had already replaced.

   These are the shipped Chat search helpers, against the endpoint's answer
   shape (`{ hits: [...] }`). */
import { expect, mock, test } from "bun:test";
import { chatMessageSearch } from "./chat.js";

const msgs = () => [
  { from: "ada", id: "a", text: "the cron spec is a fix" },
  { from: "bo", id: "b", text: "provider refused the request" },
  { from: "ada", id: "c", text: "nothing to see" },
  { from: "cy", id: "d", text: "a second fix, and another" },
];

test("a search answers the newest query when an older one lands last", async () => {
  /* "fix" then "second", the second answered first, the first after. */
  /** @type {PromiseWithResolvers<{ hits: { id: string }[] }>} */
  const answerFix = Promise.withResolvers(),
    /** @type {PromiseWithResolvers<{ hits: { id: string }[] }>} */
    answerSecond = Promise.withResolvers(),
    fetchMock = mock().mockReturnValueOnce(answerFix.promise).mockReturnValueOnce(answerSecond.promise),
    search = Object.assign(chatMessageSearch(), { fetch: fetchMock }),
    searchFix = search.run("fix", msgs()),
    searchSecond = search.run("second", msgs());

  // `fetch` is reached on a microtask, so both requests exist after a tick.
  await Promise.resolve();
  expect(fetchMock).toHaveBeenCalledTimes(2);

  answerSecond.resolve({ hits: [{ id: "d" }] });
  expect(await searchSecond).toEqual({ hits: [{ id: "d" }], query: "second", status: "done" });

  // The superseded answer must be dropped, not shown.
  answerFix.resolve({ hits: [{ id: "a" }] });
  expect(await searchFix).toEqual({ hits: [], query: "fix", status: "stale" });
});

test("a failed first search does not make the next one stale", async () => {
  const search = chatMessageSearch();

  search.fetch = mock()
    .mockRejectedValueOnce(new Error("host is down"))
    .mockResolvedValueOnce({ hits: [{ id: "a" }] });

  expect(await search.run("fix", msgs())).toEqual({ error: "host is down", hits: [], query: "fix", status: "error" });
  expect(await search.run("fix", msgs())).toEqual({ hits: [{ id: "a" }], query: "fix", status: "done" });
});

test("an emptied query clears the panel instead of searching for nothing", async () => {
  const search = chatMessageSearch();

  search.fetch = mock(() => Promise.resolve({ hits: [] }));

  expect(await search.run("   ", msgs())).toEqual({ hits: [], query: "", status: "cleared" });
  // An empty query must not reach the host.
  expect(search.fetch).not.toHaveBeenCalled();
});

test("a short query still answers, and an empty answer is named as such", async () => {
  const search = chatMessageSearch();

  search.fetch = () => Promise.resolve({ hits: [] });

  expect(await search.run("q", msgs())).toEqual({ hits: [], query: "q", status: "done" });
});

test("the in-flight state names the query so an empty panel is answerable", () => {
  expect(chatMessageSearch().pending("  fix  ")).toEqual({ hits: [], query: "fix", status: "searching" });
});

test("the page's search box draws the guarded state, not its own answer", async () => {
  /* The helper is only worth anything if the box goes through it. Pinned
     because the wiring is a hand edit in a 5,700-line module, and a guard a
     later edit routes around is invisible in a diff of the panel's markup. */
  const text = await Bun.file(new URL("../app.js", import.meta.url)).text();

  // App.js must import the guarded search.
  expect(text).toMatch(/chatMessageSearch/u);
  // The box must draw the state the guarded run resolves.
  expect(text).toMatch(/chatSearch\.run\(q\)\.then\(drawChatSearchState\)/u);
  // A superseded answer must never reach the panel.
  expect(text).toMatch(/if \(state\.status === "stale"\) \{ return; \}/u);
  // The panel must say it is working, and for what.
  expect(text).toMatch(/`Searching “\$\{state\.query\}”…`/u);
});
