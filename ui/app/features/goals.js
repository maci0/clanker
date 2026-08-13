// Goal workflow — ES module, no bundler.
// Goals are the board's durable cards. This module owns goal creation,
// per-goal streamed runs, and the goal<->board reconciliation. The board
// side of that glue lives in ./board.js; the pure helpers (sorting, field
// listing, the status->column mapping) stay in ../core/goals.js. bindGoals()
// wires the DOM and the app-level callbacks (view switching, the active
// session id).
//
// The goal->card link is durable: a mirror card carries its goal's id in its
// own `goal` field (folded into the board like any other edit), so the link
// survives reloads, other browsers and server restarts. This module only
// derives from it — cardOfGoal below is the one place the link is read, and
// the title fallback there is what adopts cards created before the field
// existed.
import { readJson } from "../core/utils.js";
import { T, bind, UI, state, uiConfirm, uiPrompt } from "../core/ui.js";
import { goalSortKey, goalFields, goalStatusLabel, goalPinnedColumn, goalWorktreeTitle } from "../core/goals.js";
import { icon } from "../core/icons.js";
import { makeLineSplitter } from "../core/stream.js";
import { board, postBoard, loadBoard, boardIsLoaded } from "./board.js";

var el = null;
var _showView = null;
var _getSessionId = null;
var _switchSession = null;

// ---- goals: what runs are being steered toward -------------------------

export var goalState = state([]);

/* Goal ids the server reports as having a run in flight right now — any tab,
   any client, not just this browser — mapped to that run's session id (""
   when it has none to point at). Refreshed by every loadGoals; merged with
   this browser's own goalRuns when deciding what "running" means. */
var runningIds = {};

/* Goals whose mirror card creation has been requested this session, so a
   slow POST does not create a second card while the first is still in
   flight. The durable link is the card's `goal` field; this only debounces
   creation. */
var goalMirrorRequested = {};

/* Newest first: the goal most recently set is the one steering runs now. */
export function renderGoals(goals) {
  goalState.val = (goals || []).slice().sort(goalSortKey);
}

/* Whether anything is working this goal right now: a run streaming into this
   page, or one the server registry attributes to another client. */
export function isGoalRunning(gid) {
  if (Object.prototype.hasOwnProperty.call(runningIds, gid)) return true;
  var run = goalRuns[gid];
  return !!(run && run.status === "running");
}

/* The board card mirroring a goal, or null. The card's own `goal` field is
   the link; the title fallback adopts cards from before the field existed
   (and only unlinked ones, so a same-titled card of another goal is safe). */
function cardOfGoal(g) {
  var cardsArr = board.cards || [];
  for (var i = 0; i < cardsArr.length; i++) {
    if (cardsArr[i].goal === g.id) return cardsArr[i];
  }
  for (var j = 0; j < cardsArr.length; j++) {
    if (!cardsArr[j].goal && cardsArr[j].title === g.objective) return cardsArr[j];
  }
  return null;
}

function findGoal(goals, gid) {
  for (var i = 0; i < (goals || []).length; i++) {
    if (goals[i].id === gid) return goals[i];
  }
  return null;
}

/* Mirrors goals onto the board so live work is visible there. Idempotent by
   construction: a goal whose card exists is only reconciled (link persisted
   if missing, column corrected when the status pins one), and a goal without
   a card gets exactly one, in the column its status asks for. Done and
   legacy abandoned goals get no posthumous card; archived goals do, because
   archive is retained history rather than deletion. Waits for the board to have loaded
   first: mirroring against an unfetched (empty) card list is what used to
   create a duplicate card on every visit. */
