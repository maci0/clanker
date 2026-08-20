# Digest: Cordis — A Programming Paradigm for Spatiotemporal Composability

Source: <https://github.com/cordiverse/paper/blob/main/paper.pdf> (Shi, Zhang, Cui —
Peking University + DeepSeek-AI), read at depth on 2026-08-20. The formal foundation
under DeepSeek Harness's "everything is a plugin": it lifts classical effect and
coeffect systems to runtime mechanisms so components can be mounted, reverted, and
recomposed *while the system runs*, with a calculus whose metatheory guarantees the
result. The paper explicitly names **self-evolving agent harnesses** as its target
future validation (Section 1.2.2, Conclusion) — which is exactly what clanker's
improve-self loop is.

## What it actually is

Two orthogonal composability dimensions, each given a runtime mechanism, unified into
one context type, and assembled into a component calculus:

1. **Temporal composability — revertible effects (Section 3.1).** Every context
   mutation flows through one primitive, `ctx.effect(callback)`; the callback yields
   an *inverse* for each step, the runtime folds those inverses LIFO into a dispose
   closure, and removing a component runs its dispose — recovering the context exactly.
   Tracking and recovery preserve composition, so "the context is recovered upon
   component removal" (Theorem 61, Corollary 62: a departing fiber's contribution is
   nothing).
2. **Spatial composability — reactive coeffects (Section 3.2).** A component declares
   the context it *requires* as a specification; on every context change the runtime
   notifies it — activating, deactivating, or neutral — with isolation (realms) and
   interception varying what a key resolves to and how it is used. A dependency
   constrains *when* a fiber activates, never *whether* its module loads.
3. **One context type (Section 3.3).** Effect context and coeffect context are the same
   `Γ`; an observational equivalence on coeffects gives effects their independence.
4. **A calculus of dynamic composition (Section 4).** A component is a fiber
   (lifecycle: LOADING → ACTIVE → UNLOADING, FAILED as inactive) whose instantiation
   and retirement are the only ways the context changes. Metatheory carries the two
   guarantees from one component to a whole interleaved system (preservation;
   quiescent state is a function of the *final* configuration alone — Theorem 73 — so
   reconciliation is order-independent).
5. **Cordis implementation (Section 5).** A core library (effect tracking with a LIFO
   accumulator, coeffect resolution, fiber lifecycle) plus a **declarative component
   loader**: a configuration *tree* of entries (`id, url, isolate, intercept, config,
   disabled`); the loader diffs an entry's fields and applies the least disruptive
   operation per change (rebuild on id/url, reload on disabled, in-place on intercept);
   **hot module replacement** that disposes the old fiber and instantiates a new one —
   no developer-annotated acceptance boundaries needed. Service multiplexing (Section
   6.2): a service broker lets multiple providers coexist (load balancing, rolling
   updates, cross-process invocation). System boundary (Section 6.1): what the system
   can exclusively modify and restore is *inside* (tracked, revertible); emissions that
   cross to the outside are only *compensated* (deleted/refunded), composing LIFO.
   Validated by Koishi, a production system with 4000+ community plugins.

## What is worth applying to clanker

### 1. Revertible effects → the tool registry's off-switch

clanker can *disable* a tool (`/plugins off <name>`, `state/plugins.json`) but
disabling is a registry reload, not an effect revert: registrations the tool made —
transform-chain membership, live-bus topics, `ck_tool` reachability, config keys —
are not systematically un-installed. The paper's pattern is: every registration
returns a dispose; disable runs the disposers LIFO. For clanker this means giving the
registry a per-tool `unregister`/dispose path so `/plugins off` (and a preset switch
that drops a tool) reverts what the tool installed, not just hides it from the model.

### 2. Reactive coeffects → dependency-aware activation for tool→tool calls

clanker already declares tool→tool calls declaratively (`tool_call` +
`tool_allow` in the manifest, used by `chain`). Today a tool whose dependency is
disabled fails at call time. The paper's model: a dependent tool is *deactivated*
(waits at L-Begin) while its provider is absent, and re-activated when it returns —
`/plugins` could list dependents that went inactive. This is the same shape the
fallback provider chain (PRD 0025) uses at the model layer; the tool layer has no
equivalent.

