# RFC 0001 — Workspace, room, board, and folder hierarchy

## Status

Discussion — opened 2026-08-16, revised same day for the multi-component
project model (a project spans several folders, owns a `#general` feed and
optional per-goal output rooms, and any clanker — local, loopback, or
networked — joins the same way).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

An operator wants to treat "the project" as one thing with several parts:
a board, a `#general` feed, and a set of folders that live in different
directories. The `#general` room is the project's activity feed — operator
chat plus board updates — and the board is its fold. Heavy agent work — a
goal's model output — goes to its own room rather than flooding the feed.
Today those parts sit next to each other without a declared relationship, so
the next implementation will invent a hierarchy whether we write it down or not.

The forcing examples are suites, not leaves: `relumea` is one product whose
repos are `relumea-core` and `relumea-web` in different directories, and
`~/Desktop/7dtd` is a game plus its tools. The operator wants **one board and
one `#general` feed for the project**, not one per folder, wants **a room per
goal for the actual model output** so the feed stays readable, and wants a
second clanker — a different process on the same host, or a networked
instance — to **join the project** and see the same board, feed, and folders.

**Decision to make.** How should folders, the workspace (a project), its
rooms (`#general` feed, per-goal output), goals, membership, and remote clanker
instances relate?

**Why now.** Three follow-on changes are blocked on the same answer: bind the
default board to a workspace, put a workspace id on goals, and define
share / enter / leave for mesh Phase 3. Doing any of those against today's
implied model (one global `board` room, a workspace that is a single folder, a
session tag that is not a path, a local `workspaces.json`) will bake a shape
that the next change has to migrate.

**Drivers.**

- Do not re-litigate ADR 0001 (the board is a chatroom fold) or ADR 0012
  (goal draft, persist, and run stay separate).
- A workspace **is** a project: one stable id over one or more named folders
  (components). The single-folder model fails the suite case by construction.
- A project owns a small **room namespace**, not one log: a default `#general`
  room that carries operator chat and board updates (the board is its fold,
  ADR 0001), and optional focused rooms — one per goal — for the goal's model
  output. The feed stays readable; heavy agent work goes to its own room.
  Per-object rooms are already the pattern (`arena-<id>`).
- Membership is uniform. The instance that owns a workspace is always in it;
  every other clanker — another process on the same host, or a networked
  instance — joins the same way, with the same verbs. Loopback is an address,
  not a mode.
- A workspace id is never a path (`src/agent/workspace.zig`: no `/` or `\`).
  A local folder path is never a global name. Component paths live on the
  home instance; a remote member maps them via an explicit bind.
- The sandbox still enforces reach. Multi-root is a sandbox change (a root
  set, not one root), and that is a security review, not a rename. File bytes
  that cross the mesh land under `state/mesh/<home-id>/files/`, never over a
  local path of the same name (PRD 0011).
- One obvious way to do a thing. Mesh join/leave must not be overloaded as
  project enter/leave.
- Suites (one product, several repos) and leaves (one repo) both have to be
  first-class. `~/Desktop/Projects` itself is a drawer, not a project.
- Only another `clanker serve` can share or enter a workspace. `clanker run`,
  the REPL, subagents, A2A, and ACP are not peers.
- Same-host multi-process mesh is the same mesh. Two `clanker serve`
  processes on one box join, share, enter, leave, and bind with the same
  frames as two machines. A shared `state/` is not a mesh: that is one
  instance with two processes fighting over the same files.

**Out of scope.** Mesh transport, admission, and TLS (PRD 0011). Goal
write / add / run split (ADR 0012). Whether the board stays a chatroom
(ADR 0001). Cron. Implementing share/enter/leave in this turn. Per-root share
(share a subset of a project's folders). Roles/permissions within a project
(read-only member vs editor). A general arbitrary room hierarchy (rooms beyond
`#general` / per-goal). A UI that browses the whole mesh as one tree (PRD 0011
non-goal). Per-session exclude from a share (PRD 0011 open question).

## Current state

These pieces already exist, and already disagree about ownership. Two are
missing entirely.

