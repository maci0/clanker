# Operational reports

This directory preserves the evidence, diagnosis, resolution, and verification
of bugs and investigations that would otherwise be lost in a run log or a pull
request discussion. It complements PRDs: a PRD describes intended product
behavior; a report explains an observed failure and the work that resolved it.

## Start here

- Use [bugs/TEMPLATE.md](bugs/TEMPLATE.md) for a confirmed defect that needs a
  durable record, including its resolution.
- Use [investigations/TEMPLATE.md](investigations/TEMPLATE.md) while tracing a
  symptom, even if the eventual result is "not a bug".
- Every report starts with `## TL;DR`, then gives the detail needed to repeat
  the reasoning without reconstructing it from logs.
- Name reports `YYYY-MM-DD-<short-topic>.md`, keep the file in the matching
  subdirectory, and add it to the inventory below when it is created.
- When an investigation confirms a defect, link its bug report both ways. When
  the defect is resolved, keep the original evidence and add the fix commit,
  tests, and any remaining risk instead of rewriting the incident away.
- When the resolution is a repeatable recovery procedure, create or update its
  companion [runbook](../runbooks/) as well. Keep the report's history here and
  the concise current procedure in the runbook.

## From a terminal

`clanker reports` is the same store from a shell. It calls the same `reports`
tool, so the inventory below, the templates and the compare-and-swap writes are
shared rather than reimplemented.

List every report and runbook:

```bash
clanker reports
```

Search both stores before diagnosing a failure:

```bash
clanker reports search "NotDir"
```

Read one record:

```bash
clanker reports open docs/reports/bugs/2026-08-14-worktree-state-symlink-notdir.md
```

Move a record to a new state, record and inventory together:

```bash
clanker reports status docs/reports/bugs/2026-08-14-worktree-state-symlink-notdir.md resolved "ensureDir handles the symlink; zig build test passes"
```

`clanker reports --help` covers `create`, `append`, `update` and `status`.

## Agent workflow

Before diagnosing a failure, use the `reports` tool's `search` action with the
error text, command, subsystem, or symptom; it searches this directory and
[runbooks](../runbooks/) together. Read a matching report before choosing a
fix; its conclusion is evidence to verify against the current tree, not an
instruction that overrides the current task. Reuse a resolved report's
reproduction and checks where they still apply. If no report covers the issue,
use its `create` action to make a TL;DR-first investigation while tracing it,
then a bug report once the defect is confirmed. `create` also adds the record
to the matching inventory. As the work proceeds, use `append` for new evidence
and `update` for a precise correction to an existing passage; both reject a
concurrent change, so reopen the record before retrying. When the work reaches
a new state, use `status` rather than editing the Status line: it rewrites the
record and its inventory entry in one call, and the inventory is what the next
reader skims. `resolved` requires a note naming the fix and what verified it,
so write the Resolution and Verification sections first. Fill out the scaffold
with the evidence, resolution, and verification before calling it complete.
Project agents receive this workflow through the harness prompt and
[`AGENTS.md`](../../AGENTS.md).

## Inventory

### Bugs

<!-- inventory:bug:start -->
- [dump-config leaks the secret half of any header whose value contains an equals sign](bugs/2026-08-24-dump-config-header-redaction-cuts-on-equals.md) — Open

- [the merge-base pin advances before the branch resync it depends on, and the resync failure is only a warning](bugs/2026-08-24-improve-merge-pin-advances-before-the-resync.md) — Open

- [kind = grok discards per-model temperature and top_p and never consults the PRD 0024 profile table](bugs/2026-08-24-grok-kind-drops-model-sampling.md) — Open

- [a missing profiles/<name>.toml is reported as config.toml not found, and the .local variant is never read](bugs/2026-08-24-profile-overlay-errors-name-the-wrong-file.md) — Open

