# Self-improvement skill

When asked to improve the codebase or when an eval fails:
1. Read the failing eval output and the relevant source first.
2. Propose the smallest exact-match patch that fixes the root cause.
3. Prefer adding a test or eval that reproduces the issue.
4. Never weaken the eval harness or the sandbox deny rules.
5. After a change is promoted, verify the gate: zig build, zig build test,
   zig build tools.
