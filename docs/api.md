# HTTP API

`clanker serve` binds one socket (`--webui-port`, default 17921) and mounts
three surfaces on it:

| Surface | Mounted at | Enabled by |
|---|---|---|
| Web UI + agent API | `/` , `/webui/*`, `/api/*` | always (unless `--proxy-port` moves the proxy to its own socket) |
| OpenAI/Anthropic compat proxy | `/proxy/v1/*` | `[serve] proxy = true` or `--proxy` |
| Liveness/readiness | `/health/live`, `/health/ready` | always |

`--proxy-port <n>` opens a second socket that carries the proxy at `/v1/*`
and nothing else. `--host` sets the address, `--serve-as` the extra Host
names a reverse proxy or tailnet name may use; see `clanker serve --help`.

The route table is `handleConnection` in `src/cli.zig`. This page is a
reference for it, not a substitute: every entry below was read off that
chain and its handler.

## Conventions

**Content type.** Every `/api/*` response is `application/json`, including
errors. The web UI index and its assets answer HTML and `text/javascript`, and
the two streaming routes answer `text/event-stream`. A `HEAD` answers the
headers its `GET` would, with `Content-Length` and no body.

**Success envelope.** `{"ok":true, ...}`. List routes add their own array or
object key beside it (`{"ok":true,"goals":[...]}`, `{"ok":true,"last_seq":N}`).

**Error envelope.** `{"ok":false,"error":"<what the caller did wrong>"}`.
The string is stable prose meant for a human; branch on the status code, not
on the text. Some refusals carry extra keys beside `error` (a cursor gap
carries `gap`, `have`, `need`), never instead of it.

**Status codes.**

| Code | Meaning here |
|---|---|
| 400 | malformed body, missing or invalid field, unparseable query value |
| 403 | cross-origin request, a Host this listener does not answer to, editing or deleting another sender's chat message, a dotenv path, or a path with a symlinked component |
| 404 | no such route, no such resource, or the owning module is disabled |
| 405 | the path exists but not with this method; the `Allow` header lists the methods it does take |
| 409 | a conflict the caller can resolve (duplicate workspace, cursor gap) |
| 413 | request body or a `path` query value over the cap |
| 421 | the `Host` header names a different listener |
| 429 | a per-run steer queue is full |
| 500 | the server's own failure (a guest tool missing, state unreadable) |
| 502 | a model catalog could not be fetched: `POST /api/catalog/refresh` could not reach models.dev, or `GET /api/providers/models` got no answer or non-JSON from the provider |
| 503 | the connection pool is saturated; `request_status` is recorded as 0 |

**Path matching.** A route that owns sub-paths claims the prefix and
everything under a `/` (`/api/runs`, `/api/runs/run-1`), never a longer
sibling name: `/api/runsfoo` is a 404, not a run listing. A suffix that is
not one of the sub-paths below is also a 404, never silently ignored.

**Module gates.** Most routes answer `404 {"error":"<x> module disabled"}`
when the matching `[modules]` key is off, rather than running a
half-configured path.

**Auth.** The web-UI and agent API have no per-request auth: whoever reaches
the socket can call them, including `/api/run`, which executes agent tools.
That is why the default bind is `127.0.0.1` and why `--host 0.0.0.0` is
called out in `clanker serve --help`. The proxy is the one surface with an
optional bearer token (`[serve] proxy_token_env`, naming the env var that
holds it); with that set it answers 401 on a missing or wrong one, and with
it unset or naming an unset variable the proxy serves unauthenticated.

**Body parsing.** Unknown fields are ignored, not refused. A field that is
present but the wrong type is a 400.

**Method refusal.** A `405` carries the RFC 9110 `Allow` list of the methods
that path does take, so a client learns the verbs from the refusal rather than
probing for them.

## Health

| Method | Path | Notes |
|---|---|---|
| GET | `/health/live` | `{"ok":true,"status":"live"}` |
| GET | `/health/ready` | `{"ok":true,"status":"ready","in_flight":N,"connection_limit":M}`, 503 once `in_flight` reaches the limit |

## Agent

| Method | Path | Body / query | Notes |
|---|---|---|---|
| POST | `/api/run` | see below | streams the answer when `stream:true` |
| POST | `/api/ask` | `{id, answer}` | answers a pending `ck_ask` question |
| POST | `/api/steer` | `{goal?, session?, message}` | 404 when no run is working that key, 429 when the queue is full |
| GET | `/api/status` | | server status the web UI polls |
| GET | `/api/metrics` | | JSON counters (`http`, `live`, `llm`, `tools`, `schedule`, `jobs`, `subagents`, `mesh`) |

`POST /api/run` accepts `task` (or `goal` alone), `stream`, `session`,
`goal`, `worktree`, `images`, `provider`, `model`, `fallback_provider`,
`temperature`, `top_p`, `reasoning_effort`, `backend`, `plan`, `research`,
`max_iterations`, `knowledge`, `workspace`. A `task` beginning `/goal `
opens a goal loop. An unknown `reasoning_effort`, `backend`, `session` or
`workspace` is a 400, never a silent default. Streaming responses are
`text/plain`; control lines are prefixed with `\x01` and carry JSON.

