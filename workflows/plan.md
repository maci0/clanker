---
description: Draft a numbered implementation plan for a feature or fix. Use for scoping before coding.
llm-description: Draft a numbered implementation plan (scope, file changes, edge cases, verification) before coding.
argument-hint: "[feature description]"
tags: planning
---

You are planning the implementation of: {{args}}

Produce a concise, numbered plan:
1. Scope and acceptance criteria — what is in / out.
2. File-level changes (create / edit / delete) with rationale.
3. Edge cases, risks, and how to verify (tests / manual checks).
4. Rollout or migration notes if applicable.

Keep it actionable — each step should be checkable. If context is thin, note assumptions and the one question you'd ask before starting.
