# Plugin manifest reference

A clanker plugin is two files: a WebAssembly module and a `*.tool.json`
manifest that describes it. The module implements the behaviour; the manifest
is the whole of what the harness knows about it — the name and description the
model reads, the JSON Schema for its arguments, and the sandbox policy the host
enforces on every call.

Loader: `src/toolhost/registry.zig` (`Registry.load` / `parseDescriptor`).
Schema and validator: `src/toolhost/manifest.zig`.
Checker: `clanker plugins validate [path]`.

```sh
clanker plugins new word_count          # scaffold a manifest + a Zig guest
zig build tools                         # compile it to zig-out/tools/word_count.wasm
clanker plugins validate                # check every manifest in agent.tools_dir
```

## Versioning

| | |
|---|---|
| Key | `manifest_version` |
| Type | integer |
| Current | `1` |
| Default | `1` |

A manifest with no `manifest_version` is version 1. Every manifest written
before the key existed is therefore a valid v1 manifest, which is why the
default is what it is and why it will not change.

A version this build does not understand is **refused, not downgraded**:
`parseDescriptor` returns `error.UnsupportedManifestVersion`, the loader logs a
warning naming the file, and the tool is not registered. Reading a v2 manifest
under v1 rules would mean loading a tool whose sandbox policy is not the one its
author wrote, which is the one failure mode a version key exists to prevent.

## Required fields

