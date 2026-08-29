# Web UI plugins — review log

The plugin surface under `ui/plugins/`: the views that are part of the
page without being part of `ui/app/`. `docs/reviews/webui.md` covers the
page itself; this file covers the plugins and the host that loads them, because
they are edited independently and a shared log makes every plugin change collide
with every page change.

New entries go at the end of this file.

## Constraints these entries honor

The plugin rules in `ui/plugins/README.md`, unchanged:

- No build step, no dependencies, no `eval`/`new Function` — the CSP is
  `script-src 'self'` and the file that ships is the file that runs.
- DOM via `createElement`/`textContent`. Never `innerHTML` from data.
- Every control carries a visible label or an `aria-label`.

## How a plugin is verified

`clanker serve` could not be reached from this environment while these were
written, so there is no browser in the loop. The plugins are plain scripts that
call a global `clanker.registerView`, which makes them straightforward to run
under `node`: a DOM stub, a `vm` context, and a test-controlled clock for
`performance.now`, `Date.now`, `requestAnimationFrame`, `setInterval` and
`setTimeout`. Deferred `api.getJSON` routes let a test hold one response open
and land it out of order, which is the only way to test the races below.

Two things the stub has to get right or failures hide: `dispatch("click")` must
be a no-op on a disabled control, the way a browser is, and a view's own
`.catch` will swallow a stub gap and report it as an ordinary endpoint error.
Every run below was also run against unmodified `main` as a control — a test
that does not fail before the fix is not evidence.

## The Files view could not go up (2026-08-13)

`GET /api/files` answers with both `parent` and `at_root`, and the plugin used
only `parent`. Those are not the same question. `handleFiles` derives `parent`
from the last `/` in the path, so the parent of `src` is the empty string —
exactly what the workspace root reports for itself. The view decided root-ness
with `cur.parent !== ""`, so one level down it concluded it was at the top:
`Up` was disabled, and its own click handler had the same test and so did
nothing. The only way back out of a top-level directory was the breadcrumb.
Two levels down everything worked, which is why this survived — `src/agent`
reports `parent: "src"` and behaves. Root-ness now comes from `at_root`, with
`cur.path === ""` as the fallback for a server that does not send it.

Three smaller disagreements between what the view showed and where it was, all
in the same load path:

`Up` began life enabled, before any response had arrived and with nothing above
it to go to. It is now disabled until the first listing lands, along with
`Refresh`.

`load()` opened by *enabling* `Up` — `if (cur.parent) show(up, true)` — so the
button was live during a navigation, reading the previous directory's parent.
Clicking it mid-flight sent a second, competing request; this server answers one
request per connection, so the two could land in either order and the view ended
up somewhere neither click asked for. Both controls are now disabled for the
duration of a load, and a request carries a generation stamp: a response from a
superseded navigation is dropped rather than painted.

A failed listing left the previous directory's rows and breadcrumbs on screen,
while `cur.path` had already moved to the directory that failed. The view was
then claiming a location it was not showing, and `Refresh` would silently jump
somewhere else. A failure now names the directory you asked for in the trail and
says why it is not there in the list; `Up` stays usable, working from the path
rather than from a `parent` the server never got to send.

The `focusRoot` path — clicking the workspace-root crumb — focused
`crumbs.firstChild` before the load resolved, so it focused the button
`drawCrumbs` was about to destroy and focus fell to the body. It now runs after
the load, on the trail that exists.

### Verified

`node` + the DOM stub driving the real `files/app.js`, 26 assertions: `Up` is
enabled one level deep and returns to the root; `Up` from `src/agent` lands on
`src` and not the root; `Up` is disabled before the first load, during a load,
and at the root; a mid-flight `Up` click issues no request; the root crumb
leaves focus on an element still attached to the view; a failed listing names
the failed directory and leaves none of the previous one behind; and a response
from a superseded navigation does not paint over the newer one. Against
unmodified `main` the same harness fails 11 of the 26. Gate: `zig build`,
`zig build tools`, `zig build test --summary all`.

## The Office janitor never stopped talking (2026-08-13)

