# Plugin manifest reference

A clanker plugin is two files: a WebAssembly module and a `*.tool.json`
manifest that describes it. The module implements the behaviour; the manifest
is the whole of what the harness knows about it — the name and description the
model reads, the JSON Schema for its arguments, and the sandbox policy the host
enforces on every call.

Loader: `src/tools/registry.zig` (`Registry.load` / `parseDescriptor`).
Schema and validator: `src/tools/manifest.zig`.
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
| `description` | string | What the model reads to decide whether to call it. The first line (up to 160 characters) is what the catalog shows; the rest is only seen once the schema is loaded, so put the *what* first and the argument detail after |
| `llm_description` | string | Optional compressed variant of `description`, sent to the model instead of it. The catalog line is paid on nearly every request, so a long human-facing `description` costs tokens every turn; this is where you keep the short one. Omitted, the loader falls back to `description`, so an unmigrated manifest still works — just not as cheaply |
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
| `fs_prefixes` | string[] | `[]` | Directory prefixes, relative to `agent.sandbox_root`, this tool may read and write through `ck_fs_*`. Empty means no filesystem at all. There is no read-only grant: a prefix carries write access |
| `network_allow` | string[] | `[]` | Hostnames this tool may reach through `ck_http`. Each entry is an exact hostname or a glob (`*.github.com`, and a bare `*` allows every host). No scheme, no path, no port |
| `network_from_config` | string | `""` | `"peers"` or `"providers"`: the harness appends those configured hosts to `network_allow` at load, because a manifest cannot know what is in someone's `config.toml` |
| `exec_allow` | string[] | `[]` | Commands this tool may run through `ck_exec`, compared against `argv[0]` **exactly**. Empty is not "the harness default set" — it is no exec at all |
| `env_allow` | string[] | `[]` | Environment variables this tool may read. Empty means the safe defaults in `host.zig`, never the whole process environment: that is where the API keys are |
| `fuel` | integer | sandbox default | Instruction budget for one call. See below |
| `llm` | bool | `false` | May call the model through `ck_llm` / `ck_llm_many`. Costs tokens, so it is opt-in, and it forces the tool onto the sequential execution path |
| `tool_call` | bool | `false` | May call other tools through `ck_tool`. Only `chain` needs it |
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
| `category` | string | `""` | Grouping label for `clanker tools list` and the web UI's tool panel. Read by the `cmd_tools` and `cmd_plugins` guests, not by the registry. Empty is rendered as `other` |

## Settings

| Key | Type | Default | Meaning |
|---|---|---|---|
| `config` | object | `{}` | Free-form per-plugin settings, handed to the guest verbatim through `ck_config` |
| `config_editable` | string[] | `[]` | Which `config` keys may be changed at runtime, from the web UI or `state/plugin_config.json` |

The harness reads exactly three keys out of `config` for itself — `provider`,
`model` and `max_tokens` — to aim `ck_llm` at a specific backend. Everything
else reaches the guest untouched.

Editability is opt-in per key on purpose. A plugin's config is often
structural, not tunable: the four `chat_*` descriptors share one `chat.wasm` and
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
| Contains `/` | the process's working directory | `zig-out/tools/calculator.wasm`, `tools/bin/calc_ts.wasm` |
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
tools_dir = "./my-plugin"
```

Two honest limits on that today, both deliberate rather than unfinished:

- **`agent.tools_dir` is one directory, not a list.** Pointing it at a plugin
  package replaces the built-in tools rather than adding to them. Installing a
  third-party plugin into a working clanker means copying its two files into
  `tools/manifests/` and wherever its `wasm` points.
- **There is no trust story.** Nothing is fetched, verified, signed, or
  attributed. A manifest is a local file you are expected to have read, and its
  sandbox policy is the only thing standing between the module and your
  machine — so read the policy before you copy the files, the same way you would
  read a shell script before running it. See
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
[docs/README.md](README.md#tool-abi): export `scratch`, `host_arena` and `run`,
import the `env.ck_*` host functions. `tools/zig/lib.zig` wraps all of it for a
Zig guest, and `clanker plugins new` writes a working one.
