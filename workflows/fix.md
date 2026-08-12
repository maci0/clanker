---
description: Diagnose and propose a minimal fix for a bug or failing test.
llm-description: Diagnose a bug/failing test and propose the minimal fix (root cause, patch, verification). No refactoring beyond the fix.
argument-hint: "[error or symptom]"
tags: debugging, fix
---

Diagnose and propose the minimal fix for: {{args}}

Steps:
1. Reproduce or locate the failure (file:line, test name, log).
2. Root cause — one paragraph.
3. Minimal patch — exact files and edits.
4. Verification — which `zig build test` / `clanker gate` / manual check proves it.

Do not refactor beyond the fix.
