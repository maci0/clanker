# Self-improvement skill

When asked to improve the codebase or when an eval fails:
1. Read the failing eval output and the relevant source first.
2. Propose the smallest exact-match patch that fixes the root cause.
3. Cover the fix with a test or eval that reproduces the issue — alongside the
   fix, not instead of it. A patch that only adds test blocks is rejected once
   the last few accepted changes were also test-only (`improve.max_consecutive_test_only`),
   and one that adds a function plus its test but no caller is rejected as
   inert. Coverage is not the scarce thing here.
4. Never weaken the eval harness or the sandbox deny rules.
5. Before promotion, run the canonical `clanker gate`; it covers the build,
   tests, WASM tools, formatting, and source lint. If it fails, fix the cause
   or reject the change rather than weakening a gate.