function mirrorGoalsToBoard(goals) {
  var work = function () {
    (goals || []).forEach(function (g) {
      if (!g || !g.id || !g.objective) return;
      var status = g.status || "active";
      var card = cardOfGoal(g);
      if (card) {
        // Adopt a pre-goal-field card: persist the link on the card itself
        // so it survives reloads and reaches other browsers.
        if (!card.goal) postBoard({ op: "update", id: card.id, goal: g.id, goal_sync: false }, null);
        var pinned = goalPinnedColumn(g, isGoalRunning(g.id));
        if (pinned && card.column !== pinned) {
          postBoard({ op: "move", id: card.id, column: pinned, goal_sync: false }, null);
        }
        return;
      }
      if (status === "abandoned") return;
      if (goalMirrorRequested[g.id]) return;
      goalMirrorRequested[g.id] = true;
      // A board card title is capped at 512 characters but a goal objective
      // is not, so an over-long objective used to make the mirror fail with
      // "title must be 1-512 characters" and pin this goal as "requested"
      // forever. Truncate the *display* title for the card; the full
      // objective stays on the goal and is one click away on the Goals view.
      // The durable card<->goal link is the card's `goal` field, so a shorter
      // title does not orphan it.
      var title = g.objective;
      if (title.length > 512) title = title.slice(0, 512);
      postBoard({
        op: "create",
        title: title,
        body: g.completion_criterion || "",
        column: goalPinnedColumn(g, isGoalRunning(g.id)) || "backlog",
        goal: g.id
      }, null).then(function (ok) {
        // Only a confirmed create keeps the debounce flag. On failure the flag
        // is dropped so the next loadGoals retries; otherwise a transient
        // error (or a too-long objective that was later shortened) would keep
        // the goal off the board forever.
        if (!ok) delete goalMirrorRequested[g.id];
      });
    });
  };
  if (boardIsLoaded()) {
    work();
    return Promise.resolve();
  }
  return loadBoard().then(work);
}

function goalCard(g) {
  var fields = goalFields(g);
  var running = isGoalRunning(g.id);

  var actions = [];
  if (g.id) {
    /* Active goals are meant to be worked: without this, adding a goal only
       wrote state/goals.json and never started a run. The per-run budget box
       sets this run's max iterations; left blank it falls back to the goal's
       stored default, then to the global agent.max_iterations. */
    if ((g.status || "active") === "active" && !running) {
      actions.push(T.div({ class: "goal-run-controls" },
        T.input({
          type: "number", min: "1", max: "1000", step: "1",
          "data-goal-budget": g.id,
          placeholder: g.max_iterations ? ("≤ " + g.max_iterations + " iters (default)") : "max iters (default)",
          title: "Optional per-run max iterations. Blank uses the goal's stored default, then the global agent.max_iterations."
        }),
        UI.button("Work on this", function () { workOnGoal(g); },
          { label: "Work on goal: " + (g.objective || g.id) })));
    }
    if ((g.status || "active") !== "done") {
      var mirror = cardOfGoal(g);
      var pendingChecklist = mirror && (mirror.subtasks || []).some(function (s) { return !s.done; });
      var doneAction = UI.button("Mark done", function () {
        // The board tool owns the checklist invariant. Move the mirror first
        // so an incomplete tree is refused before goal state can say "done";
        // postBoard then synchronizes the accepted move back to this goal.
        var card = cardOfGoal(g);
        if (card) postBoard({ op: "move", id: card.id, column: "done" }, "Goal marked done.");
        else postGoal({ id: g.id, status: "done" }, "Goal marked done.");
      });
      if (pendingChecklist) {
        doneAction.disabled = true;
        doneAction.title = "Finish every checklist item before marking this goal done.";
      }
      actions.push(doneAction);
    }
    /* Iterate: ask what to refine, then reactivate the goal (if it is not
       already active) and start a run steered by that instruction. Works for
       finished, reviewing, archived or idle-active goals alike. */
    if (g.id && !running) {
      actions.push(UI.button("Iterate", function () { iterateGoal(g); },
        { label: "Iterate on this goal's implementation" }));
    }
    [["Archive", "archived", "Goal archived and retained for future learning."],
     ["Reactivate", "active", "Goal reactivated."]].forEach(function (pair) {
      if ((g.status || "active") === pair[1]) return;
      actions.push(UI.button(pair[0], function () { postGoal({ id: g.id, status: pair[1] }, pair[2]); }));
    });
    actions.push(UI.button("Delete", function () {
      uiConfirm("Delete this goal? Runs that carried it are kept.", { danger: true, confirmLabel: "Delete" }).then(function (yes) {
        if (yes) postGoal({ id: g.id, remove: true }, "Goal deleted.");
      });
    }, { kind: "danger", label: "Delete goal: " + (g.objective || g.id) }));
  }

  // The pill says what is actually happening, not just what is stored:
  // "running" while a run is in flight, "waiting for review" after one
  // finished. data-status carries the same word so the colours follow.
  var shown = goalStatusLabel(g, running);
  var shownKey = (g.status || "active") === "active" && running ? "running" : (g.status || "");
  var worktreeTitle = goalWorktreeTitle(g);
  return T.div({ class: "goal", "data-status": shownKey },
    T.div({ class: "goal-objective" }, g.objective || "(no objective recorded)"),
    T.div({ class: "goal-meta" },
      T.span({ class: "goal-status" }, shown),
      /* Only when the goal actually carries the field. Goals written before it
         existed have nothing to say, and a marker for "unknown" would be a
         claim the record does not make. */
      worktreeTitle
        ? T.span({ class: "goal-worktree", title: worktreeTitle }, icon("worktree", 14), "worktree")
        : null,
      g.max_iterations ? T.span("budget ≤ " + g.max_iterations + " iters") : null,
      g.id ? T.span("id " + String(g.id).slice(0, 10)) : null),
    /* A well-specified goal runs to several paragraphs and there are usually
       several of them; expanded by default they push the rest of the page off
       screen, so the objective and status stay visible and the specification
       is one click away. */
    fields.length ? T.details({ class: "goal-detail" },
      T.summary("Specification"),
      T.dl(fields.map(function (pair) {
        return [T.dt(pair[0]), T.dd(pair[1])];
      }))) : null,
    g.id ? renderGoalRunPanel(g) : null,
    actions.length ? T.div({ class: "goal-actions" }, actions) : null);
}