The janitor is written to say very little — the header calls him "the comedic
relief, not a status lamp", and `janitor.zig` records why the lines are dry.
On screen he never shut up. One deadline was doing two jobs: `quipUntil` was
only ever read as *when may he say the next thing*, so the rounds branch was

    if (now > janitor.quipUntil) { janitor.quip = <line>; janitor.quipUntil = now + 9000 }

and nothing ever assigned `janitor.quip = null`. `drawJanitor` draws a bubble
whenever `janitor.quip` is truthy, so from the first line onward there was a
speech bubble over him on every frame for as long as the view stayed open, the
text swapping every nine seconds. The character with one joke for every
occasion is the one the header says he is not.

A line now has a lifetime as well as a successor: `quipUntil` is when it comes
down, `nextQuipAt` is the earliest he may start another, and one helper sets
all of it so no quip can be assigned without a deadline to remove it. The check
that takes a line down sits above the pile branch, so a line outlives neither a
rush to fresh garbage nor a scrub — it used to outlive both, and everything
after them. `nextQuipAt` starts unset and the first line waits out a gap, so
opening the Office is quiet instead of opening mid-sentence. The clean-up line
after he sweeps a pile goes through the same helper, so it expires too; it
previously set `quipUntil = now + 6000`, which under the old reading only
delayed his *next* line and left that one up forever as well.

The measured effect: over 400 frames he now has a bubble up on 114 of them, the
4.5 s line against the 9 s gap. On `main` it is 400 of 400.

Second bug in the same file, unrelated but found by the same harness.
`load()` sets `offices`, then fetches `/api/goals`, and it was that
continuation which first assigned `o.piles` and `o.index`. The three-second
message poll gates only on `offices.length`, so a poll landing in the window
between the two reached `applyMessage` with `o.piles` still undefined. The
guard there reads `(o.piles || []).length < 3` and the next line is
`o.piles.push(...)`, so the guard passed and the push threw — into `poll()`'s
per-room `.catch(function () {})`, which swallowed it. The visible result was
not an error: the card action was logged, no pile appeared, and every later
message in the same batch was dropped while `o.cursor` had already advanced
past it, so those messages were never retried. Both fields now exist from the
moment an office object does; the `/api/goals` continuation only settles
`index`, which is a position rather than an existence.

### Verified

`node` + the DOM stub driving the real `office/app.js`, with the sprite sheets
deliberately never loading so the fallback drawing path runs and every speech
bubble arrives as a recorded `fillText` call. 15 assertions: the view opens with
no bubble, a line appears, it comes down again, it stays down for a real gap,
another and different line follows, and over 400 frames he is silent for most
of them; and, with `/api/goals` held pending while the poll fires, a `@todo`
action both records its pile and does not eat the next message in the batch,
while an action whose id does not land on the 1-in-3 leaves the floor clean.
Against unmodified `main` the same harness fails 6 of the 15. Gate: `zig build`,
`zig build tools`, `zig build test --summary all` — 163/163 steps, 2 skipped
tests, the expected worktree pair.

## The Activity timeline would not open the card it named (2026-08-13)

Every row in the Activity timeline ends in a button carrying the card's title,
with `title="Open this card on the board"`. It called
`api.showView("board")` — and nothing else. It switched view and left you to
find the card among all the others yourself, which on a board several clankers
have been working is the whole reason you were reading the timeline. The button
kept its promise as far as the word "board" and no further.

The card's id was available and thrown away: `load()` folded each entry as
`{ ts, who, what, card: c.title }`, keeping the title for display and dropping
`c.id`. The board already has a deep link for this — `#board/<id>`, which
`app.js`'s hash router resolves by waiting for the board to load and then
opening that card, the same path `#arena/<id>` and `#compare/<id>` take. So the
entry now carries its id and the button navigates to that link; nothing about
opening a card is reimplemented here, and no host-side change was needed. An
unchanged hash fires no `hashchange`, so that one case asks the host directly
instead.

A card with no title left the button with no accessible name at all — empty
text, and an `aria-label` was never set. The plugin rules require every control
to carry a visible label or an `aria-label`, so the button now always has one,
falling back to naming the card by id.

