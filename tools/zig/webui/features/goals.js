// Goals view — ES module, no bundler.
// Owns #view-goals: goal cards, per-goal streamed runs, and the goal<->board
// mirroring glue (a goal's board card follows its run lifecycle). The board
// side of that glue lives in ./board.js; the pure helpers (sorting, field
// listing) stay in ../core/goals.js. bindGoals() wires the DOM and the
// app-level callbacks (view switching, the active session id).
import { readJson } from "../core/utils.js";
import { T, bind, UI, state } from "../core/ui.js";
import { goalSortKey, goalFields } from "../core/goals.js";
import { makeLineSplitter } from "../core/stream.js";
import { board, postBoard } from "./board.js";

var el = null;
var _showView = null;
var _getSessionId = null;

// ---- goals: what runs are being steered toward -------------------------

export var goalState = state([]);

/* Goals whose board mirror has already been requested, so a goal created
   from within a run (the agent's `goal` tool appends it to state/goals.json,
   which the next loadGoals picks up) gets a board card once rather than on
   every refresh. Form-created goals and board->goal cards set goalCardLinks
   themselves, so this only ever adds the ones that arrived without a card. */
var goalBoardMirrored = {};

/* Newest first: the goal most recently set is the one steering runs now. */
export function renderGoals(goals) {
  goalState.val = (goals || []).slice().sort(goalSortKey);
}

/* Goals that reach the web UI from state/goals.json are mirrored onto the
   board in the section matching their state (backlog for a fresh active goal),
   so a goal created from within a goal run is not invisible on the board.
   ensureGoalBoardCard is idempotent (it finds an existing card by title or
   creates one) and the goalBoardMirrored guard keeps a goal from being
   re-created across refreshes. */
function mirrorGoalsToBoard(goals) {
  (goals || []).forEach(function (g) {
    if (!g || !g.id || !g.objective || goalBoardMirrored[g.id]) return;
    goalBoardMirrored[g.id] = true;
    ensureGoalBoardCard(g.objective, g.completion_criterion);
  });
}