export function loadGoals() {
  return fetch("/api/goals")
    .then(readJson)
    .then(function (data) {
      runningIds = {};
      (data.running || []).forEach(function (r) { runningIds[r.id] = r.session || ""; });
      renderGoals(data.goals || []);
      return mirrorGoalsToBoard(data.goals || []);
    })
    .catch(function (err) {
      el.goals.textContent = "";
      var p = document.createElement("p");
      p.className = "usage-empty";
      p.textContent = "Could not load goals: " + err.message;
      el.goals.appendChild(p);
    });
}

/* A goal run streams into its own panel on the goal card, independently of
   the chat composer and of every other goal run. The server serves each
   /api/run connection on its own thread, so concurrency is purely a
   front-end shape: each run keeps its own AbortController, its own streamed
   text and its own status. Starting a second goal while the first streams is
   therefore accepted; only a second run of the *same* goal is refused. */
var goalRuns = {};  // goal id -> { controller, status, text }

function goalRunStatusLabel(status) {
  if (status === "running") return "running…";
  if (status === "stopped") return "stopped";
  if (status === "failed") return "failed";
  return "finished";
}

/* Appends a streamed line to a run's stored text and, if its panel is on
   screen, to that panel's output node directly — streaming must not rebuild
   the whole goals list on every chunk. */
function appendGoalText(gid, text) {
  var run = goalRuns[gid];
  if (!run) return;
  run.text += text;
  var node = el.goals.querySelector('.goal-run-output[data-goal-output="' + gid + '"]');
  if (node) node.textContent = run.text;
}

/* A run's status changed (finished / stopped / failed): update the stored
   status and rebuild so the panel swaps its Stop button for the verdict. The
   stored text survives, so the rebuild shows everything streamed so far. */
function setGoalStatus(gid, status) {
  var run = goalRuns[gid];
  if (!run) return;
  run.status = status;
  renderGoals(goalState.val);
}

function abortGoalRun(gid) {
  var run = goalRuns[gid];
  if (run && run.controller) run.controller.abort();
}

/* Sends a mid-run message to the agent working this goal (POST /api/steer).
   The run picks it up between iterations, accepting a correction without
   restarting the task. The echo into
   the panel is local; the run's own stream shows a "steering message
   applied" status line when the loop actually consumes it. */
function sendSteer(gid) {
  var box = el.goals.querySelector('input[data-goal-steer="' + gid + '"]');
  if (!box) return;
  var msg = box.value.trim();
  if (!msg) return;
  box.disabled = true;
  fetch("/api/steer", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ goal: gid, message: msg })
  })
    .then(readJson)
    .then(function () {
      box.value = "";
      appendGoalText(gid, "[steering sent: " + msg + "]\n");
      el.goalsStatus.textContent = "Steering message sent — the run picks it up between iterations.";
    })
    .catch(function (err) {
      el.goalsStatus.textContent = "Steering failed: " + err.message;
    })
    .finally(function () {
      box.disabled = false;
      box.focus();
    });
}