And a failed `/api/board` left the previous timeline on screen. `draw()` was
only reached on success, so the rows kept describing work while the status line
said the read had failed — the view contradicting itself, with no way to tell
which half was current. A failure now replaces the list with what went wrong.

### Verified

`node` + the DOM stub driving the real `activity/app.js`, 16 assertions: one row
per log entry across all cards, newest first, with the count announced; each
button navigates to its *own* card's deep link rather than the first one's; no
button is left without an accessible name and the untitled card's carries an
`aria-label`; a failed refresh clears the stale rows, says why, leaves Refresh
usable, and a later refresh recovers; and an empty board explains itself.
Against unmodified `main` the same harness fails 6 of the 16. Gate: `zig build`,
`zig build tools`, `zig build test --summary all`.

## Health — the server's own numbers, which nothing was reading (2026-08-13)

`GET /api/metrics` has been served since it was added and **no code in the
browser ever called it**. A grep for each `/api/*` route across
`ui/app/` finds a consumer for every one of them except this. So
everything `handleHttpMetrics` reports was invisible from the page: how much
traffic the server is taking, how much of it is failing, how close it is to its
connection limit, and how long it takes to answer.

The saturation figure is the one that earns a view. This server hands each
connection to a thread and answers one request per connection, so `in_flight`
against `connection_limit` is the difference between "busy" and "your next
request waits" — and it is the mechanism behind the dropped polls that the arena
and rooms views have each had to be made resilient to. `/health/ready` already
reports that condition, but it reports it as a 503, which is the right shape for
a load balancer and the wrong one for a page: it says whether the server
arrived, not how close it got. This view says how close.

A new plugin rather than a page module, because it is exactly the kind of thing
the plugin surface exists for: useful, self-contained, and off by default.

### What it shows

Four stat tiles and one distribution. The tiles are `Requests`, `Errors`,
`In flight` and `Mean response`; the distribution is the latency histogram.

**A total is not a rate.** Every counter the endpoint exposes is a monotonic
total, and the number you want from most of them is per-second. Two samples are
differenced, and until the second one arrives the rate reads `—` and says
"waiting for a second sample" rather than showing a total in a per-second slot.
A gap of unknown length is not a sample window either, so a failed read drops
the stored sample instead of differencing across the outage; the first read
after a recovery also reads `—`.

**A counter that goes backwards means a restart**, not negative traffic. That
case reports no rate and names itself: "counters reset, now N since start". It
is worth distinguishing from a just-opened view, because both show no rate but
only one of them is news.

**The bands are cut from cumulative buckets.** `latency_buckets` is
`le_10 ≤ le_100 ≤ le_1000 ≤ le_10000`, so each band is a subtraction and the
slowest band is `requests_total - le_10000`. Every subtraction is clamped at
zero: the server loads each counter with its own atomic read, so a sample taken
mid-request can legitimately have a bucket ahead of `requests_total`, and an
unclamped band would render a negative bar width.

**`in_flight` counts the connection asking.** It never reads zero from a
browser, because the poll itself is one of the connections. The tile says "this
poll included" rather than quietly subtracting one.

### Drawing

Nothing is on a canvas. The distribution is a real `<table>` with the bars
inside a cell, so the numbers *are* the chart rather than a caption for it, and
a screen reader or a stylesheet-less page reads exactly what the bars show. The
bars are `aria-hidden` because the count and the share are already in their own
cells beside them — the same choice the run checklist and the office log make.

Colour is never the only encoding. Saturation is a word (`ready`, `busy`,
`saturated`) with the colour following it, not carrying it. The bands are one
hue getting stronger as the band gets slower, which is a sequence rather than
five identities — slow bands read hardest, which is the one you want to notice.
State rides on a tile's left edge rather than on its number, so the value keeps
the page's ink and stays legible. Under `forced-colors` the fills are replaced
with outlines. Every colour is a page token, so light, dark and the Catppuccin
themes all work without this file knowing they exist; a literal hex would be the
one thing on the page that does not follow the theme.

The poll is 2s and gated on the panel's `hidden` attribute, because the host
never unmounts a view — and a poll on a view nobody is looking at costs a
connection that another view's poll wanted. Coming back re-reads immediately
rather than showing numbers as old as the moment it was hidden.