function goalCard(g) {
  var fields = goalFields(g);

  var actions = [];
  if (g.id) {
    /* Active goals are meant to be worked: without this, adding a goal only
       wrote state/goals.json and never started a run. The per-run budget box
       sets this run's max iterations; left blank it falls back to the goal's
       stored default, then to the global agent.max_iterations. */
    if ((g.status || "active") === "active") {
      actions.push(T.div({ class: "goal-run-controls" },
        T.input({
          type: "number", min: "1", max: "1000", step: "1",
          "data-goal-budget": g.id,
          placeholder: g.max_iterations ? ("≤ " + g.max_iterations + " iters (default)") : "max iters (default)",
          title: "Optional per-run max iterations. Blank uses the goal's stored default, then the global agent.max_iterations."
        }),
        UI.button("Work on this", function () { workOnGoal(g); },
          { label: "Work on goal: " + (g.objective || g.id) }),
        UI.button("Re-evaluate", function () { reEvaluateGoal(g); },
          { label: "Re-evaluate whether goal is done: " + (g.objective || g.id) })));
    }
    [["Mark done", "done", "Goal marked done."],
     ["Abandon", "abandoned", "Goal abandoned."],
     ["Reactivate", "active", "Goal reactivated."]].forEach(function (pair) {
      if ((g.status || "active") === pair[1]) return;
      actions.push(UI.button(pair[0], function () { postGoal({ id: g.id, status: pair[1] }, pair[2]); }));
    });
    actions.push(UI.button("Delete", function () {
      if (!window.confirm("Delete this goal? Runs that carried it are kept.")) return;
      postGoal({ id: g.id, remove: true }, "Goal deleted.");
    }, { kind: "danger", label: "Delete goal: " + (g.objective || g.id) }));
  }

  return T.div({ class: "goal", "data-status": g.status || "" },
    T.div({ class: "goal-objective" }, g.objective || "(no objective recorded)"),
    T.div({ class: "goal-meta" },
      T.span({ class: "goal-status" }, g.status || "unknown"),
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
    g.id ? renderGoalRunPanel(g.id) : null,
    actions.length ? T.div({ class: "goal-actions" }, actions) : null);
}

export function loadGoals() {
  return fetch("/api/goals")
    .then(readJson)
    .then(function (data) {
      renderGoals(data.goals || []);
      mirrorGoalsToBoard(data.goals || []);
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
/* Board cards started as goals: goal id -> card id. Set when "Work as goal"
   turns a card into a goal, so the goal card can move its board card through
   the board columns as the goal progresses (done when marked done). */
var goalCardLinks = {};

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

/* The run panel drawn inside a goal card. Rebuilt from stored state whenever
   the goal list re-renders, so a live run survives a reload or a status
   refresh. */
function renderGoalRunPanel(gid) {
  var run = goalRuns[gid];
  if (!run) return null;
  return T.div({ class: "goal-run", "data-status": run.status, "data-goal-run": gid },
    T.div({ class: "goal-run-head" },
      T.span({ class: "goal-run-status" }, goalRunStatusLabel(run.status)),
      run.status === "running"
        ? UI.button("Stop", function () { abortGoalRun(gid); },
            { kind: "danger", icon: "strike", label: "Stop this goal run" })
        : null),
    T.pre({ class: "goal-run-output", "data-goal-output": gid }, run.text || ""));
}

/* Starts a run that executes an active goal: switches to Goals and streams
   the run into that goal's own panel. Runs are independent — the chat
   composer's single busy guard does not apply, so several goals can be
   worked at once. */
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
  _showView("goals", true);
  renderGoals(goalState.val);
  el.goalsStatus.textContent = opts.task ? "Re-evaluating goal…" : "Starting work on goal…";
  // A goal mirrored onto the board follows the run's lifecycle: its card moves
  // to doing when the run starts, review when it finishes, and back to ready if
  // it is stopped or fails. workCardAsGoal also moves its card explicitly, so
  // this only applies where a goal->card link exists (form-created goals).
  if (goalCardLinks[g.id]) {
    moveGoalCardToColumn(g.id, "doing");
    logGoalRunState(g.id, "running");
  }
  if (opts.onStart) opts.onStart();

  var splitter = makeLineSplitter(function (line) {
    if (line.charCodeAt(0) === 1) {
      var evt;
      try { evt = JSON.parse(line.slice(1)); } catch (e) { return; }
      if (evt.type === "error") appendGoalText(g.id, "\n[" + evt.message + "]\n");
      // A status event is a run lifecycle note (contacting the provider,
      // processing) rather than answer text: show it as a bracketed log line
      // so a run that has just started is not an empty panel labelled
      // "running…" while it waits for its first streamed output.
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
      el.goalsStatus.textContent = "Goal run finished.";
      if (goalCardLinks[g.id]) {
        moveGoalCardToColumn(g.id, "review");
        logGoalRunState(g.id, "finished");
      }
      if (opts.onDone) opts.onDone("finished");
    }
  }).catch(function (err) {
    splitter.flush();
    if (!goalRuns[g.id]) return;
    if (err && err.name === "AbortError") {
      setGoalStatus(g.id, "stopped");
      el.goalsStatus.textContent = "Goal run stopped.";
      if (goalCardLinks[g.id]) {
        moveGoalCardToColumn(g.id, "ready");
        logGoalRunState(g.id, "stopped");
      }
      if (opts.onDone) opts.onDone("stopped");
    } else {
      appendGoalText(g.id, "\n[goal run failed: " + err.message + "]\n");
      setGoalStatus(g.id, "failed");
      el.goalsStatus.textContent = "Goal run failed: " + err.message;
      if (goalCardLinks[g.id]) {
        moveGoalCardToColumn(g.id, "ready");
        logGoalRunState(g.id, "failed");
      }
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

/* Re-evaluates whether the goal is already done: runs the agent against the
   completion criterion and asks it to inspect the current state and give a
   verdict, rather than doing the work. Streams into the goal's own panel like
   any other run, and if the agent concludes it is met the user can mark it
   done from the same card. */
function reEvaluateGoal(g) {
  if (!g || !g.id) return;
  runGoal(g, {
    task: "Re-evaluate whether this goal is already done. Do NOT do the work " +
      "or make changes unless strictly needed to verify. Inspect the current " +
      "state (files, board, recorded runs) and report clearly whether the " +
      "completion criterion is met, and why.\n\nObjective: " +
      (g.objective || "") + "\nDone when: " + (g.completion_criterion || "")
  });
}

/* Turns a board card into a goal and starts a run on it, moving the card
   through the board with the run's lifecycle: into Doing when the run starts,
   into Review when it finishes, and back to Ready if it is stopped or fails
   (so it never sits in Doing half-finished). The card id lives in the browser
   and the run streams back its own end, so the movement is a front-end
   concern here. */
export function workCardAsGoal(c) {
  if (!c || !c.id) return;
  var objective = (c.title || "").trim();
  if (!objective) {
    el.boardStatus.textContent = "That card has no title to turn into a goal.";
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
      goalCardLinks[created.id] = c.id;
      postBoard({ op: "move", id: c.id, column: "doing" }, null);
      runGoal(created, {
        onDone: function (status) {
          var col = status === "finished" ? "review" : "ready";
          postBoard({ op: "move", id: c.id, column: col }, null);
        }
      });
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
      // A goal marked done (and only that) carries its board card over to the
      // board's done column: the card was moved to doing when the goal started
      // and review when it finished, so closing the goal closes the loop. This
      // is a front-end concern — the goal id -> card id link lives in this
      // browser (see goalCardLinks), not in state/goals.json.
      if (payload && payload.status === "done" && payload.id) {
        moveGoalCardToColumn(payload.id, "done");
        logGoalRunState(payload.id, "done");
      }
      // A goal created from the Goals view (objective present, no id) is also
      // mirrored onto the board: it gets a card in the column that matches the
      // goal's state (backlog for a fresh active goal). The card is the board's
      // equivalent of the goal, so working on / finishing / closing the goal
      // later moves it through doing -> review -> done (see runGoal and the
      // mark-done branch above). Goals created from an existing board card are
      // skipped here — workCardAsGoal already owns that card and links it.
      if (payload && payload.objective && payload.id === undefined && payload.column === undefined) {
        ensureGoalBoardCard(payload.objective, payload.completion_criterion);
      }
      return d;
    })
    .catch(function (err) {
      el.goalsStatus.textContent = "Goal failed: " + err.message;
      return null;
    });
}

/* Mirrors a freshly-created goal onto the board: finds the card whose title is
   the goal's objective (the board mirror created by workCardAsGoal, or an
   earlier auto-add), or creates one in the backlog column if none exists, then
   records the goal -> card link so the card follows the goal's lifecycle.
   Idempotent: a goal whose objective already matches a card is only linked;
   a goal with no matching card creates one. */
function ensureGoalBoardCard(objective, criterion) {
  if (!objective) return;
  var existing = null;
  for (var i = 0; i < board.cards.length; i++) {
    if (board.cards[i].title === objective) { existing = board.cards[i]; break; }
  }
  var goalId = bestGoalIdFor(objective);
  if (existing) {
    if (goalId) goalCardLinks[goalId] = existing.id;
    return;
  }
  var done = function (d) {
    if (!d || !d.board) return;
    var created = null;
    for (var j = 0; j < d.board.cards.length; j++) {
      if (d.board.cards[j].title === objective) { created = d.board.cards[j]; break; }
    }
    if (created && goalId) goalCardLinks[goalId] = created.id;
  };
  postBoard({ op: "create", title: objective, body: criterion, column: "backlog" }, null).then(done);
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

/* Moves the board card linked to a goal (if any) into `column`. The link is
   recorded when the card is started as a goal; without one this is a no-op, so
   marking a hand-typed goal done never disturbs the board. */
function moveGoalCardToColumn(goalId, column) {
  var cardId = goalCardLinks[goalId];
  if (!cardId) return;
  postBoard({ op: "move", id: cardId, column: column }, null);
}

/* Records a goal run's state on its board card so the card's activity log
   reflects the run lifecycle, not just which column it sits in. The column
   move already encodes where the work stands (doing / review / ready); the
   log entry says what the run actually did, so a board reader can tell a run
   that finished from one that was stopped or failed without opening the goal
   panel. No-op when the goal has no linked card. */
function logGoalRunState(goalId, state) {
  var cardId = goalCardLinks[goalId];
  if (!cardId) return;
  postBoard({ op: "log", id: cardId, what: "goal run " + state }, null);
}

/* The goal a board card is the mirror of, or null. Reverse of goalCardLinks:
   iterate the goal->card map and return the goal that points at this card. */
export function goalIdForCard(cardId) {
  for (var gid in goalCardLinks) {
    if (goalCardLinks[gid] === cardId) return gid;
  }
  return null;
}

/* Wires the view to the DOM and the app: `deps.el` is app.js's element map,
   `deps.showView` switches views, `deps.getSessionId` reads the conversation
   the chat composer is on (a goal run joins that session). */
export function bindGoals(deps) {
  el = deps.el;
  _showView = deps.showView;
  _getSessionId = deps.getSessionId;

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
    el.goalAdd.disabled = true;
    postGoal(payload, "Goal added.").then(function (d) {
      el.goalAdd.disabled = false;
      // A refused goal keeps what was typed: the criterion is the field most
      // likely to be refused, and retyping the objective to fix it is a tax.
      if (!d) return;
      el.goalObjective.value = "";
      el.goalCriterion.value = "";
      el.goalMaxIterations.value = "";
      // Newest first after renderGoals — start work so defining a goal is not
      // just writing state/goals.json.
      var goals = goalState.val || [];
      var created = null;
      for (var i = 0; i < goals.length; i++) {
        if ((goals[i].status || "active") === "active" && goals[i].objective === objective) {
          created = goals[i];
          break;
        }
      }
      if (created) workOnGoal(created);
    });
  });
}
