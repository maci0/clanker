# Web UI plugins — review log

The plugin surface under `tools/webui-plugins/`: the views that are part of the
page without being part of `tools/zig/webui/`. `docs/WEBUI_REVIEW.md` covers the
page itself; this file covers the plugins and the host that loads them, because
they are edited independently and a shared log makes every plugin change collide
with every page change.

New entries go at the end of this file.

## Constraints these entries honor

The plugin rules in `tools/webui-plugins/README.md`, unchanged:

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