### Verified

Two ways.

`node` + the DOM stub driving the real `health/app.js`, 60 assertions: a first
sample has totals but no rate; 40 requests over 2s reads as `20/s` and half a
request a second is not `0/s`; a counter going backwards reports no rate, names
the reset, and the pair after it measures from the new baseline; the four
saturation cases each show the numbers, the word, the state attribute and a
header chip that agrees; cumulative buckets become `700,200,60,30,10` with
shares and bar widths scaled against the largest band; an inconsistent sample
clamps to `90,0,25,0,0` with no negative widths; an empty server reads as empty
rather than dividing by zero; a hidden view stops polling and resumes when
shown; a failed read clears the tiles, says why, and does not fake a rate across
the gap; and a poll is not issued while one is in flight.

Live, against a real `clanker serve` on this machine: the plugin is discovered
by `/api/webui/plugins` with its title, description, group and `has_css`; its
`app.js` and `app.css` 404 while disabled and serve `200` with the right content
types once enabled; and the real view, fed two real samples taken 1230 ms apart
with real traffic in between, rendered `44/s` against an independently computed
`43.9/s` — 54 requests over 1230 ms — with `1/64 connections, ready`,
`10 of 88 (11%)` errors, a `0.2ms` mean and all 88 requests in the `up to 10ms`
band. Gate: `zig build`, `zig build tools`, `zig build test --summary all` —
163/163 steps, 776/778 tests, 2 skipped, the expected worktree pair.

## The Health error tile needed evidence, not just a share (2026-08-13)

Follow-up to the entry above, prompted by #199. That fix stopped
`handleConnectionGuarded`'s final keep-alive pass being counted as a request:
`errors_total` for ordinary browsing went from 8 to 0 and `requests_total` from
14 to 7 on the same workload. The counters this view reads are now real.

Which made a threshold visible that had never had a chance to behave. The error
tile escalated to its worst state on `share >= 1%`, and under the old phantom
counts the share was permanently around 11%, so the tile was always red and the
rule was never actually exercised. With real numbers, one 404 out of 89 requests
reads as 1.1% — and painted the panel red.

These are totals since start, so early on the denominator is tiny: a single
request for a path that does not exist reads as 1%, or 12%, or 50%, depending
only on how long the server has been up. That is a client asking for something
absent, not a server in trouble, and colouring it the same as a server failing
half its requests is how a panel earns being ignored. The worst state now needs
the share to clear its bar **and** at least five errors, so a share computed
over almost nothing cannot reach it; below that it is a warning, with the counts
beside it doing the talking. The counts are on screen in every state, which is
what the colour was never allowed to be the only carrier of anyway.

Verified against the live server that prompted it: `1 of 89 (1.1%)` now reads as
a warning rather than a fault, while the bucket arithmetic is unchanged and
still exact — 15 requests, bands summing to 15, `le_10000 <= requests_total`,
no negative band.

### Verified

The same harness, 74 assertions now (60 plus 14 for this): a clean server is
good; 1 of 89, 4 of 8 and 1 of 1 are warnings; 5 of 500, 10 of 88 and 50 of 100
are faults; and the counts are shown regardless of state. Against `main` the
three warning cases fail, all reading `bad`. Gate: `zig build`,
`zig build tools`, `zig build test --summary all`.

## Three plugins, three controls that were not doing their job (2026-08-24)

**Mesh's visibility guard read an attribute nobody sets.** `mount` is handed the
inner `<section>`; the host toggles `hidden` on the enclosing `.view` panel
(`panel.hidden = !on` in `showView`). So `container.hidden` in
`ui/plugins/mesh/app.js` was `false` for the life of the tab, and all three
guards that read it — the 4s `/api/mesh/status` + `/api/mesh/pending` poll, the
1s pending-countdown redraw, and the live-bus handler — were guards over
nothing. Opening Mesh once left it polling forever from a view nobody could see,
which is the standing background poll this surface is not allowed to be, and
each of those requests is a connection another view's poll wanted. The comment
above the timers claimed this had been fixed; it had not. It asks the panel now,
via `container.closest(".view")`, the way `health` and `office` already do and
say why.