| Thing | Where it lives | What it is bound to today |
|---|---|---|
| Folder | an absolute directory on one machine | the `path` on a workspace row, or the serve cwd |
| Workspace | `state/workspaces.json` (`src/agent/workspace.zig`) | **exactly one** folder + sessions tagged with that id. Empty id is the cwd and is never stored |
| Component / root | *does not exist* | a workspace cannot name a second folder today |
| Session | `state/sessions/<id>.json` | a single `workspace` string (`src/agent/session.zig`) |
| Chatroom | `state/chatrooms.jsonl` | a fleet-scoped named log. Subscribe is per instance, not per workspace (PRD 0001). DMs are ordinary rooms `dm:<a>\|<b>` with no folder and no board; arenas already get per-object rooms `arena-<id>` |
| Kanban | fold of a room, default `"board"` (`tools/zig/board.zig`) | the room the caller named, otherwise one global board for the instance. The board is already a room fold; there is no per-project `#general` room and no goal rooms |
| Goal | `state/goals.json` | optional `worktree` (git branch/path). No workspace field (`tools/zig/add_goal.zig`) |
| Goal room | *does not exist* | a goal's model output lives in a session, with no room of its own |
| Membership | `state/mesh/members.json` (PRD 0011) | **mesh** membership only. No per-project roster, no enter/leave |
| Bind record | *does not exist* | nothing maps a remote project's folders to local checkouts |
| Private todos | in-memory, per run (ADR 0002) | the run, never a room |
| Mesh member | `state/mesh/members.json` (PRD 0011) | an `instance.id`. JOIN may *advertise* `share.workspaces[]` but sharing is not implied |
| Remote replica | `state/mesh/<home-id>/sessions/` (Phase 3, not built) | home instance owns the canonical transcript |

The web UI rail (`#workspace-pick`) already treats a workspace as "a folder
on this machine and its chat history". The files browser sandboxes to that
folder. The board view does not. The goals view does not. Two serves that
both register `~/Desktop/7dtd` still have two workspaces: same path is a
coincidence, not identity. Two serves started from the same checkout
without a private `state_dir` are not meshed at all: they share
`state/sessions/`, `state/chatrooms.jsonl`, and `state/workspaces.json`.
Serve's HTTP listen sets `reuse_address`, so a second process can even
bind the same web UI port; that is a collision, not a cluster.

The status quo is viable for one operator, one machine, one checkout, one
folder. It fails as soon as a project spans two folders, or a second instance
needs the same board and feed, or a long goal loop starts flooding the one
global room with model output.

## Options considered

### Option A — single-folder typed hierarchy (one folder per workspace)

- **What it is:** keep the types distinct and pin their edges, but leave a
  workspace at exactly one folder. Cross-tree work is an "extra attach" list
  of other workspace ids on the same session. The room namespace idea below
  (a `#general` feed plus per-goal rooms) applies to A too; A just keeps one
  root.

  ```
  instance (instance.id)
    workspace (stable id, local path on home only)
      folder          exactly one
      sessions        tagged with that id
      extra attaches  other workspace ids on the same session
      board room      `board` on the default workspace, `board:<id>` otherwise
      goals           tagged with that id
    rooms             fleet-scoped logs (lounge, ops, dm:…). Not workspaces.
  mesh
    join / leave      instance membership
    share / unshare   home offers one workspace id
    enter / leave     a member subscribes to that offer
    bind              optional local checkout mapped to the same id
  ```

  Remote sharing is the PRD 0011 home rule plus three operator verbs:
  **share** (home offers the id), **enter** (peer takes a shadow row: same id,
  `home=<instance>`, no path), **bind** (peer maps a local checkout).

- **Maturity:** most of the types already exist. Missing: goal `workspace`
  field, `board:<id>` convention, session extra-attach list, enter/leave/bind.
- **How it would fit:** `workspace.zig` stays the local registry.
  `Session.workspace` stays the primary id; a new optional extras list holds
  the rest. `goal_add` grows a workspace field. `board.zig` already accepts
  `room`; the host default becomes `board:<ws>`.
- **Pros:**
  - Matches the files rail and the sandbox (one root) as they exist today.
  - Does not invent a second replication mechanism.
  - A laptop can enter `7dtd` without pretending it has the local path.