/* The run panel drawn inside a goal card. Rebuilt from stored state whenever
   the goal list re-renders, so a live run survives a status refresh. Also
   drawn — without output — for a run some other client is streaming (the
   server said so), so that run can still be steered from here. */
function renderGoalRunPanel(g) {
  var gid = g.id;
  var run = goalRuns[gid];
  // runningIds[gid] is a session id string, possibly "" (a run with no
  // session to point at) — hasOwnProperty is what means "running", not
  // truthiness, or a sessionless remote run would read as not running.
  var remote = !run && Object.prototype.hasOwnProperty.call(runningIds, gid);
  var remoteSession = remote ? runningIds[gid] : "";
  if (!run && !remote) return null;
  var status = run ? run.status : "running";
  var steerable = status === "running";
  return T.div({ class: "goal-run", "data-status": status, "data-goal-run": gid },
    T.div({ class: "goal-run-head" },
      T.span({ class: "goal-run-status" }, remote ? "running (in another session)…" : goalRunStatusLabel(status)),
      // Only offered when that run actually has a session to open — a
      // goal-only `--goal` CLI run has none, and there is nowhere to jump to.
      remote && remoteSession
        ? UI.button("View session", function () { _switchSession(remoteSession); _showView("chat"); },
            { label: "Open the conversation this run is streaming into" })
        : null,
      run && status === "running"
        ? UI.button("Stop", function () { abortGoalRun(gid); },
            { kind: "danger", icon: "strike", label: "Stop this goal run" })
        : null),
    run ? T.pre({ class: "goal-run-output", "data-goal-output": gid }, run.text || "") : null,
    steerable ? T.div({ class: "goal-steer" },
      T.input({
        type: "text",
        "data-goal-steer": gid,
        placeholder: "Steer this run — tell the agent something mid-flight…",
        maxlength: "8000",
        onkeydown: function (e) {
          if (e.key === "Enter") { e.preventDefault(); sendSteer(gid); }
        }
      }),
      UI.button("Send", function () { sendSteer(gid); },
        { label: "Send steering message to this goal run" })) : null);
}

/* Moves the goal's mirror card (if any) into `column`; a no-op when there is
   no card or it is already there. goal_sync: false because these moves come
   *from* goal state — bouncing them back through the board->goal sync would
   only re-post what is already true. */
function moveGoalCard(g, column) {
  var card = cardOfGoal(g);
  if (!card || card.column === column) return;
  postBoard({ op: "move", id: card.id, column: column, goal_sync: false }, null);
}

/* Records a run lifecycle note on the goal's mirror card, so a board reader
   can tell a finished run from a stopped or failed one without opening the
   goal panel. */
function logGoalRun(g, what) {
  var card = cardOfGoal(g);
  if (!card) return;
  postBoard({ op: "log", id: card.id, what: "goal run " + what, goal_sync: false }, null);
}

/* Starts a run that executes an active goal: switches to Goals and streams
   the run into that goal's own panel. Runs are independent — the chat
   composer's single busy guard does not apply, so several goals can be
   worked at once. The mirror card follows the run's lifecycle: doing while
   it works, review when it finishes (the server flips the goal itself to
   review at the same moment), back to ready when it is stopped or fails. */