### 3. Declarative config + incremental reconciliation → config, profiles, presets as one authoritative record

Theorem 73 (quiescent state = f(final config); order-independent reconciliation)
validates clanker's direction: `config.toml` + `--profile` overlays (ADR 0024) +
presets (PRD 0033) are already a declarative configuration tree, and the REPL's
`/plugins on|off` reloading the tool catalog is a miniature reconciliation. The
paper's per-field dispatch (rebuild vs. reload vs. in-place) is the principled version
of what clanker does ad hoc; the *no load order* property is exactly what the tool
system would need if manifests ever gain cross-tool dependencies (PRD 0022 already
resolves name collisions last-listed-wins; a loader with the paper's property would
make that ordering irrelevant for activation).

### 4. Hot module replacement → scope improve-self to the plugin layer

The single most relevant application. clanker's improve-self loop edits source and
needs a rebuild + restart to take effect; the paper's Section 1.2.2 names this exact
scenario — a harness that "generates and deploys modifications to its own components
while continuously serving requests" — as the motivating case where full restarts
discard accumulated state and a faulty self-modification "can disable the very process
needed to recover." HMR (dispose old fiber, instantiate new) is the recoverable
version. clanker already has a plugin layer (WASM tools, skills, prompts, chains,
presets, web UI plugins) that is *loadable without rebuilding the binary*; a
self-improvement loop scoped to those surfaces (recompile a tool's wasm, swap it
in-process) would get most of the paper's value with none of the JS runtime. The
ROADMAP audit's rejection of Cordis *standing-mount machinery* stays correct; the HMR
*principle* for the plugin surfaces does not follow from it.

### 5. Service broker → provider fallback chain and mesh

The paper's broker (multiple providers coexist, broker dispatches; rolling updates =
gradual provider transition) is the formalized version of clanker's fallback provider
chain (PRD 0025) and its mesh (PRD 0011): the mesh is a *cross-process* broker with
local providers and RPC-mediated access — the paper's Section 6.2 "cross-process
invocation" verbatim. Nothing to build; the vocabulary gives the existing design a
name and its guarantees (unloading a provider reverts its registration; consumers see
no reload).

### 6. System boundary + compensation → sandbox mental model and janitor

The paper's boundary (inside = exclusively modifiable and restorable; outside =
emissions, only compensable) is precisely clanker's sandbox line: a WASM guest writes
files only through declared grants, so its writes are tracked; anything that escapes
(state/ artifacts, spills, chatroom messages) is an *emission* that can only be
compensated — which is exactly what `clanker janitor` already does. The paper's
acquisition/emission split (acquisition installs a revertible record; emission pushes
through it) suggests making tool-written artifacts carry an acquisition record so
janitor deletes precisely, the way `state/spills/` and `state/opencv/` already
imply.

## What not to apply

- **The Cordis JS runtime itself.** A dependency clanker cannot adopt: clanker is a
  single-binary Zig harness with AOT-compiled WASM tools (PRD 0033's scoping note and
  the ROADMAP audit already rejected Cordis standing mounts/generations/file watchers
  as "no equivalent need in clanker's static, WASM-manifest tool model"). The paper's
  *principles* transfer; its implementation does not.
- **Full effect/coeffect machinery in the agent-loop hot path.** The agent loop is
  deliberately native (ADR 0004's reasoning: keys, transport, per-token cost). The
  mechanisms belong at the *plugin registry* layer, not inside `loop.zig`.
- **Developer-annotated HMR boundaries / Webpack-style HMR.** The paper's HMR needs no
  annotations, but clanker has no module-level dev server; tool-level swaps are the
  right granularity.

## Bottom line

The paper is the missing *theory* under the philosophy clanker's ROADMAP audit already
practices ad hoc. It would help as (a) a vocabulary for the gap report (temporal =
revertible effects, spatial = reactive coeffects), (b) a design target for the tool
registry's off-switch and dependency handling, and (c) the strongest argument for
scoping improve-self's self-modification to the plugin layer first, where HMR-style
swap is already loadable. It changes no in-flight clanker decision; it sharpens the
ones being made.