## Sessions

Module gate: `sessions`. Ids are 1-64 characters of `[A-Za-z0-9_-]`.

| Method | Path | Notes |
|---|---|---|
| GET | `/api/sessions` | header-only listing the picker consumes |
| GET | `/api/sessions/search?q=` | full text over transcripts |
| GET | `/api/sessions/<id>` | one session |
| POST | `/api/sessions` | `{import_chat:true, title?, messages:[{role,content}]}` |
| POST | `/api/sessions/<id>` | `{title?, workspace?, archived?}`; `import_chat` and `messages` are read only on the collection POST above, and a body carrying only those is a 400 naming the three fields this route takes |
| DELETE | `/api/sessions/<id>` | also forgets the session's spills and export |
| POST | `/api/sessions/<id>/fork` | `{"ok":true,"id":"<new>"}` |
| POST | `/api/sessions/<id>/compact` | `{"ok":true,"bytes":N}` |
| POST | `/api/sessions/<id>/branch/<n>` | cut at turn n |
| GET | `/api/sessions/<id>/events` | mesh event tail, `?after=<seq>` |
| POST | `/api/sessions/<id>/events` | `{owner, events}`; 409 on a cursor gap |

## Workspaces

A workspace is a named project folder (ADR 0020). Path ids are 1-64
characters with no `/`, `\` or `:`; an empty id is only ever a value, naming
the default workspace.

| Method | Path | Body |
|---|---|---|
| GET | `/api/workspaces` | list |
| POST | `/api/workspaces` | `{name, path}` or `{name, roots}` |
| GET | `/api/workspaces/<id>` | one |
| POST | `/api/workspaces/<id>` | `{name?, path?, roots?}` |
| DELETE | `/api/workspaces/<id>` | dangling session pointers are cleared |

## Goals, board, workflows

| Method | Path | Notes |
|---|---|---|
| GET | `/api/goals` | `{"ok":true,"goals":[...],"running":[ids]}` |
| POST | `/api/goals` | add or update a goal record |
| GET/POST | `/api/board` | the shared Kanban board; GET lists, POST takes the tool input verbatim |
| GET | `/api/workflows` | workflow definitions |

Module gate: `goal` on `/api/goals` only. `/api/board` and `/api/workflows`
carry no gate.

## Knowledge and prompts

| Method | Path | Notes |
|---|---|---|
| GET | `/api/knowledge` | list collections |
| POST | `/api/knowledge` | `{title, description}` |
| GET | `/api/knowledge/search?q=&collections=a,b` | |
| GET | `/api/knowledge/<id>` | one collection |
| DELETE | `/api/knowledge/<id>` | |
| POST | `/api/knowledge/<id>/docs` | `{name, content}` |
| DELETE | `/api/knowledge/<id>/docs/<doc>` | |
| POST | `/api/knowledge/<id>/sync` | `{path, prune?}`; host-side folder mirror |
| GET | `/api/prompts` | |
| POST | `/api/prompts` | |
| DELETE | `/api/prompts` | |

`/search` is an exact action segment, not a prefix: a collection may be named
`searches`.

## Schedule, arena, compare

| Method | Path | Notes |
|---|---|---|
| GET | `/api/schedule` | list |
| POST | `/api/schedule/<id>` | `{enabled}` |
| GET | `/api/arena` | list matches |
| GET | `/api/arena/<id>` | one match |
| GET | `/api/compare` | blind listing (`reveal:false`) |
| GET | `/api/compare/<id>` | one comparison, still blind |
| POST | `/api/compare/<id>` | `{pick}`: the label of one of that comparison's answers; a POST to the collection is 405 |

## Runs and graphs

Module gate: `graphs`. Run ids are `run-<digits>` or `sub-<digits>`.

| Method | Path | Notes |
|---|---|---|
| GET | `/api/runs` | newest-first listing (capped) |
| GET | `/api/runs/<id>` | one run graph |

## Providers and catalog

| Method | Path | Notes |
|---|---|---|
| GET | `/api/providers` | each row gains a native `usable` / `reason` annotation |
| GET | `/api/providers/models?name=<provider>` | 502 when the provider's `/models` does not answer or answers non-JSON |
| GET | `/api/catalog?q=` | models.dev search, at least 2 characters |
| POST | `/api/catalog/refresh` | refetch; 502 when models.dev is unreachable |

`GET /api/catalog/refresh` is a 404: the segment is a POST action, not a
search for a model named "refresh".

## Config

| Method | Path | Body / query |
|---|---|---|
| GET | `/api/config/status` | `{"ok":<bool>,"error":"...","checked_ts_ms":N}` |
| GET | `/api/config/raw?file=config.toml` | `config.toml` or `config.local.toml` only |
| POST | `/api/config/raw` | `{file, content}`, validate-then-write |
| POST | `/api/config/model` / `/set` / `/remove` | |
| POST | `/api/config/default` | |
| POST | `/api/config/table/set` / `/remove` | |

## Plugins, skills, themes

| Method | Path | Notes |
|---|---|---|
| GET/POST | `/api/plugins` | |
| POST | `/api/plugins/config` | `{name, config}` |
| GET/POST | `/api/skills` | |
| GET/POST | `/api/webui/plugins` | |
| GET | `/webui/plugins/<name>/app.{js,css}` | served from disk |
| GET | `/webui/themes/<name>.{json,css}` | |
| GET | `/webui/commands/...` | |

## Records

One relay endpoint per store: `/api/reports`, `/api/rfc`, `/api/adr`,
`/api/prd`, `/api/research` (ADR 0019). `reports` covers `docs/reports/`
and `docs/runbooks/`. Reads take `?action=`, writes take the same action in
the body; pairing a read action with POST (or the reverse) is a 400 naming
the method the action wanted. Writes land in `docs/`. No HTTP action leaves
the process: `sweep` is refused here with a 400 and exists only as
`clanker research sweep`. See
`clanker reports --help` for the per-store action list.

## Peers, mesh and chat

Module gates: `peers` and `chatrooms` across this section, plus `mesh`
on the four `/api/mesh/` routes below `/api/mesh/map` (which is served
even with `mesh` off). Those four answer `"modules.mesh is off; set it and
restart serve"`, not the `<x> module disabled` form above.