function runGoal(g, opts) {
  if (!g || !g.id) return;
  opts = opts || {};
  var existing = goalRuns[g.id];
  if (existing && existing.status === "running") {
    el.goalsStatus.textContent = "A run for this goal is already in progress; wait for it to finish.";
    return;
  }
  var task = opts.task || ("Work on this goal until the completion criterion is met. When the work is done, land it in the repository so the goal is genuinely complete: create a branch, commit your changes to it, push the branch, open a pull request, and merge it. Do not leave the finished work uncommitted.\n\nObjective: " +
    (g.objective || "") + "\nDone when: " + (g.completion_criterion || ""));
  var controller = new AbortController();
  goalRuns[g.id] = { controller: controller, status: "running", text: "" };
  _showView("board", true);
  renderGoals(goalState.val);
  el.goalsStatus.textContent = opts.task ? "Re-evaluating goal…" : "Starting work on goal…";
  moveGoalCard(g, "doing");
  logGoalRun(g, "started");
  if (opts.onStart) opts.onStart();

  var splitter = makeLineSplitter(function (line) {
    if (line.charCodeAt(0) === 1) {
      var evt;
      try { evt = JSON.parse(line.slice(1)); } catch (e) { return; }
      if (evt.type === "error") appendGoalText(g.id, "\n[" + evt.message + "]\n");
      // A status event is a run lifecycle note (contacting the provider,
      // processing, a steering message being applied) rather than answer
      // text: show it as a bracketed log line so a run that has just started
      // is not an empty panel labelled "running…".
      else if (evt.type === "status") appendGoalText(g.id, "[ " + evt.message + " ]\n");
      return;
    }
    appendGoalText(g.id, line + "\n");
  });

  fetch("/api/run", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      task: task,
      goal: g.id,
      stream: true,
      session: _getSessionId(),
      max_iterations: opts.maxIterations || null
    }),
    signal: controller.signal
  }).then(function (resp) {
    if (!resp.ok || !resp.body) throw new Error("server responded HTTP " + resp.status);
    var reader = resp.body.getReader();
    var decoder = new TextDecoder();
    return (function pump() {
      return reader.read().then(function (chunk) {
        if (chunk.done) return;
        splitter.push(decoder.decode(chunk.value, { stream: true }));
        return pump();
      });
    })();
  }).then(function () {
    splitter.flush();
    if (goalRuns[g.id] && goalRuns[g.id].status === "running") {
      setGoalStatus(g.id, "finished");
      el.goalsStatus.textContent = "Goal run finished — waiting for review.";
      moveGoalCard(g, "review");
      logGoalRun(g, "finished");
      // The server moved the goal to review when the run completed; re-fetch
      // so the card and its status pill say so without a manual refresh.
      loadGoals();
      if (opts.onDone) opts.onDone("finished");
    }
  }).catch(function (err) {
    splitter.flush();
    if (!goalRuns[g.id]) return;
    if (err && err.name === "AbortError") {
      setGoalStatus(g.id, "stopped");
      el.goalsStatus.textContent = "Goal run stopped.";
      moveGoalCard(g, "ready");
      logGoalRun(g, "stopped");
      loadGoals();
      if (opts.onDone) opts.onDone("stopped");
    } else {
      appendGoalText(g.id, "\n[goal run failed: " + err.message + "]\n");
      setGoalStatus(g.id, "failed");
      el.goalsStatus.textContent = "Goal run failed: " + err.message;
      moveGoalCard(g, "ready");
      logGoalRun(g, "failed");
      loadGoals();
      if (opts.onDone) opts.onDone("failed");
    }
  });
}

function workOnGoal(g) {
  // Read the per-run budget box on this goal card (if any). A positive number
  // is a per-run override; anything else sends null so the server falls back
  // to the goal's stored default, then to the global agent.max_iterations.
  var box = el.goals.querySelector('input[data-goal-budget="' + g.id + '"]');
  var n = box ? parseInt(box.value, 10) : NaN;
  runGoal(g, { maxIterations: Number.isFinite(n) && n > 0 ? n : null });
}

/* Iterate: ask what specifics of the goal's implementation to refine, then
   reactivate the goal (if it is not already active) and start a run steered
   by that instruction. The current implementation stays in the repo; the new
   run is told to build on it and focus only on the named specifics, so an
   iteration is a narrower, directed pass rather than a fresh attempt from the
   goal's completion criterion alone. */
function iterateGoal(g) {
  uiPrompt(
    "What should the agent iterate on?",
    "",
    { placeholder: "e.g. the retry path, the board sync edge case, tighten the criterion…", maxlength: 8000 }
  ).then(function (raw) {
    var msg = (raw || "").trim();
    if (!msg) return;
    // Re-read the goal from live state: the user may have taken another
    // action while the prompt was open, and its status decides reactivation.
    var cur = findGoal(goalState.val, g.id) || g;
    var act = function () {
      if ((cur.status || "active") === "active") return Promise.resolve(cur);
      return postGoal({ id: cur.id, status: "active" }, "Goal reactivated for iteration.")
        .then(function (d) {
          return findGoal(d.goals, cur.id) || cur;
        });
    };
    act().then(function (goal) {
      runGoal(goal, {
        task: "Iterate on the previous work already done toward this goal. The user wants the implementation refined in this specific way — focus on this and this alone:\n\n" +
          msg + "\n\nKeep what already works; change only what this instruction targets, then land the improvement in the repository (branch, commit, push, open a pull request, and merge it).\n\nObjective: " +
          (goal.objective || "") + "\nDone when: " + (goal.completion_criterion || "")
      });
    });
  });
}