- **Cons:**
  - **A project with two folders is not one workspace.** `relumea` cannot be
    "one board, one feed" without either opening the parent drawer or adding
    an extra-attach list — which is exactly the multi-root idea, under a
    different name, and the "run may touch" extras still need a sandbox root
    set to be enforced (see Option B). Extra-attach is either informational
    (then it is not reach) or enforced (then it carries B's sandbox cost with
    none of B's clarity).
  - `board:<id>` forks the current global `board` room.
- **Cost to adopt:** schema additions (goal field, session extras, shadow
  rows), one board-room defaulting rule, share/enter/leave/bind surface.
- **Cost to leave:** drop the extra field and the room default. The one-way
  door is migrating cards off the global `board` room.
- **Evidence:** `workspace.zig` is already "named folder plus tagged
  conversations"; `board.zig` already takes `room`; PRD 0011 Phase 3 already
  has home + explicit share.

### Option B — multi-root project workspace (recommended)

- **What it is:** a workspace is a **project**: one stable id over one or more
  named folders (components), a small **room namespace** (a `#general` feed
  plus optional per-goal output rooms), tagged goals and sessions, and a
  membership roster. The owning (home) instance is always a member; every other
  clanker — another process on the same host or a networked instance — becomes
  a member by entering the same shared offer.

  ```mermaid
  flowchart TD
      subgraph Inst["instances (mesh members)"]
          Main["instance main — home / owner"]
          Laptop["instance laptop — peer"]
      end

      subgraph WS["workspace relumea — one project"]
          W["workspace id<br/>(stable, never a path)"]
          W --> Roots["roots — named folders: core, web"]
          W --> Gen["ws:relumea · #general<br/>chat + board updates<br/>(board = fold of this room)"]
          W --> GoalRoom["ws:relumea:goal:&lt;id&gt;<br/>per-goal model output<br/>(optional, lossy feed)"]
          W --> Goals["goals — tagged relumea"]
          W --> Sessions["sessions — tagged relumea"]
          W --> Members["members — main (home), laptop"]
      end

      subgraph Fleet["fleet rooms — not projects"]
          DM["dm:&lt;a&gt;|&lt;b&gt;<br/>direct messages"]
          Ops["ops / other fleet rooms"]
      end

      Main --- W
      Laptop -.->|enter/leave| Members
      Main --- Fleet
      Laptop --- Fleet
  ```

  **A room namespace, not one log.** ADR 0001 already made the board a chatroom
  fold, so the project's default room `ws:<id>` (shown as `#general`) is the
  board *and* the project feed: card actions are `@todo` messages the fold
  picks out, operator chat is everything else. A goal may get an optional
  `ws:<id>:goal:<goal-id>` room for its actual model output — turns, decisions,
  diffs — so a long goal loop does not flood the feed. The board stays one fold
  over `#general`; goal rooms are output feeds, and the goal's card remains on
  the board (the card already carries the goal id). The empty-id (cwd)
  workspace keeps today's `board` room as its `#general`, so existing logs do
  not move.

  **Two different canonical rules.** The board's room *is* the board's source
  of truth (ADR 0001: there is no `board.json`). A goal's output is *not*: the
  session transcript is the durable record (PRD 0011 home writes it), and the
  goal room is a shared projection/feed of that work, allowed to be lossy
  summaries. Making the goal room another canonical store would re-create the
  two-stores-for-one-idea problem ADR 0001 closed.

  ```mermaid
  sequenceDiagram
      participant Goal as Goal loop (agent)
      participant GR as ws:relumea:goal:&lt;id&gt;
      participant Gen as ws:relumea (#general)
      participant Peers as Entered members

      Goal->>GR: post model output (turns, decisions, diffs)
      GR->>Peers: fan-out to subscribers
      Goal->>Gen: card action — @todo move / claim / log
      Gen->>Peers: fan-out board update to subscribers
      Note over Gen,Peers: the board is the fold of #general (ADR 0001)
  ```

  **Membership is uniform.** The home process owns its workspaces and is always
  in them — no local join needed. A second process on the same host is a loopback
  mesh peer and enters exactly like a networked instance: `share` on home,
  `enter` on the peer (subscribe to the project's rooms, take replica sessions
  under `state/mesh/<home-id>/sessions/`, optionally `bind` local folders),
  `leave` to unsubscribe. `bind` is always explicit, even when both processes
  see the same absolute path.

  **Folders reach a member two ways.** For editing, the member `bind`s a local
  checkout (git is the file merge, PRD 0011). For reading without a checkout,
  shared file bytes land under `state/mesh/<home-id>/files/` — never over a
  local path of the same name.

- **Maturity:** multi-root is VS Code's default for "this product is several
  folders", and it is the fix for the single-cwd gap Claude Code operators file
  ([anthropics/claude-code#47983](https://github.com/anthropics/claude-code/issues/47983),
  open as of 2026-08). The
  [repo-of-repos](https://www.raffertyuy.com/raztype/repo-of-repos-pattern/)
  and
  [multi-repo workspace](https://medium.com/@sunghyunroh/multi-repo-workspace-strategy-the-structure-where-ai-coding-agents-actually-shine-4ed6b87fb11d)
  writeups are the same conclusion from the other direction: people invent an
  *outer* object to hold N folders. We already have the outer object — the
  workspace id — it just holds one path today. Per-object rooms are already
  established (`arena-<id>`), so per-goal rooms are the same pattern.
- **How it would fit:** `Workspace.path: []const u8`
  (`src/agent/workspace.zig:30-35`) becomes `roots: []Root` with `{name, path}`.
  `workspaceSandboxPath` (`src/cli.zig:11255`) and `openWorkspaceRoot`
  (`src/cli.zig:11261`) return a root **set** instead of one directory; the
  files browser takes a root/component selector. The run sandbox root
  (`run_cfg.agent.sandbox_root`, `src/cli.zig:12908`) becomes a set, and
  `fs_prefixes` — already a list, and today validated as "relative to the
  sandbox root" (`src/toolhost/manifest.zig:493`) — needs a disambiguator for
  which root a prefix is relative to. The default board room moves from the
  global `board` to the project's `ws:<id>` (`#general`), empty-id keeps
  `board`; goal rooms are created on demand under `ws:<id>:goal:<id>` and are a
  feed over the session, not a store. Goal/session fields are the same additive
  change as A. Mesh Phase 3 guests `workspace_share` as specified;
  enter/leave/bind are the operator surface on that offer, not new frame kinds.
- **Pros:**
  - The suite case is the default, not an attach: `relumea` is one project with
    two roots, one board, one `#general` feed — which is what "the relumea
    board" means.
  - The feed stays readable: a goal's model output lives in its own room, while
    board updates and operator chat stay in `#general`. The board remains one
    consistent fold.
  - Membership is one set of verbs for local, loopback, and networked clankers;
    only the address differs.
  - Does not invent a second replication mechanism (board rides the room,
    sessions ride PRD 0011 home).
  - A leaf opened alone is just a project with one root — the same shape, no
    special case.
- **Cons:**
  - The sandbox's single-root assumption must become a root set. That is the
    first security-sensitive change in this RFC and must be spiked, not assumed.
  - A leaf opened alone and the same folder as a root of the suite become two
    names for one tree.
  - Sharing a project shares all its roots; per-root share is a follow-up.
  - Remote bind is N checkouts, not one.
- **Cost to adopt:** workspace schema (roots list), files API + sandbox root
  set, board-room defaulting rule + goal-room creation, membership roster,
  share/enter/leave/bind surface. This is the largest option and the one real
  cost.
- **Cost to leave:** sessions and shares that refer to a multi-root id must be
  split back into single-root workspaces (a data migration); the sandbox root
  set reverts to one root; goal rooms can be dropped and the fold moved back to
  the global `board`.
- **Evidence:** VS Code multi-root; Claude Code
  [#47983](https://github.com/anthropics/claude-code/issues/47983) is the
  single-folder complaint; repo-of-repos and multi-repo-workspace writeups
  both conclude "outer object holds N repos". Eric Ma,
  [cross-repo agents](https://ericmjl.github.io/blog/2025/11/17/how-to-reference-code-across-repositories-with-coding-agents/):
  operators already attach extra paths by telling the agent the other path —
  a roots list makes that a named field instead of a prompt convention.
  `fs_prefixes` is already a list (`src/sandbox/host.zig:178`); the single
  assumption is the root *directory*, not the prefix type. `arena-<id>` rooms
  (`tools/zig/lib.zig`) show per-object rooms are an existing convention.

### Option C — collapse the types

- **What it is:** chatroom = workspace = folder. One name, one log, one path,
  the board is that room's fold. Entering a workspace is joining a room.
- **Maturity:** how a lot of chat products feel; also how this repo looked
  before `workspace.zig` existed.
- **How it would fit:** delete `workspaces.json` or make it room metadata.
  `Session.workspace` becomes the room name. Mesh JOIN `share.rooms[]` is the
  only share list.
- **Pros:** fewest nouns; board, chat, and "where are we" cannot disagree.
- **Cons:** a folder is not a log. A laptop that has not bound a checkout still
  needs a room, and a room still needs a path on *some* machine; collapse hides
  that split. Fleet lounge and `ws:relumea` are different kinds of room.
  Forcing every room to have a folder either pollutes the drawer or makes
  "folder" optional — which is B with worse names. ADR 0001 said the board
  rides a room, not that a room *is* a workspace.
- **Evidence:** PRD 0001 rooms have no path; DMs (`dm:<a>|<b>`) are rooms with
  no folder. PRD 0011 JOIN carries *both* `share.workspaces[]` and
  `share.rooms[]` — the design already says they are not the same set.

### Option D — status quo

- **What it is:** keep today: workspace is one local folder plus a session tag,
  one global `board` room, goals untagged, no enter/leave.
- **Pros:** zero migration.
- **Cons:** a project spanning two folders has no name; a second instance cannot
  enter a project as a first-class act; goals remain instance-global; a goal
  loop's model output floods the one global `board` room; the next "board per
  workspace" change guesses a room name in the dark.
- **Evidence:** `Session.workspace` is a single string; `add_goal.zig` has
  `worktree` and no workspace; `board.zig` defaults to `"board"`.

### Option E — out of the box: cwd is the workspace, git is identity

- **What it is:** delete the registry; the workspace *is* the process cwd.
  Cross-machine identity is `(git remote, HEAD)`. A second instance "enters" by
  cloning the same remote. No `workspaces.json`, no share verb, no shadow rows.
- **Maturity:** the default for most CLI coding agents, and why they grow
  `CLAUDE.md`/`AGENTS.md` at the repo root and then invent outer repos.
- **Pros:** no new identity; git is already the file merge; `clanker run` in a
  checkout is already this.
- **Cons:** non-git trees (notes, `7dtd` game data, a mixed drawer) have no
  identity; two clones of one remote need a disambiguator, which is a registry
  again; the board is not in git; home-instance for sessions is still required.
  The first suite forces an outer object — the same conclusion as B.
- **Evidence:** Claude Code #47983; Eric Ma cross-repo (the workaround is "tell
  the agent the other path", i.e. B's roots list done by hand).

## Implications by horizon

### Short term (this release / 0–3 months)

- **If B:** add `workspace` on goals; default the board room to `ws:<id>`
  (`#general`) when a non-empty workspace is selected (empty-id keeps `board`
  so today's log does not move); add a membership roster row (owner + entered
  members). **Spike the sandbox root set before anything else** — it is the
  only irreversible-enough change and the only security-sensitive one.
- **If A:** add `workspace` on goals; default `board:<id>`; extra-attach stays
  an open question.
- **If C:** rename in the UI only, or accept rooms-without-folders leaking.
- **If status quo:** ship nothing; the next board or goals change guesses.
- **If E:** delete or ignore `workspaces.json`; break the files rail for any
  registered non-cwd folder.

### Medium term (3–12 months)

- **If B:** mesh Phase 3 implements share/enter/leave/bind against a locked
  model. Two machines bind the same id to different checkouts; git merges files,
  home merges transcripts. The files browser shows the project's roots as a
  selector. Goal rooms are created on demand as feeds over their sessions; the
  board stays one fold over `#general`.
- **If A:** the first real suite pushes the extra-attach list into being a de
  facto multi-root, or the operator opens the parent drawer.
- **If C:** fleet rooms and project rooms fight for the same picker; someone
  re-adds "this room has no folder".
- **If status quo:** each surface grows a private notion of "current project";
  they drift.
- **If E:** every suite becomes a super-repo or a pile of absolute paths in
  prompts.

### Long term (12+ months)

- **If B:** the type list is stable. New objects (schedules, arenas, knowledge
  collections) attach to a workspace id the way sessions do, or stay
  instance-global on purpose. The residual tax is teaching share ≠ enter ≠
  join.
- **If A:** we revisit this RFC when the multi-root requirement bites.
- **If C:** we reintroduce workspaces under another name ("project rooms",
  "pathed rooms").
- **If status quo:** a later RFC is this file, with a larger migration.
- **If E:** we track other agents' outer-repo conventions instead of our own
  types.

## Recommendation

**Recommended option:** Option B, multi-root project workspace: a stable
workspace id over one or more named roots; a small room namespace — `ws:<id>`
(`#general`: chat + board updates) and optional `ws:<id>:goal:<id>` rooms for
model output; goals and sessions tagged to that id; and mesh share / enter /
leave / bind kept distinct from mesh join / leave.

**Confidence:** 6/10

**Why this confidence.** The product requirement is now explicit and
unambiguous — a project is several folders with one board, one `#general` feed,
and per-goal output rooms, and any clanker joins it the same way. That points
straight at B. What holds the score at 6 is that B carries the first
security-sensitive change in this RFC: the sandbox's single root becomes a root
set, and `fs_prefixes` "relative to the sandbox root" must be redefined against
N roots. Confidence rises to 7–8 if a spike shows a root set can be enforced
without weakening `fs_prefixes`, and if the `ws:<id>` / `ws:<id>:goal:<id>`
naming folds chat + board + goal output without breaking the existing `board`
log. It sinks if the root set proves too expensive and A's extra-attach is
enough in practice (operators open leaves alone more than suites), or if the
suite really is "share the whole drawer", which no option here endorses.

**Rationale.** A keeps the sandbox simple and loses the very case the operator
named as the requirement. C looks like fewer nouns and then immediately needs
optional folders and two kinds of room. E is the right *file* merge (git) and
the wrong *session* merge (home still orders appends; non-git trees still need
an id). Status quo is not a decision, it is a deferral while the drift accrues.
B is the only option where "the relumea board", "the relumea `#general`", "the
relumea goal rooms", and "join relumea from another machine" all mean one
thing. Its room namespace is not a new mechanism: rooms are already cheap named
logs with a `:` convention (`dm:`) and per-object rooms (`arena-<id>`), so
`#general` and per-goal rooms are just names in that space. The cost B adds — a
sandbox root set — is real and must be spiked first, but it is the cost of the
requirement, not a reason to pretend the requirement does not exist.

**Reversibility.** Additive fields (goal.workspace, membership roster, goal
rooms, bind records) are easy to ignore. The points of no return are:
promoting the single `board` room to per-project `ws:<id>` (`#general`) rooms,
advertising multi-root workspace ids over the mesh as if stable, and the
`roots` list itself (splitting a multi-root id back into single-root workspaces
is a data migration). Do not migrate the existing `board` log until a second
project actually needs its own board; keep `board` as the empty-id workspace's
`#general` room forever. Spike the root set before committing to it.

## Open questions

1. **Room namespace separator collision.** Workspace ids currently allow `:`
   (`validName` rejects only controls and `/`, `\`), so `ws:<id>:goal:<id>` is
   ambiguous when a workspace id is literally `relumea:goal`. Bias: reject `:`
   in workspace ids (or reserve a separator). Who: this RFC.
2. **Sandbox root-set semantics.** Do `fs_prefixes` grant "any root" or name a
   specific root? How do callers that assume one root (`openWorkspaceRoot`,
   `workspaceSandboxPath`) get upgraded without a global `chdir` race? This is
   the spike that gates B. Who: whoever implements the files/sandbox change.
3. **Is the goal room opt-in, and how much output does it hold?** Created on
   demand, default off? Full model output or lossy summaries? Bias: opt-in;
   summaries by default, full output only on request, because the session is
   the canonical transcript.
4. **Is the goal room canonical for goal output, or a projection over the
   session?** Bias: projection — the session (PRD 0011 home) is the durable
   record, the room is a lossy feed. Making the room canonical duplicates the
   session and re-opens the two-stores problem ADR 0001 closed.
5. **Component naming and bind identity.** Are roots keyed by a local name
   (`core`, `web`) that bind matches by name, or does a root carry its own
   stable id so two checkouts of the same root can be told apart? Bias: named,
   explicit; matching by basename is the `7dtd`-vs-`7dtd` collision.
6. **Membership roles.** Is entering read-write, or do we need a read-only
   "watch" member? Bias: read-write for v1, roles are a follow-up.
7. **Per-root share.** Does `share` offer the whole project, or can home offer
   a subset of roots? Bias: whole project first; subset later.
8. **Rename "workspace" to "project"?** The operator thinks "project", the code
   says `workspace`. Bias: keep `workspace` for continuity with `workspace.zig`
   and `Session.workspace`; the rename is cosmetic and can happen later.
9. **Home-unreachable continues to refuse writes (PRD 0011), or do we want a
   later fork-and-reconcile?** Out of scope here; raising it so B's laptop story
   is not silently oversold.

## Next steps / action items

- [ ] Comment on this RFC, especially Option B (multi-root) vs A (single-root +
      extra-attach) given suites are a hard requirement.
- [ ] Spike: sandbox root set — can N roots be enforced without weakening
      `fs_prefixes`? This is the gate for Option B.
- [ ] Spike: default the board room to `ws:<id>` (`#general`) when the selected
      workspace is non-empty, leave `board` for the cwd workspace, confirm the
      existing fold still reads. Also confirm `ws:<id>:goal:<id>` naming against
      the `:` collision question, and that a goal room can be a lossy feed over
      its session.
- [ ] Spike: add `workspace` to `goal_add` / `goal_update` as an optional field
      defaulting to the current rail id.
- [ ] Add a per-workspace membership roster (owner + entered members) as part of
      mesh Phase 3; share / enter / leave / bind are operator verbs on
      `workspace_share`, not new frame kinds.
- [ ] Do not migrate the current `board` room.

## References

- [ADR 0001 — The Kanban board is a chatroom](../adrs/0001-board-is-a-chatroom.md)
- [ADR 0002 — Private run todos vs the shared board](../adrs/0002-private-todos-vs-shared-board.md)
- [ADR 0012 — Goal draft, persistence, and execution are separate](../adrs/0012-goal-draft-persistence-and-execution-are-separate.md)
- [PRD 0001 — Chatrooms](../prds/0001-chatrooms.md)
- [PRD 0002 — Shared Kanban board](../prds/0002-kanban-board.md)
- [PRD 0011 — Clanker mesh](../prds/0011-clanker-mesh.md) (Phase 3
  shared workspaces, home instance, `workspace_share`)
- `src/agent/workspace.zig`, `src/agent/session.zig`,
  `src/cli.zig` (`openWorkspaceRoot`, `workspaceSandboxPath`),
  `src/sandbox/host.zig` (`fs_prefixes`),
  `src/toolhost/manifest.zig` (prefix "relative to the sandbox root"),
  `tools/zig/board.zig`, `tools/zig/add_goal.zig`, `tools/zig/lib.zig`
  (`arena-<id>` rooms)
- Claude Code
  [multi-project workspace issue #47983](https://github.com/anthropics/claude-code/issues/47983)
  — single-cwd agents hit suites and file it as a product gap
- [Repo-of-repos](https://www.raffertyuy.com/raztype/repo-of-repos-pattern/)
  and [multi-repo workspace strategy](https://medium.com/@sunghyunroh/multi-repo-workspace-strategy-the-structure-where-ai-coding-agents-actually-shine-4ed6b87fb11d)
  — prior art for an *outer* object holding many repos
- Eric Ma,
  [cross-repo agents](https://ericmjl.github.io/blog/2025/11/17/how-to-reference-code-across-repositories-with-coding-agents/)
  — operators already attach extra paths by telling the agent; a roots list
  names that instead

## Appendix

### Object relationships (cardinality)

Cardinality reads left → right. The three many-to-many edges are the ones with
a real join record; the rest are foreign keys or derived views.

| Left | Right | Cardinality | Join / where it lives |
|---|---|---|---|
| Instance | Workspace | **N:N** | membership roster on the workspace's home — home owns it, peers enter/leave |
| Instance | Root | **N:N** | bind record: (instance, root) → local checkout path on the member |
| Instance | Room | **N:N** | per-instance subscription (`chatrooms-sub.json`) |
| Workspace | Root | 1:N | `workspace.roots[]` |
| Workspace | Room | 1:N | room namespace: `ws:<id>` (#general) and `ws:<id>:goal:<id>` |
| Workspace | Goal | 1:N | `goal.workspace` |
| Workspace | Session | 1:N | `session.workspace` |
| Room | Board | 1:0..1 | only `#general` folds a board (ADR 0001); goal and fleet rooms do not |
| Board | Card | 1:N | cards are `@todo` messages in the board's room |
| Goal | Card | 1:0..1 | `card.goal` links them; the web UI mirrors a goal to one board card |
| Goal | Room | 1:0..1 | `ws:<id>:goal:<goal-id>`, created on demand, chat/status only |

Fleet rooms (`dm:<a>|<b>`, `ops`) are rooms with no folder, so they map to zero
workspaces — the 0-side of `Workspace : Room`. Session replication is the same
1:N from the home instance to its sessions, with read-only replicas on entered
peers under `state/mesh/<home-id>/sessions/` (PRD 0011), not a second
relationship type.

### User journey — two instances enter and leave a project

```mermaid
sequenceDiagram
    participant Main as instance main (home)
    participant Laptop as instance laptop (peer)

    Note over Main,Laptop: both admitted to the mesh (join already handled)
    Main->>Laptop: share relumea
    Laptop->>Main: enter relumea
    Main-->>Laptop: membership row (home = main)
    Laptop->>Laptop: subscribe ws:relumea + goal rooms
    Main-->>Laptop: replica sessions under state/mesh/main/sessions/
    Laptop->>Main: bind core, web (local checkouts)
    Note over Main,Laptop: laptop sees board, #general, goals, and folders
    Laptop->>Main: leave relumea
    Note over Main,Laptop: drop membership + unsubscribe; home data stays
```

### User journey — local operator starts a goal

```mermaid
sequenceDiagram
    participant Op as Operator (main)
    participant WS as workspace relumea
    participant Goal as Goal loop
    participant GR as ws:relumea:goal:&lt;id&gt;
    participant Gen as ws:relumea (#general)

    Op->>WS: create project (roots core + web)
    Op->>Goal: start goal
    Goal->>GR: create goal room (on demand)
    loop each turn
        Goal->>GR: post model output
        Goal->>Gen: update board card
    end
    Goal->>Gen: card moved to Done
```

Same picture, two processes on one host. Loopback is the address; nothing else
changes. The home process is always a member of its own workspaces — no local
join — and a second process on the same box enters exactly like a remote one.

```
instance "main"                         instance "side"
  [instance] id = "main"                  [instance] id = "side"
  [mesh] listen_port = 7420               [mesh] listen_port = 7421
  [serve] webui_port = 17921              [serve] webui_port = 17922
  [agent] state_dir = "state"             [agent] state_dir = "state-side"

from side:  mesh join 127.0.0.1:7420
from main:  share relumea
from side:  enter relumea
            bind core /home/maci/Desktop/Projects/relumea-core
            bind web  /home/maci/Desktop/Projects/relumea-web
```

Starting a second serve in the same checkout with no private `state_dir` is not
this. That is two processes on one instance.

### Operator disk (why the drawer is not a project)

```
~/Desktop/7dtd                  project (roots: game + tools)
~/Desktop/Projects/             drawer, never a project
  relumea/                      (folder only if it has a repo of its own)
  relumea-core/                 root of project "relumea"
  relumea-web/                  root of project "relumea"
  other-app/                    project with one root
```

The project is `relumea`, not `relumea-core` + `relumea-web` opened separately
and not the `Projects/` drawer. A leaf (`other-app`) is a project with one root
— the same shape, no special case.

### Who can share or enter

| Process | Mesh member? | Can share / enter a workspace? |
|---|---|---|
| Another `clanker serve` (other machine or same host) | after admit | yes, same frames |
| `clanker run` / REPL / `clanker mesh …` | no (loopback client of local serve) | no |
| Subagent / swarm child | no (same process) | no |
| Foreign A2A agent | no | no |
| ACP editor | no | no |