**Music's Remove button drew nothing.** `btn("×", …)` on each playlist row.
`setGlyph` prefers `api.icon`, the loader always supplies it, and
`icon()` returns an *empty* `<span>` for a name that is not in `ICON_PATHS` —
and `×` is a character, not a name. The dock's own controls were migrated to the
host's icon grid; this row was missed, so every Remove was a blank
`.music-btn` box. The `aria-label` was there, so a screen reader was fine and a
sighted user had an unmarked square. It asks for `close` now. Worth noting the
trap: a test harness that omits `api.icon` takes `setGlyph`'s
`else b.textContent = name` branch and renders a perfectly convincing `×`, so a
stub would have hidden this rather than caught it.

**Office's mount threw where storage is blocked.** Line one of `mount` read the
pre-migration alarm key with a bare `localStorage.getItem`. `api.storage`
swallows a blocked store; a bare read does not, and it is the property access
itself that raises `SecurityError` when a browser is set to block site data. So
an optional preference read replaced the entire view with the plugin error panel
in a browser where nothing about the office needs storage. Music does the same
migration read inside a `try`, which is the shape; the office read is in one
now.

### Verified

`ui/plugins/mesh/mesh.test.mjs` gains a case that reads both halves of the
contract, so they cannot drift apart again: that the loader hands `mount` the
`section` and hides the `panel`, that `container.hidden` appears nowhere in the
plugin, and that all three consumers go through `viewHidden()`. It fails against
`origin/main`.

`ui/plugins/music/music.test.mjs` gains a cross-file case rather than a
one-glyph assertion: it parses the key set out of `ui/app/core/icons.js` and
checks every name music hands `btn`/`setGlyph`, ternaries included, against it.
Against `origin/main` it reports exactly `[ '×' ]`. This catches the next one
too.

`ui/plugins/office/office.test.mjs` is new — office had no suite at all — and is
registered in `build.zig` for the `js-suite-coverage` gate. It pins that the one
remaining store read is inside `legacyAlarm`'s `try`, plus the rules the view has
to keep anyway: no `innerHTML`, no `eval`, timers gated on
`container.closest(".view")`, and no colour literal in `app.css`. The storage
case fails against `origin/main`; the other three pass there, which is what they
are for.

## The plugin host assumed a view is opened once and the rail never changes

Three reported bugs, one assumption. `ui/app/core/plugins.js` builds a plugin's
chrome correctly and then registers it in a way that only worked while the rail
was static, and it hands every plugin the same live region.

### `refresh` was documented but unreachable

`viewLoaded[name]` in `app.js` is set on the first successful load and never
cleared, so a view loader is never called twice and `spec.refresh` was reachable
only from the error panel's Retry. PRD 0012 lists `refresh` in the registration
API; `mesh` says in a comment that "refresh() covers re-entry"; it did not.
`health` and `office` had each grown a `MutationObserver` on their panel's
`hidden` attribute to work around it, both with a comment naming the host as the
reason.

`showView` now calls the host's `pluginViewShown(name)` on every switch to a
view it had already loaded. The host keeps per-view mount state in one place
(`trackMount`), shared by the eager and the deferred loader, and the hook is
read at call time rather than captured because `health` and `office` both assign
`this.refresh` from inside `mount`. It is deliberately a no-op until `mount` has
run: `wasLoaded` is read in `showView` before the load branch can flip the flag,
so a loader that mounts synchronously cannot get `refresh` in the same switch.
Both observers are gone, since with a working hook they only bought a second
`/api/metrics` read and a second poll per re-entry.

Consolidating both loaders onto one guarded mount/refresh pair dropped the
`runPluginHook(section,` call sites from four to two, and an assertion in
`ui/app/webui-load.test.mjs` pinned that by number. It now names the two hooks
behind the shared guard instead of counting, which is what it was there to say.

### One live region for every plugin, rewritten about once a second

`api.status` wrote `#webui-plugins-status`, and so did the loader's own five
enable/disable/failure lines. `health` calls it from `applySample`, which runs on
every live `metrics` event, throttled to 1 Hz server-side. That id is also one of
the sixteen the page's status-to-toast mirror watches, so the cost was not only a
polite announcement every second but a fresh toast every second, and an enable
confirmation asked for at the same moment was overwritten inside it.

