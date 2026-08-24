# RFC 0030 — How session permission modes sit on confirm_writes

## Status

Decided — 2026-08-21. ADR 0042

## Overview

Kimi Code has manual/yolo/auto plus Approve for this session and pattern rules. Clanker has confirm_writes never|browser|always. Decide how session modes compose with the sandbox always-denied tier.

## Options considered

Sources opened: kimi docs/en/guides/interaction.md Approval flow and Mode switching (2026-08-21); slash-commands.md /yolo /auto /permission; src/config.zig confirm_writes.

### Option A — session mode enum on top of confirm_writes, plus a session allow-set

What it is: modes manual (ask), yolo (skip regular confirms, still ask plan-exit and secrets), auto (skip confirms and ask_user). "Approve for this session" records a tool-name allow for the rest of the session. Sandbox always-denied (dotenv, exec_allow) never lifts. Pattern rules in config are a later phase.

How it would fit: Agent.permission_mode + session_allow: StringHashMap; confirm_fn short-circuits on allow-set or yolo/auto. /yolo /auto /permission in the REPL.

Pros: matches kimi's attended/unattended split without deleting the sandbox.

Cons: two knobs (confirm_writes and mode) can confuse; need a precedence table.

Cost to adopt: mode + allow-set + slash commands. Cost to leave: drop the fields.

Evidence: interaction.md; agent.confirm_writes in config.zig.

### Option B — map kimi names onto confirm_writes only

What it is: /yolo aliases never, /permission always, auto is never plus ask_fn null.

Pros: no new state.

Cons: loses "approve for this session" and yolo-still-confirms-plan-exit.

### Option C — status quo

What it is: never/browser/always.

Pros: one ternary.

Cons: no session allow after one yes.

### Option D — out of the box: hooks.json PreToolUse deny

What it is: ADR 0027 already gates tools. Encode yolo as empty hooks.

Pros: no new mode.

Cons: hooks are fail-open policy scripts, not a session allow-set.

Evidence: ADR 0027.

## Implications by horizon

### Short term
- **If A:** /yolo and session allow-set work in REPL and web.
- **If B:** aliases only.
- **If status quo:** always/never remains the whole story.

### Medium term
- **If A:** config [[permission.rules]] can land as phase 2.
- **If B:** still no per-session allow.
- **If status quo:** operators set confirm_writes globally.

### Long term
- **If A:** mode is the kimi-shaped surface; sandbox remains the floor.
- **If B:** names lie.
- **If status quo:** fine if nobody wants yolo.

## Next steps / action items

- [ ] ADR: modes sit on confirm_writes, never replace the sandbox
- [ ] PRD: phase 1 mode + session allow-set; phase 2 pattern rules

## Recommendation

**Recommended option:** Adopt Option A: session mode enum on top of confirm_writes, plus a session allow-set

**Confidence:** 7/10

**Rationale.** Keeps the sandbox floor. Mapping onto confirm_writes alone loses approve-for-this-session and yolo-still-confirms-plan-exit.

## References

- Research: [Research — Kimi Code CLI feature inventory for clanker](../research/kimi-code-features.md) — read 2026-08-21. Its claims are unverified here until each is checked against the source it cites (the URL, repository, or file — the note itself is not the source).