/* Runs a board card as a goal. If the card already mirrors a goal (its
   `goal` field, or an unlinked card whose title matches one), that goal is
   reused — clicking "Work as goal" twice must not mint a twin goal. Only a
   card with no goal at all creates one, and the mirror created by postGoal
   adopts this card by title, so the link is persisted without a second
   write. */
export function workCardAsGoal(c, opts) {
  if (!c || !c.id) return;
  opts = opts || {};
  var objective = (c.title || "").trim();
  if (!objective) {
    el.boardStatus.textContent = "That card has no title to turn into a goal.";
    return;
  }
  // A per-run iteration budget chosen on the card detail modal, same rule as
  // the Goals view's budget box: a positive number is a per-run override,
  // anything else sends null so the server falls back to the goal's stored
  // default, then to the global agent.max_iterations.
  var maxIterations = opts.maxIterations || null;
  var existingId = c.goal || bestGoalIdFor(objective);
  var existing = findGoal(goalState.val, existingId);
  if (existing) {
    if ((existing.status || "active") !== "active") {
      postGoal({ id: existing.id, status: "active" }, "Goal reactivated from the board.")
        .then(function (d) {
          if (!d) return;
          runGoal(findGoal(d.goals, existing.id) || existing, { maxIterations: maxIterations });
        });
    } else {
      runGoal(existing, { maxIterations: maxIterations });
    }
    return;
  }
  var criterion = (c.body || "").trim() ||
    "Complete the work described on the board card \"" + objective + "\".";
  postGoal({ objective: objective, completion_criterion: criterion }, "Goal added from the board.")
    .then(function (d) {
      if (!d) return;
      // The card's objective is the newest goal carrying that text: matching
      // by it and taking the largest `updated` picks the one just created even
      // when an older goal already used the same wording.
      var created = null, createdUp = -1;
      var goals = d.goals || [];
      for (var i = 0; i < goals.length; i++) {
        if (goals[i].objective === objective && (goals[i].updated || 0) > createdUp) {
          created = goals[i];
          createdUp = goals[i].updated || 0;
        }
      }
      if (!created) return;
      runGoal(created, { maxIterations: maxIterations });
    });
}

export function postGoal(payload, status) {
  return fetch("/api/goals", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  })
    .then(readJson)
    .then(function (d) {
      renderGoals(d.goals || []);
      el.goalsStatus.textContent = status;
      // A status change carries the mirror card along: done -> the done
      // column, review -> the review column, and a reactivation pulls the
      // card back out of done/review so the board stops claiming finished
      // work. Abandoning leaves the card where it lies.
      if (payload && payload.id && payload.status) {
        var changed = findGoal(d.goals, payload.id);
        if (changed) {
          if (payload.status === "done") {
            moveGoalCard(changed, "done");
          } else if (payload.status === "review") {
            moveGoalCard(changed, "review");
          } else if (payload.status === "archived" || payload.status === "abandoned") {
            moveGoalCard(changed, "archive");
          } else if (payload.status === "active") {
            var card = cardOfGoal(changed);
            if (card && (card.column === "done" || card.column === "review" || card.column === "archive")) {
              postBoard({ op: "move", id: card.id, column: "ready", goal_sync: false }, null);
            }
          }
        }
      }
      // A deleted goal's card stays (it is still work someone wrote down),
      // but stops claiming to mirror the goal.
      if (payload && payload.remove && payload.id) {
        for (var ci = 0; ci < (board.cards || []).length; ci++) {
          if (board.cards[ci].goal === payload.id) {
            postBoard({ op: "update", id: board.cards[ci].id, goal: "", goal_sync: false }, null);
            break;
          }
        }
      }
      // A goal created here (objective present, no id) is mirrored onto the
      // board: either an existing unlinked card with this title is adopted,
      // or a card is created in the column the goal's state asks for.
      if (payload && payload.objective && payload.id === undefined) {
        var created = null, createdUp = -1;
        var goals = d.goals || [];
        for (var i = 0; i < goals.length; i++) {
          if (goals[i].objective === payload.objective && (goals[i].updated || 0) > createdUp) {
            created = goals[i];
            createdUp = goals[i].updated || 0;
          }
        }
        if (created) mirrorGoalsToBoard([created]);
      }
      return d;
    })
    .catch(function (err) {
      el.goalsStatus.textContent = "Goal failed: " + err.message;
      return null;
    });
}