| Key | Type | Meaning |
|---|---|---|
| `name` | string | What the model writes to call the tool. Lowercase letters, digits and underscores only. Also the registry key, so it must be unique across the tools directory |
| `description` | string | Human-facing description — what a person reads in the web UI's Tools view or the REPL's tool detail. The model only ever sees it as the loader's fallback when `llm_description` is absent |
| `llm_description` | string | Optional compressed variant of `description`, sent to the model instead of it. Its first line (up to 160 characters) is what the catalog shows, and the catalog line is paid on nearly every request, so a long human-facing `description` costs tokens every turn; this is where you keep the short one. Omitted, the loader falls back to `description`, so an unmigrated manifest still works — just not as cheaply |
| `prompt_guidance` | string | Optional binding usage rules for this tool. Injected into the system prompt's `## Tool guidance` section (one `### name` block per declaring tool, ahead of the catalog) whenever the tool is enabled and non-internal, and echoed as `guidance` in the `load_tools` reply so a model that just loaded the tool reads the rules at the moment of use. For workflow constraints the model must follow — the descriptions say what the tool does, this says how it must be used |
| `wasm` | string | The module. See [Where the module lives](#where-the-module-lives) |

`input_schema` is not strictly required, but a manifest without one tells the
model the tool takes no arguments, so the validator warns.

## Schema

| Key | Type | Meaning |
|---|---|---|
| `input_schema` | object | JSON Schema for the tool's arguments. `"type": "object"` is filled in if absent |
| `parameters` | object | OpenAI's spelling of `input_schema`, accepted for compatibility. `input_schema` wins if both are present |

The type matters more than it looks: Anthropic rejects a request whose tool
list contains a schema with no `type`, and it rejects the *entire* request — one
malformed manifest breaks every tool call for every tool. `normalizedSchema`
defaults the type rather than shipping a request no provider will take, and the
validator treats a `type` that is not `"object"` as an error.

## Sandbox policy

Everything a plugin may reach is denied unless the manifest names it. There is
no ambient authority: a manifest with none of these keys is a pure function over
its arguments.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `fs_prefixes` | string[] | `[]` | Directory prefixes, relative to `agent.sandbox_root`, this tool may read and write through `ck_fs_*`. Empty means no filesystem at all. There is no read-only grant: a prefix carries write access. For a multi-root workspace, a relative guest path whose first component names one of the project's roots resolves under that root; the same prefix grant is checked against the remainder, so the prefix list itself is unchanged |
| `network_allow` | string[] | `[]` | Hostnames this tool may reach through `ck_http`. Each entry is an exact hostname or a glob (`*.github.com`, and a bare `*` allows every host). No scheme, no path, no port |
| `network_from_config` | string | `""` | `"peers"` or `"providers"`: the harness appends those configured hosts to `network_allow` at load, because a manifest cannot know what is in someone's `config.toml` |
| `exec_allow` | string[] | `[]` | Commands this tool may run through `ck_exec`, compared against `argv[0]` **exactly**. Empty is not "the harness default set" — it is no exec at all |
| `env_allow` | string[] | `[]` | Environment variables this tool may read. Empty means the safe defaults in `host.zig`, never the whole process environment: that is where the API keys are |
| `fuel` | integer | sandbox default | Instruction budget for one call. See below |
| `llm` | bool | `false` | May call the model through `ck_llm` / `ck_llm_many`. Costs tokens, so it is opt-in, and it forces the tool onto the sequential execution path |
| `live_publish` | bool | `false` | May emit onto the serve live bus through `ck_publish`. The import existing is not a grant. Events land on `Topic.plugin` only; the host stamps `t` and `from`. Forces the sequential path: the bus is host-shared state |
| `tool_call` | bool | `false` | May call other tools through `ck_tool`. Only tools that call others need it — as shipped, `chain` (the tools it wraps), `run_plan` (a bounded step list), `bugreport` (`kanban_add`), and `goal_write` (`ask_user`) |
| `tool_allow` | string[] | all | With `tool_call`, which tool names it may invoke. Absent or empty means every enabled non-internal tool. Ignored entirely without `tool_call` |
| `confirm` | bool | derived | Ask the human before running, when a confirm channel is installed (`agent.confirm_writes`). Unset, it is derived from the grants: any tool with `exec_allow` or `fs_prefixes` is a write in a viewer's eyes. A read-only tool opts out with `false`; a tool whose risk its grants understate opts in with `true` |

### Fuel

The sandbox gives every call 10,000,000,000 instructions. A manifest's `fuel`
is clamped to that as a **ceiling**, so a descriptor can tighten its own budget
and can never raise it (`runtime.zig`'s `fuelBudget`). `calculator` ships with
`100000000` as the demonstration.

`0` is the loader's "unset", so writing it does not ask for the default — it is
a mistake the validator names. A value above the ceiling is an error rather
than a silent clamp: the clamp is not in question, the manifest's claim about
itself is.

## Behaviour flags

| Key | Type | Default | Meaning |
|---|---|---|---|
| `internal` | bool | `false` | Hidden from the model's tool catalog. Used by the `cmd_*` slash commands, the web UI, and transforms — reachable through a REPL command or an HTTP route, never chosen by the agent |
| `enabled` | bool | `true` | The manifest's own default on/off state. Ships `false` for anything that spends tokens unasked. `state/plugins.json` overrides it either way |
| `sequential` | bool | `false` | Never runs on the parallel worker pool. For tools over host-shared state (the chatroom log) — each call waits its turn on the main thread |
| `check` | bool | `false` | This tool answers pass/fail about something (a gate, an eval, a lint). Its verdict is recorded in the run graph as a check |
| `statusline` | bool | `false` | Contributes a segment to the REPL status line, invoked with empty input after each turn. Pair with `"internal": true` |
| `turn_hook` | bool | `false` | Runs once after each REPL turn and may print a line into the transcript. Pair with `"internal": true` |
| `category` | string | `""` | Grouping key for `clanker tools list` and the web UI's Tools panel. Read by the `tools` and `plugins` guests, not by the registry. Empty is rendered as `other`. Known groups: `agent`, `chat`, `code`, `compute`, `harness`, `kanban`, `knowledge`, `media`, `transform`, `web`, `other`. A name prefix matches its group (`chat_*` in `chat`, `kanban_*` in `kanban`, `todo_*`/`goal_*`/`skill_*` in `agent`, `note_*` in `knowledge`, `session_*` in `harness`, `zig_*` in `code`, `web_*` in `web`; `webui*` is harness and is not `web_*`). Multi-op families use `noun_verb` (`kanban_add`, `goal_write`, `note_write`, `web_fetch`). Standalone file verbs stay `verb_noun` (`read_file`, `edit_file`). Inspectors are a bare noun (`sessions`, `config`, `providers`, `learnings`). `knowledge` is notes, memory, research, rfc, reports, roadmap. `clanker plugins validate` warns on an unknown string or a prefix in the wrong group so a typo does not silently invent a one-tool section |

## Settings

| Key | Type | Default | Meaning |
|---|---|---|---|
| `config` | object | `{}` | Free-form per-plugin settings, handed to the guest verbatim through `ck_config` |
| `config_editable` | string[] | `[]` | Which `config` keys may be changed at runtime, from the web UI or `state/plugin_config.json` |

The harness reads exactly three keys out of `config` for itself — `provider`,
`model` and `max_tokens` — to aim `ck_llm` at a specific backend. Everything
else reaches the guest untouched.

`max_tokens` is the grant, and a guest may only lower it (`clampCkLlmMaxTokens`
takes the smaller of the request and the grant), never raise it: otherwise a
confused or injected tool call bills an unbounded completion against the
operator's key.

**Size it for a model that reasons, not for the answer.** `max_tokens` bounds
*output*, and on a reasoning model the reasoning trace is output: the provider
fills `reasoning_content` first and only then emits `content`. A grant sized
for the answer alone is spent before a visible token exists, and the provider
still answers 200 — empty `content`, `finish_reason: "length"` — so the guest
sees an empty string and reports that the model said nothing. The floor is
`reasoning_headroom` in [`tools/zig/llm_budget.zig`](../tools/zig/llm_budget.zig)
(4096 tokens on top of the content budget), and `toolDescriptorGate` fails any
`"llm": true` descriptor that grants less. Capabilities cannot be used to
decide this: `Model.capabilities` is filled from the models.dev snapshot and is
empty on any checkout that has not run `clanker providers refresh`.

The ceiling is not a bill — the grant caps what a call *may* generate, not what
it does. Measured on `deepseek-v4-pro`, the effort classifier spends 95 tokens
against its 4096 grant.

Omitting the key is a different statement from setting a small one. A
descriptor with `"llm": true` and no `config.max_tokens` falls back to the host
default and is not claiming a budget — `providers` pings with `max_tokens: 1`
and ignores the completion entirely, and `rlm`, `subagent` and `swarm` reach a
model through `ck_subagent`/`ck_swarm`, whole agent turns the harness budgets.

Editability is opt-in per key on purpose. A plugin's config is often
structural, not tunable: the nine `chat_*` descriptors share one `chat.wasm` and
select their behaviour with `"op"`, so letting a machine-local override reach
that key would turn `chat_send` into `chat_rooms`. Only the tool knows which of
its settings are safe to change, so only the tool declares them.

## Transforms

A transform plugin wraps other tools instead of being called by the model.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `transform.phase` | string | required | `"before"` (rewrite the arguments going in) or `"after"` (rewrite the result coming out) |
| `transform.tools` | string[] | `["*"]` | Which tools it wraps. `"*"` is all of them |
| `transform.order` | integer | `0` | Ascending; lower runs first. A transform never wraps itself or another transform |

Pair a transform with `"internal": true`: it is not a tool the model calls. It
stays switchable through `/plugins` anyway — being able to turn a filter off is
the whole point of it.

## Where the module lives

`wasm` is resolved by `Registry.resolveWasmPath` at load:

| Form | Resolved against | Example |
|---|---|---|
| Contains `/` | the process's working directory | `zig-out/tools/calculator.wasm`, `tools/ts/dist/calc_ts.wasm` |
| Bare filename | the manifest's own directory | `word_count.wasm` beside `word_count.tool.json` |

Every in-tree manifest uses the first form, because the harness runs from the
repo root and the build output is at a known path from there. The second form
exists for plugins that do not live in this repo: a directory someone unpacked
has no idea what clanker's working directory will be, so a self-contained
`{name.tool.json, name.wasm}` pair is the portable shape.

## Distributing a plugin

A plugin package is a directory holding a manifest and the module it names:

```
my-plugin/
├── word_count.tool.json     "wasm": "word_count.wasm"
└── word_count.wasm
```

Check it, then point clanker at it:

```sh
clanker plugins validate ./my-plugin
```

```toml
# config.local.toml
[agent]
tools_dir = ["tools/manifests", "./my-plugin"]
```

A later-listed directory wins on a tool `name` collision, so put overrides
last. A bare string still works and still means one directory.

One remaining limit, deliberate rather than unfinished:

- **There is no trust story.** Nothing is fetched, verified, signed, or
  attributed. A manifest is a local file you are expected to have read, and its
  sandbox policy is the only thing standing between the module and your
  machine — so read the policy before you point `tools_dir` at it, the same way
  you would read a shell script before running it. See
  [ADR 0007](adrs/0007-plugin-manifests-are-declarative-and-unsigned.md).

## Validation

`clanker plugins validate [path]` checks one manifest or every `*.tool.json` in
a directory (default: `agent.tools_dir`). It exits non-zero if anything is an
error, so it can guard a release script.

The loader is deliberately forgiving — one bad manifest must not take the other
ninety down with it — so an unknown key, a dead grant, or a fuel budget above
the ceiling all load without complaint and quietly do nothing. That is the class
of bug the validator exists to name:

```
tools/manifests/thing.tool.json: warning: fs_prefix: unknown key; the loader ignores it, so it grants and configures nothing
tools/manifests/thing.tool.json: error: exec_allow: "/bin/sh -c" must be a bare command name: the gate compares argv[0] exactly, so a path or an argument never matches
```

**Errors** mean the loader will refuse the manifest, or accept it and do
something other than what it says: a missing required field, a wrong type, a
grant the sandbox cannot express, a schema no provider will take, a fuel budget
above the ceiling, an unsupported `manifest_version`.

**Warnings** mean it loads but a key does nothing: an unknown key, `tool_allow`
without `tool_call`, `statusline`/`turn_hook`/`transform` without `internal`, a
`config_editable` entry naming a key that is not in `config`, a `wasm` that is
not on disk yet.

Two checks need more than the manifest's own bytes, and run when the
surrounding files are there: whether the module exists, and whether a guest
source file that calls the model declares `llm`. The second is the same rule
`registry.zig`'s conformance test enforces for this repo — an undeclared model
caller runs on the parallel worker pool and races the shared access-token cache,
which surfaces as a crash in somebody else's tool.

## A complete example

```json
{
  "manifest_version": 1,
  "name": "word_count",
  "description": "Count the words in a string. Input {\"text\": \"a b c\"}, returns {\"ok\": true, \"count\": 3}.",
  "wasm": "zig-out/tools/word_count.wasm",
  "input_schema": {
    "type": "object",
    "properties": {
      "text": { "type": "string", "description": "The text to count." }
    },
    "required": ["text"]
  },
  "network_allow": [],
  "fs_prefixes": [],
  "fuel": 50000000,
  "category": "compute"
}
```

The guest side of that pair is the Tool ABI in
[docs/README.md](README.md#wasm-tool-abi): export `scratch`, `host_arena` and `run`,
import the `env.ck_*` host functions. `tools/zig/lib.zig` wraps all of it for a
Zig guest, and `clanker plugins new` writes a working one.