Each plugin view now gets its own `sr-only` `role="status"` node,
`#plugin-status-<id>`, built with its chrome and handed to the mirror through a
new `observeStatus` context entry: the mirror had a hard-coded id list, and a
plugin's region does not exist when that list is read. The shared line is the
loader's alone, behind one guarded `hostStatus` helper, which is also where a
spec with no view chrome behind it still lands. Writing the same line twice
running is one announcement.

The frequency was Health's own defect and is fixed there too: `applySample`
takes an `announce` flag, false for a sample that arrived on the live bus, true
for a read somebody asked for. The tiles are the live surface.

### Arrow keys followed registration order, not the rail

`makeViewShell` puts a plugin's tab inside its group heading, which is the right
place, then does `_VIEWS.push(id)` and wires the tab with that index. `wireTab`
moved focus purely by index, so for the eleven built-ins — where `VIEWS` happens
to be exactly the shipped rail order — the index had always been a stand-in for
DOM position. A plugin is the first thing to separate them: ArrowUp from a
Work-group plugin landed on System.

`wireTab` reads `railOrder()` instead, per press rather than captured, since a
plugin's tab can join the rail long after a built-in was wired. The index it was
wired with survives as the fallback for a tab that is not in the rail.

`aria-owns` on `.rail-places` had the same fault and is the half that is easy to
miss: the Set up group's tabs sit outside the tablist element and are members of
it only through that attribute, so the order it is written in is the order a
screen reader reads. Appending each new id put a Work-group plugin after System.
`syncTablistOwns` rebuilds it from the rail's order.

### Verified

`ui/app/core/plugins.test.mjs` is new — the host had no suite of its own — and
is registered in `build.zig` for `js-suite-coverage`. The host is an ES module
that imports six siblings and expects a browser, so it runs in a `vm` with the
imports stripped and stubbed, over a DOM stub built to the shape of the shipped
rail rather than a flat list of tabs: a `.rail-places` tablist holding Work (an
`<h2>` in a `<section>`) and Watch (a `<summary>` in a `<details>`), plus a
separate `.rail-settings` nav whose tabs are members only through `aria-owns`.
That structure is the point — a flat stub would have let the rail-order fix pass
without proving anything.

Fourteen cases, run as a control against an untouched `origin/main` worktree:
twelve fail there and two pass. The two that pass on both sides are the controls
— a key the tablist does not own is left alone, and a status call with no panel
behind it still lands somewhere. The before-state failures name the reported
symptoms rather than an incidental break: ArrowUp reports `'system' !== 'kanban'`,
which is exactly what the report claimed.

Live: `clanker serve` returns the new host and app bytes, and enabling `health`
over `/api/webui/plugins` serves a `health/app.js` with the `announce` gate and
no `MutationObserver`. Full `clanker gate`: twelve of twelve PASS.

## 2026-08-29 — Retry after a failed plugin script load was a no-op

Found by reading `loadPluginScript` (`ui/app/core/plugins.js`) against the
error panel's retry path. A deferred plugin's Retry resets the promise cache
(`pluginScripts[name] = null`) and calls the loader again — but a script whose
fetch failed left its dead `<script>` element in the head, and the loader's
existing-tag check (`script[data-plugin="<name>"]`) found it and resolved
`true` without touching the network. `shell.spec` was still null, so the panel
showed the same failure again: for a script that 404ed once (server briefly
down, plugin enabled before its `app.js` was written), Retry could never
succeed short of a full page reload. `onerror` now removes the tag before
resolving, so the retry path genuinely refetches.

Pinned in `ui/app/core/plugins.test.mjs`: the failed tag is gone from the head,
Retry injects a fresh element rather than adopting the dead one, and the
retried load mounts the plugin once its script registers. Run as a control
against unfixed `plugins.js`: the new case fails there (`Retry must inject a
fresh script tag`), the other fourteen pass. The test's DOM stub now hangs
`head` off the same root `document.querySelector` walks, since the
existing-tag check is exactly what the stub had been hiding.
