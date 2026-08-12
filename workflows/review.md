---
description: Review code for bugs, security, and style. Paste a file or diff after the hint.
llm-description: Review code/diff for bugs, security, style, test gaps; end with a pass/needs-work/block verdict.
argument-hint: "[file or diff]"
tags: review, security
---

Review the following for correctness, security, and style: {{args}}

Checklist:
- Bugs, off-by-ones, unhandled errors, resource leaks
- Security: injection, authz, sandbox/fs boundaries
- Zig 0.16 idioms, error handling, allocator discipline
- Test coverage gaps

End with a verdict: ✅ pass / ⚠️ needs work / ❌ block — and the highest-priority fix first.