| Method | Path | Notes |
|---|---|---|
| GET | `/api/peers` | phonebook rows: `name`, `url`, `status` (`up`/`down`), `card_name`, `description`, `skills`, `error` |
| GET | `/api/mesh/map` | self, `[[peers]]` and chat wires; served even with `mesh` off |
| GET | `/api/mesh/status` | |
| POST | `/api/mesh/join` / `/leave` | `{address}` / `{peer_id}` |
| GET/POST | `/api/mesh/pending` | list or answer (`{id, allow}`) |
| GET | `/api/chat/rooms` | room stats plus this instance's subscriptions |
| GET | `/api/chat/messages?room=&after=` | room history, `room` required |
| POST | `/api/chat/message` | inbound peer delivery |
| POST | `/api/chat/send` | this instance speaking |
| POST | `/api/chat/subscribe` | join or leave a room |
| POST | `/api/chat/react` / `edit` / `delete` / `pin` / `topic` | |
| GET | `/api/chat/pins` | |

## Live events

| Method | Path | Notes |
|---|---|---|
| GET | `/api/events?topics=chat,mesh,plugin` | SSE; 403 on a cross-origin request; keep-alive opted out. Also accepts `arena`, `run` and `metrics` |
| POST | `/api/live` | publish; `ck_publish` is the guest equivalent |

## Files, logs, misc

| Method | Path | Notes |
|---|---|---|
| GET | `/api/files?path=&workspace=` | native file browser; dotenv files are refused and hidden |
| GET | `/api/logs` , `/api/logs/<name>` | `state/logs/` only |
| GET | `/api/janitor` | dry-run scan only; nothing is deleted |
| GET | `/api/stats` | token usage aggregate (module `token_stats`) |
| GET | `/api/mcp/servers` | names only, values redacted |
| GET | `/api/feedback` , POST | |
| POST | `/api/notify` | peer notification delivery |

## A2A

Module gate: `a2a`.

| Method | Path |
|---|---|
| GET | `/.well-known/agent.json` |
| POST | `/api/a2a/message` |

`POST /api/a2a/message` is JSON-RPC 2.0 and answers a JSON-RPC object
(`{"jsonrpc":"2.0","id":...,"result":...}`), so its refusals are the API
envelope above rather than JSON-RPC error objects. A request with no `method`,
or with a `jsonrpc` other than `"2.0"`, is a 400. Every other method name is
answered the same way: the agent runs and its message comes back.

The `id` is the request's idempotency key, because the work behind it is a full
agent run. A repeat of an id that already completed inside the window returns
the stored reply with `200` instead of running the agent again; a repeat of an
id whose first run is still in flight is a `409` with a JSON-RPC error object
(`{"code":-32000}`); a run that failed releases its id, so the peer's retry
starts a new one. An `id` of `null`, or one that is not a string or an integer,
is not deduplicated. The window and the table size are
`src/serve/a2a_reply_cache.zig`.

## Proxy

`/proxy/v1/*` forwards to the configured provider 1:1, in the shape of
`src/serve/proxy.zig`. `/v1/*` on a dedicated `--proxy-port`. See
`docs/configuration.md` for the `[serve]` proxy keys (`proxy`, `proxy_port`,
`proxy_token_env`, `proxy_aliases`). The proxy is native: it attaches
credentials and never routes a request through the agent loop.