/* The id of the newest goal carrying `objective`, or null. */
function bestGoalIdFor(objective) {
  var goalId = null, best = -1;
  var goals = goalState.val || [];
  for (var i = 0; i < goals.length; i++) {
    if (goals[i].objective === objective && (goals[i].created || 0) > best) {
      goalId = goals[i].id;
      best = goals[i].created || 0;
    }
  }
  return goalId;
}

/* The goal a board card mirrors, or null: the card's own `goal` field, with
   a title match for cards that predate it. Used by board.js's board->goal
   sync when a card is moved. */
export function goalIdForCard(cardId) {
  var c = null;
  for (var i = 0; i < (board.cards || []).length; i++) {
    if (board.cards[i].id === cardId) { c = board.cards[i]; break; }
  }
  if (!c) return null;
  if (c.goal) return c.goal;
  return bestGoalIdFor(c.title);
}

/* The board's "Re-sync from goals" action: enforce every goal's pinned
   column, and additionally park the mirror of an idle active goal back in
   ready when its card still claims doing/review/done. Idempotent: a card
   already where its goal wants it is left alone, and the moves are posted
   with goal_sync off so nothing bounces back. Returns how many cards moved. */
export function syncCardsFromGoals() {
  var moved = 0;
  (goalState.val || []).forEach(function (g) {
    if (!g || !g.id) return;
    var card = cardOfGoal(g);
    if (!card) return;
    var target = goalPinnedColumn(g, isGoalRunning(g.id));
    if (!target && (g.status || "active") === "active" &&
        (card.column === "doing" || card.column === "review" || card.column === "done" || card.column === "archive")) {
      target = "ready";
    }
    if (target && card.column !== target) {
      postBoard({ op: "move", id: card.id, column: target, goal_sync: false }, null);
      moved += 1;
    }
  });
  return moved;
}

/* Wires the view to the DOM and the app: `deps.el` is app.js's element map,
   `deps.showView` switches views, `deps.getSessionId` reads the conversation
   the chat composer is on (a goal run joins that session), `deps.switchSession`
   opens a conversation by id (used to jump into a remote run's transcript). */
export function bindGoals(deps) {
  el = deps.el;
  _showView = deps.showView;
  _getSessionId = deps.getSessionId;
  _switchSession = deps.switchSession;

  bind(el.goals, goalState, function (goals) {
    if (!goals.length) {
      return UI.empty("No goals set. Add one above, or run `clanker goal \"<intent>\"`.");
    }
    return goals.map(goalCard);
  });

  el.goalForm.addEventListener("submit", function (e) {
    e.preventDefault();
    var objective = el.goalObjective.value.trim();
    var criterion = el.goalCriterion.value.trim();
    if (!objective || !criterion) return;
    var budgetRaw = el.goalMaxIterations.value.trim();
    var budget = budgetRaw ? parseInt(budgetRaw, 10) : 0;
    var payload = { objective: objective, completion_criterion: criterion };
    if (Number.isFinite(budget) && budget > 0) payload.max_iterations = budget;
    /* Sent only when ticked. Leaving the key out records nothing, which is what
       an untouched checkbox means and what keeps goals made here identical to
       every goal made before this control existed. The server turns the boolean
       into the stored string. */
    if (el.goalWorktree && el.goalWorktree.checked) payload.worktree = true;
    el.goalAdd.disabled = true;
    postGoal(payload, "Goal added.").then(function (d) {
      el.goalAdd.disabled = false;
      // A refused goal keeps what was typed: the criterion is the field most
      // likely to be refused, and retyping the objective to fix it is a tax.
      if (!d) return;
      el.goalObjective.value = "";
      el.goalCriterion.value = "";
      el.goalMaxIterations.value = "";
      if (el.goalWorktree) el.goalWorktree.checked = false;
      el.goalsStatus.textContent = "Goal card created in Backlog.";
    });
  });
}