- [a preset's denied tools are still offered to the model; repl --preset is a silent no-op](bugs/2026-08-24-preset-tool-filter-is-inert.md) — Open

- [an unreadable or oversize improvements.jsonl reads as no history, disabling the improve loop's dedup and revert gates](bugs/2026-08-24-improve-history-read-failure-reads-as-empty.md) — Open

- [a mis-escaped trim set lets a whitespace-only hook command through, and the warn log then indexes an empty argv](bugs/2026-08-24-hook-command-trim-set-is-mis-escaped.md) — Open

- [the Anthropic wire is sent OpenAI's reasoning_effort field, and no thinking_schema value produces a valid Anthropic block](bugs/2026-08-24-anthropic-wire-gets-openai-reasoning-effort.md) — Open

- [auto-thinking runs the classifier once per iteration instead of once per turn, and classifies a blank submit](bugs/2026-08-24-auto-thinking-classifies-every-iteration.md) — Resolved

- [the one-turn advisor block is removed only on the success path, so three exits leave it as message 0](bugs/2026-08-24-advisor-block-leaks-into-message-zero.md) — Resolved

- [the persistent-learnings prompt section keeps the oldest 4 KiB, so every note past the cap is invisible forever](bugs/2026-08-24-learnings-prompt-keeps-the-oldest-notes.md) — Resolved

- [advisor.model is parsed, documented and never read, so every critique bills the main model](bugs/2026-08-24-advisor-model-never-read.md) — Resolved
- [ck_http hands guests no response headers, so header-only facts are unreachable](bugs/2026-08-24-ck-http-hands-guests-no-response-headers.md) — Open

- [gh_read lists and diffs are silently cut to GitHub's default page of 30](bugs/2026-08-24-gh-read-lists-silently-cut-at-thirty.md) — Resolved

- [ck_http drops the status and body of every >= 400 response, so two documented gh_read errors could never fire](bugs/2026-08-24-ck-http-drops-error-status-and-body.md) — Resolved

- [A gh_read PR diff is a run of hunks that names no file](bugs/2026-08-24-gh-read-diff-hunks-name-no-file.md) — Resolved
- [A plugin with one typo in capabilities vanishes from the list with nothing to read, and group is never checked](bugs/2026-08-24-webui-addon-list-drops-a-bad-manifest-with-no-diagnostic.md) — Open

- [A plugin's refresh hook is documented as the re-entry point but the host never calls a view loader twice](bugs/2026-08-24-plugin-refresh-hook-is-unreachable.md) — Open

- [Every plugin's api.status writes the same sr-only live region, and Health rewrites it about once a second](bugs/2026-08-24-plugin-status-line-is-one-shared-live-region.md) — Open

- [A web UI plugin's tab is wired at the end of VIEWS but inserted mid-rail, so arrow-key order scrambles](bugs/2026-08-24-plugin-tab-arrow-keys-follow-registration-order.md) — Open

- [A board card's member avatar is a control inside the card button, and picking a member reopens the picker](bugs/2026-08-24-board-card-member-avatar-nested-in-the-card-button.md) — Open

- [The composer textarea carries role=combobox, which ARIA does not allow on a textarea](bugs/2026-08-24-webui-task-textarea-combobox-role.md) — Open

- [Template boilerplate and duplicated sections are in the RFC and report stores too, not just the six PRDs](bugs/2026-08-23-template-boilerplate-across-rfcs-and-reports.md) — Open

- [Bug — a run using the debug tool leaks a hash-map allocation when launch times out](bugs/2026-08-23-debug-tool-run-leaks-on-adapter-timeout.md) — Open

- [cli.zig respond() sends a full body on HEAD, against RFC 9110 and its own stated invariant](bugs/2026-08-23-respond-sends-a-body-on-head.md) — Resolved

- [A reports status note is written verbatim in two places, so the store's own update verb cannot edit it](bugs/2026-08-23-reports-status-note-lands-twice-and-cannot-be-edited.md) — Open

- [The /api/events cap refusal declares a Content-Length four bytes longer than its body](bugs/2026-08-23-events-cap-503-declares-the-wrong-length.md) — Resolved
- [PRDs 0052 through 0057 each carry a second, unfilled copy of four template sections](bugs/2026-08-23-prd-template-boilerplate-left-in-six-records.md) — Resolved

- [The opt-in 3D arena stage is blank for good after one tab switch](bugs/2026-08-23-arena3d-stage-stays-blank-after-unmount.md) — Resolved

- [The REPL transcript renders bridge_stream_buf as bridgestreambuf](bugs/2026-08-23-repl-markdown-eats-snake-case-underscores.md) — Open

- [A clipboard paste request the terminal never answers leaves the REPL composer unable to submit](bugs/2026-08-23-repl-composer-latches-into-paste-mode.md) — Open

- [A round-1 arena forfeit resolves damage the combatant never had a chance to see](bugs/2026-08-23-arena-round-one-forfeit-eats-unseen-damage.md) — Resolved

- [DAP waitEvent appends every frame to the event queue, so attach can lose its own response](bugs/2026-08-23-dap-waitevent-files-responses-as-events.md) — Resolved

- [DAP launch waits for an initialized event that initialize already queued, so a correct adapter times out](bugs/2026-08-23-dap-launch-misses-a-queued-initialized-event.md) — Resolved

- [The Arena view freezes on a running match: its poll skips every tick while the live stream is up](bugs/2026-08-23-arena-view-never-refreshes-a-running-match.md) — Resolved

- [The kernel supervisor's environment was whatever the Io carried, not a policy](bugs/2026-08-23-kernel-supervisor-environment-is-unspecified.md) — Resolved

- [A clanker-<name> binary on PATH is exec'd unsandboxed with no entry in the enabled-list](bugs/2026-08-23-cli-tier2-plugin-runs-without-consent.md) — Resolved

- [A composer @path mention of a file over the 32 KiB cap is dropped instead of truncated](bugs/2026-08-23-mention-over-cap-file-dropped.md) — Resolved

- [Every kernel cell was held for the full timeout_ms before its reply was returned](bugs/2026-08-23-kernel-timeout-watchdog-holds-every-reply.md) — Resolved

- [corrupt TUI/CLI plugin state silently disabled every plugin](bugs/2026-08-23-corrupt-plugin-state-silently-disables.md) — Resolved

- [A hung-up /api/events subscriber does not release its in-flight slot on macOS](bugs/2026-08-23-events-slot-not-released-on-hangup.md) — Resolved

- [A panic raised from a blocked Io.Threaded recurses forever instead of aborting](bugs/2026-08-23-panic-recurses-forever-instead-of-aborting.md) — Resolved

- [zig build e2e does not compile on macOS: the pty harness is Linux-only](bugs/2026-08-23-e2e-pty-harness-is-linux-only.md) — Resolved

- [unknown provider kind failed with no naming diagnostic](bugs/2026-08-23-unknown-provider-kind-names-nothing.md) — Resolved

- [Arena floored untargeted concede and final_stand moves](bugs/2026-08-23-arena-untargeted-concede-floored.md) — Resolved

- [DAP stop events were attached to the next tool call](bugs/2026-08-23-dap-stopped-event-misattributed.md) — Resolved
- [A kernel cell writing to fd 1 corrupts the supervisor's JSON line protocol](bugs/2026-08-23-kernel-cell-stdout-corrupts-supervisor-protocol.md) — Resolved

- [Production kernel cells run unsandboxed while ADR 0010 specifies a WASI sandbox](bugs/2026-08-23-kernel-persist-path-is-unsandboxed.md) — Open

- [improve gate skipped extra in-tree tools_dir entries](bugs/2026-08-23-descriptor-gate-skips-extra-tools-dirs.md) — Resolved

- [Goal-loop work turns ignore --backend and call Agent.run](bugs/2026-08-22-goal-loop-ignores-backend.md) — Resolved

- [ACP hang never unblocks a silent vendor child](bugs/2026-08-22-acp-hang-never-unblocks-a-silent-child.md) — Resolved

- [Two backend runs in the same second wrote one graph file](bugs/2026-08-22-backend-run-id-seconds-collide.md) — Resolved

- [clanker commit --all silently omits every new file](bugs/2026-08-22-commit-all-omits-new-files.md) — Resolved

- [rfc create writes a seeded research link that does not resolve](bugs/2026-08-22-rfc-seeded-research-link-misses-the-parent-directory.md) — Resolved

- [improve-self exhausts all attempts when the model answers only in reasoning](bugs/2026-08-22-improve-self-reasoning-only-empty-content.md) — Resolved
- [A hand-made git worktree loses config.local.toml and .env, so clanker verbs fall back to the committed default provider](bugs/2026-08-22-hand-made-worktree-falls-back-to-committed-provider.md) — Resolved

- [loadSessions folds every failure into an empty conversation list](bugs/2026-08-22-webui-loadsessions-swallows-failure.md) — Resolved

- [webui model and effort choices are stored browser-global, not per chat](bugs/2026-08-22-webui-model-effort-storage-is-global.md) — Resolved

- [webui handles llm_start stream events the server never emits](bugs/2026-08-22-webui-llm-start-event-never-emitted.md) — Resolved

- [node --test on ui/app fails in directory mode while every file passes](bugs/2026-08-22-node-test-dir-mode-fails-on-ui-app.md) — Resolved

- [REPL slash commands typed mid-run are steered, not run](bugs/2026-08-22-repl-slash-commands-swallowed-mid-run.md) — Resolved

- [Post-launch DAP ops block unbounded on a silent adapter](bugs/2026-08-22-dap-post-launch-ops-block-unbounded.md) — Resolved

- [Steer framing sentence is persisted as the user's own words](bugs/2026-08-22-steer-framing-persisted-in-transcript.md) — Resolved

- [Non-streaming runs never register a steer slot](bugs/2026-08-22-nonstreaming-runs-unsteerable.md) — Resolved

- [steerEnqueue delivers to the first matching slot only](bugs/2026-08-22-steer-enqueue-first-match-only.md) — Resolved

- [REPL log sink frees the logger's stack buffer on the first [ERROR] record](bugs/2026-08-22-repl-log-sink-frees-the-loggers-stack-buffer.md) — Resolved

- [debug.launch_timeout_ms is stored but never bounds a launch](bugs/2026-08-21-dap-launch-timeout-never-bounds-launch.md) — Resolved

- [SQLITE_TRANSIENT translate-c cast breaks the build on aarch64-macos](bugs/2026-08-21-sqlite-transient-fnptr-cast-breaks-macos-build.md) — Resolved

- [Worker parallel sandbox omitted the session grant, denying session tools and failing the session_search capability eval in improve-self](bugs/2026-08-20-worker-sandbox-omits-session-denies-session-tools.md) — Resolved

- [janitor reports removing orphaned staging dirs but large ones survive](bugs/2026-08-20-janitor-truncated-list-leaves-staging-behind.md) — Resolved

- [lsp capability eval fails on large files, blocking every improve-self promotion](bugs/2026-08-20-lsp-eval-blocks-improve-self.md) — Resolved

- [improve-self left src/acp/server.zig non-compiling across two commits](bugs/2026-08-20-improve-self-acp-server-build-break.md) — Resolved

- [schedule list rendered rows after the first as garbage from a freed buffer](bugs/2026-08-19-schedule-list-second-row-garbled.md) — Resolved

- [A throwing plugin mount broke the tab switch instead of showing a tab error](bugs/2026-08-19-webui-plugin-mount-throw-breaks-tab-switch.md) — Resolved

- [Corrupt state/webui_plugins.json was swallowed silently](bugs/2026-08-19-webui-plugin-state-corruption-silent.md) — Resolved

- [A capped scheduled run takes the whole run-due sweep down with it](bugs/2026-08-19-schedule-sweep-dies-with-capped-entry.md) — Resolved

- [The UnknownProvider hint pointed at config.toml although providers merge from config.toml + config.local.toml](bugs/2026-08-19-unknownprovider-hint-names-only-config-toml.md) — Resolved

- [Vertex error bodies reach the operator as a bare HTTP status: the Google error envelope is parsed by no codec and unrecognised bodies are discarded](bugs/2026-08-19-vertex-error-bodies-discarded.md) — Resolved

- [A lapsed chat deadline can wedge the caller forever: the abort fires once and cancel cannot rescue a blocked read](bugs/2026-08-19-bounded-chat-one-shot-abort-wedges.md) — Resolved

- [rfc recommend replaces existing Why-this-confidence and Reversibility text with template placeholders](bugs/2026-08-19-rfc-recommend-replaces-fields-it-was-not-given.md) — Resolved

- [research sweep's web backend returns only unrelated pages](bugs/2026-08-19-research-sweep-web-backend-returns-unrelated-results.md) — Resolved

- [improve-self fast-forwards main's ref but leaves the working tree/index reverted to pre-promotion content](bugs/2026-08-19-improve-self-merge-leaves-worktree-reverted.md) — Resolved

- [zigLibDir spawns bare zig with no PATH search or environment, always failing](bugs/2026-08-19-zig-lib-dir-never-resolves-in-sandbox.md) — Resolved

- [zig_std returns not-found: zigLibDir runs zig env without the live environment](bugs/2026-08-19-zig-std-missing-environ-map.md) — Resolved

- [improve-self hangs when a provider goes quiet: proposal/plan LLM calls have no deadline](bugs/2026-08-18-improve-engine-llm-calls-have-no-deadline.md) — Resolved

- [improve-self staging tests fail on peers.notifications unreadable-log test](bugs/2026-08-18-improve-self-notifications-test-assertion.md) — Resolved

- [The agent loop sends max_tokens_per_turn as the completion grant](bugs/2026-08-18-turn-sends-compaction-cap-as-completion-grant.md) — Resolved

- [recent_commits test fails when a commit subject contains the two characters backslash-n](bugs/2026-08-18-recent-commits-test-false-positive-on-backslash-n.md) — Resolved

- [The fallback chain attempts providers that have no credentials](bugs/2026-08-18-fallback-tries-unconfigured-providers.md) — Resolved

- [A truncated ck_exec result emits an unquoted note and is not JSON](bugs/2026-08-18-exec-truncated-note-is-not-json.md) — Resolved

- [improve-self stalls re-asking for a granted file too large to include](bugs/2026-08-17-improve-self-stalls-asking-for-too-large-file.md) — Resolved

- [A status change keeps the old text of a multi-line TL;DR bullet](bugs/2026-08-17-status-truncates-a-multi-line-tldr-bullet.md) — Resolved

- [clanker commit --yes auto-applies the degraded fallback plan](bugs/2026-08-17-commit-yes-applies-a-degraded-fallback-plan.md) — Resolved

- [The improve ledger is written to a worktree copy that is never merged back](bugs/2026-08-17-improve-ledger-written-to-a-worktree-copy.md) — Resolved

- [A stray config.toml hunk reverts to the struct default and nothing surfaces it](bugs/2026-08-17-config-hunk-deleted-as-collateral-reverts-silently.md) — Resolved

- [A CAS lock name hashes the path string, so one target can have two locks](bugs/2026-08-17-cas-lock-name-hashes-an-unresolved-path.md) — Resolved

- [An agent run hangs forever when a provider accepts the connection and goes quiet](bugs/2026-08-17-agent-llm-call-has-no-deadline.md) — Resolved

- [SIGWINCH runs vaxis winsize callbacks in the signal handler, panicking std.Io and recursing through recover()](bugs/2026-08-17-tui-resize-crash-sigwinch-in-signal-handler.md) — Resolved

- [A goal loop stops dead on a single AnswerTruncatedToEmpty instead of retrying the turn](bugs/2026-08-17-goal-loop-dies-on-one-truncated-reply.md) — Resolved

- [The autolearn synthesis grant is spent entirely on reasoning](bugs/2026-08-17-ck-llm-grant-spent-on-reasoning.md) — Resolved

- [session_search and spill list broke their JSON shape on empty stores, failing improve-self capability evals](bugs/2026-08-17-capability-evals-reject-empty-store-tools.md) — Resolved

- [TUI scrolling cannot reach the messages above an expanded reply](bugs/2026-08-17-scroll-cannot-reach-above-expanded-reply.md) — Resolved

- [clanker run exits clean when the final reply is length-truncated to empty](bugs/2026-08-17-run-reports-success-on-empty-length-stop.md) — Resolved

- [TUI scrolling never advances through a fully expanded fold](bugs/2026-08-17-expanded-fold-cannot-be-scrolled-through.md) — Resolved

- [TUI expanded reply fold shows a stray › on its first body line](bugs/2026-08-17-fold-first-line-keeps-turn-arrow.md) — Resolved

- [Peer cooldown table is never freed, so any command that reaches a down peer ends in a leak trace](bugs/2026-08-17-peer-cooldown-table-leaks-at-exit.md) — Resolved

- [TUI reply fold can be opened but never closed again](bugs/2026-08-17-fold-header-vanishes-when-expanded.md) — Resolved

- [origin/main did not compile: an if mixed the optional catch-null form with an error-union else clause](bugs/2026-08-17-pushed-main-mixed-optional-and-error-else.md) — Resolved

- [clanker commit applies a plan it computes a second time, not the one it previewed](bugs/2026-08-17-commit-applies-an-unconfirmed-plan.md) — Resolved

- [Activity view shows only 'log' actions, so a board being worked on looks idle](bugs/2026-08-17-activity-view-shows-only-log-actions.md) — Resolved

- [clanker commit writes one commit and reports the whole multi-commit plan as written](bugs/2026-08-17-smart-commit-sweeps-the-whole-index.md) — Resolved

- [Every completed GET /api/events is logged at ERROR and counted as a server error](bugs/2026-08-17-sse-subscriptions-logged-as-server-errors.md) — Resolved

- [Runs filter's 'failed' keyword throws a TypeError and could never match](bugs/2026-08-17-runs-filter-failed-keyword-throws.md) — Resolved

- [clanker janitor never prunes sub-run graphs](bugs/2026-08-17-janitor-never-prunes-sub-run-graphs.md) — Resolved

- [smart_commit's apply path re-adds whole worktree files, widening a hunk-narrowed index](bugs/2026-08-17-smart-commit-readds-worktree-files.md) — Resolved

- [clanker commit generates a generic 'chore: update working tree' message for a clearly scoped diff](bugs/2026-08-16-smart-commit-generic-message.md) — Resolved

- [resolveExecPath leaks PATH-candidate allocations through ckStdApi](bugs/2026-08-17-resolveexecpath-candidate-leak.md) — Resolved

- [A commit on origin/main did not compile, and the break surfaced in an unrelated session's push](bugs/2026-08-16-pushed-main-did-not-compile.md) — Resolved

- [reports status updates the Status section but not the TL;DR](bugs/2026-08-16-reports-status-leaves-the-tldr-saying-open.md) — Resolved

- [Five agent sessions on one checkout committed and stashed each other's work](bugs/2026-08-16-concurrent-sessions-commit-each-others-work.md) — Resolved

- [clanker commit always fails: smart_commit returns no text field](bugs/2026-08-16-clanker-commit-tool-output-has-no-text-field.md) — Resolved

- [improve-self worktrees are never reclaimed when a run promotes nothing](bugs/2026-08-16-improve-worktree-merge-bound-to-promotion.md) — Resolved

- [Every guest read and write under a symlinked state/ was refused](bugs/2026-08-16-guest-writes-refused-under-symlinked-state.md) — Resolved

- [State backups stopped for two days because .agents is a real directory](bugs/2026-08-16-state-backup-aborts-on-checkout-local-agents.md) — Resolved

- [Isolated-run e2e still called the removed `goal` guest](bugs/2026-08-16-worktree-e2e-calls-removed-goal-tool.md) — Resolved

- [Worker parallel sandbox omitted tool_self_name, failing capability evals in improve-self](bugs/2026-08-16-worker-sandbox-missing-tool-self-name.md) — Resolved

- [Compaction repeats forever when the history it cannot move exceeds the threshold](bugs/2026-08-16-compaction-cannot-shrink-immovable-history.md) — Resolved

- [The compaction summary always fails on a thinking model](bugs/2026-08-16-compaction-summary-budget-spent-on-reasoning.md) — Resolved

- [Unknown goal id runs unscoped task](bugs/2026-08-15-unknown-goal-id-runs-unscoped.md) — Resolved

- [Goal lifecycle capabilities were conflated](bugs/2026-08-15-goal-lifecycle-capabilities-conflated.md) — Resolved

- [Worktree setup rejects a symlinked checkout state directory](bugs/2026-08-14-worktree-state-symlink-notdir.md) — Resolved

- [Improve staging misses UI build inputs](bugs/2026-08-14-improve-staging-misses-ui-build-inputs.md) — Resolved
- [Improve staging omits release-contract files](bugs/2026-08-14-improve-staging-omits-release-contract-files.md) — Resolved
<!-- inventory:bug:end -->

### Investigations

<!-- inventory:investigation:start -->
- [The two pty e2e tests fail in any git worktree and pass in the main checkout](investigations/2026-08-22-pty-e2e-fails-in-a-worktree.md) — Resolved

- [improve_history is granted a path that is a symlink inside an improve-self worktree](investigations/2026-08-22-improve-history-guest-in-an-improve-worktree.md) — Resolved

- [Two pty e2e journeys fail on an untouched base: the REPL's vaxis capability queries never arrive](investigations/2026-08-22-pty-e2e-capability-queries-unanswered.md) — Resolved

- [REPL UI thread and run worker allocate from one unlocked ArenaAllocator](investigations/2026-08-22-repl-ui-thread-and-worker-share-one-unlocked-arena.md) — Closed

- [Web UI bug+gap queue disposition](investigations/2026-08-21-webui-bug-gap-queue-disposition.md) — Resolved

- [Plugin-philosophy alignment gap analysis](investigations/2026-08-20-plugin-philosophy-alignment.md) — Resolved

- [zig build test crashed once with an ISCONN panic in the peers connect path](investigations/2026-08-19-peers-connect-isconn-panic.md) — Closed

- [google-vertex-anthropic returns HTTP 400 on every request, blocking improve-self](investigations/2026-08-19-vertex-anthropic-400.md) — Resolved

- [zig build test intermittently hangs forever in the bounded-chat abort test](investigations/2026-08-18-bounded-chat-abort-test-hangs.md) — Resolved
- [Stale post-promotion checkout diff on doctor.zig was committed and pushed as revert 124d592e](investigations/2026-08-19-stale-checkout-diff-pushed-as-revert.md) — Resolved

- [The REPL had no /rfc although clanker rfc exists](investigations/2026-08-17-missing-clanker-tool-rfc-slash-command-in-tui.md) — Resolved
- [Escalation run died AnswerTruncatedToEmpty after 34 iterations](investigations/2026-08-18-escalation-run-answer-truncated-to-empty.md) — Resolved

- [improve-self staging compile errors and recent_commits test failed the gate](investigations/2026-08-18-improve-self-staging-and-recent-commits.md) — Resolved

- [Escalation run died on DeepSeek ReadFailed and an unconfigured OpenAI fallback](investigations/2026-08-18-escalation-run-failed-on-llm-fallback.md) — Resolved

- [pty e2e text assertions race vaxis's cell diff](investigations/2026-08-17-pty-text-assertions-race-the-cell-diff.md) — Resolved

- [The two-spellings CAS-lock test failed one run in three with lock_count 2](investigations/2026-08-17-cas-lock-two-spellings-test-flaked-once.md) — Resolved

- [Record search matches one exact substring, so multi-word queries miss existing records](investigations/2026-08-17-missing-clanker-tool-record-search-has-no-multi-word-semantics.md) — Resolved

- [No verb reads or sets a single config key](investigations/2026-08-17-missing-clanker-tool-no-verb-reads-or-sets-a-config-key.md) — Resolved

- [Record stores have no rename or move action](investigations/2026-08-17-missing-clanker-tool-record-stores-cannot-rename-a-record.md) — Resolved

- [TUI cannot scroll above an expanded reply](investigations/2026-08-17-tui-cannot-scroll-above-expanded-reply.md) — Resolved

- [No CLI verb prints a completed run's final answer](investigations/2026-08-17-missing-clanker-tool-no-verb-prints-a-runs-final-answer.md) — Resolved

- [TUI fold shows a stray turn arrow and cannot be scrolled through](investigations/2026-08-17-tui-fold-arrow-and-scroll.md) — Resolved

- [ck_cas.lock sidecars still accumulating in the source tree](investigations/2026-08-17-ck-cas-lock-sidecars-still-accumulating.md) — Resolved

- [GET /api/events logs as ERROR status=0 and counts as an http error](investigations/2026-08-17-sse-requests-logged-as-errors.md) — Resolved

- [TUI Shift+Enter logs vaxis_parser unhandled ss3 instead of newline](investigations/2026-08-17-tui-shift-enter-ss3-unhandled.md) — Resolved

- [Web UI run history is stale because graph listings sort filenames lexically](investigations/2026-08-17-web-ui-run-history-stale.md) — Resolved

- [TUI selection copy never reaches the system clipboard in terminals that ignore OSC 52 or intercept Ctrl+Shift+C](investigations/2026-08-16-tui-selection-copy-not-reaching-clipboard.md) — Resolved

- [TUI crashes irrecoverably on terminal resize with mascot enabled](investigations/2026-08-16-tui-resize-crash.md) — Resolved

- [TUI Ctrl+C cannot interrupt a streaming turn while the picker or search modal is open](investigations/2026-08-16-tui-ctrl-c-swallowed-by-picker-and-search.md) — Resolved

- [Improve staging omits node UI-test data roots](investigations/2026-08-15-improve-staging-node-ui-data.md) — Resolved

- [ck_cas lock sidecars are never removed and bypass the create retry](investigations/2026-08-16-ck-cas-lock-sidecars.md) — Closed

- [`clanker run` never finishes, compacting on every iteration](investigations/2026-08-16-run-livelock-compaction-thrash.md) — Resolved

- [improve-self gate tool build failure (appendWriteFn) and follow-up](investigations/2026-04-15-improve-self-gate-build.md) — Resolved

- [improve-self iterations exhaust attempts on config.toml documentation test](investigations/2026-06-13-improve-staging-config-doc.md) — Resolved

- [improve-self iterations wasted on @errorUpdate in WASM guest](investigations/2026-06-12-improve-self-erroreupdate-guest.md) — Resolved

- [improve-self iterations fail on hallucinated @errorUpdate](investigations/2025-08-17-improve-self-errorupdate.md) — Closed

- [Goal command lifecycle contract](investigations/2026-08-15-goal-command-lifecycle-contract.md) — Resolved

- [Unexpected worktree from isolated_cli and NotDir shared-state warning](investigations/2026-08-14-isolated-cli-worktree-notdir.md) — Resolved

- [Improve staging omits `ui/`](investigations/2026-08-14-improve-staging-omits-ui.md) — Resolved
<!-- inventory:investigation:end -->

## Report lifecycle

An investigation may be open, resolved, or closed as not a bug. A bug report
is open until the fix is verified, then resolved; it may be reopened if the
symptom returns. Status is a summary for the index, not a replacement for the
report's evidence and verification sections.

The inventory above carries a second copy of each status. Only the `status`
action writes both; `create` sets the inventory copy once and never again, so a
record moved by hand leaves the index behind. A runbook has no status — its
inventory line carries a summary — and `status` refuses one for that reason.

Reports are historical records. Amend them when new evidence changes the
conclusion, but do not delete failed hypotheses or the conditions that made a
bug possible.
