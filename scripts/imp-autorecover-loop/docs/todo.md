for the repair loop, add another layer where we first try to repair clanker run with clanker run before falling back to the sepcified repair harness


fix this

[WARN] ts_ms=1786778597430 request_id=run-1786776644 compaction summary failed (EmptyResponse), trying local extractive summary
[INFO] ts_ms=1786778597431 request_id=run-1786776644 tool-result pruning reclaimed 5882 bytes from the next request
The diff shows help text changes. The test passed in isolation though. Let me find the actual test definition to understand what it checks.[INFO] ts_ms=1786778599425 request_id=run-1786776644 iteration 170: 1 tool call(s)
[INFO] ts_ms=1786778599442 [exec] → rg
[INFO] ts_ms=1786778599449 [exec] ✓ rg … 6ms
[INFO] ts_ms=1786778599475 tool 'repo_search' -> 127 bytes in 49ms
[INFO] ts_ms=1786778599475 request_id=run-1786776644 compacting conversation: 10 messages, ~18364 estimated tokens (threshold 16000)
[WARN] ts_ms=1786778603714 request_id=run-1786776644 compaction summary failed (EmptyResponse), trying local extractive summary
[INFO] ts_ms=1786778603714 request_id=run-1786776644 tool-result pruning reclaimed 5882 bytes from the next request
[INFO] ts_ms=1786778604860 request_id=run-1786776644 iteration 171: 1 tool call(s)
[INFO] ts_ms=1786778606124 tool 'read_file' -> 2248 bytes in 1264ms
[INFO] ts_ms=1786778606125 request_id=run-1786776644 compacting conversation: 10 messages, ~18891 estimated tokens (threshold 16000)
[WARN] ts_ms=1786778611003 request_id=run-1786776644 compaction summary failed (EmptyResponse), trying local extractive summary
[INFO] ts_ms=1786778611003 request_id=run-1786776644 tool-result pruning reclaimed 5882 bytes from the next request
Let me run the failing test directly to see the current failure.[INFO] ts_ms=1786778616954 request_id=run-1786776644 iteration 172: 1 tool call(s)
[INFO] ts_ms=1786778616971 [exec] → zig
[INFO] ts_ms=1786778616992 [exec] ✓ zig … 21ms
[INFO] ts_ms=1786778617004 tool 'test_file' -> 32 bytes in 49ms
[INFO] ts_ms=1786778617004 request_id=run-1786776644 compacting conversation: 10 messages, ~18870 estimated tokens (threshold 16000)
[WARN] ts_ms=1786778621415 request_id=run-1786776644 compaction summary failed (EmptyResponse), trying local extractive summary
Test passes now. Let me check the git state and the WIP diff.[INFO] ts_ms=1786778622901 request_id=run-1786776644 iteration 173: 2 tool call(s)
[INFO] ts_ms=1786778622939 [exec] → git
[INFO] ts_ms=1786778622943 [exec] ✓ git … 4ms
[INFO] ts_ms=1786778622953 tool 'git' -> 419 bytes in 52ms
[INFO] ts_ms=1786778622991 [exec] → git
[INFO] ts_ms=1786778622998 [exec] ✓ git … 7ms
[INFO] ts_ms=1786778623008 tool 'git' -> 11041 bytes in 54ms
[INFO] ts_ms=1786778623009 request_id=run-1786776644 tool 'git' -> 11041 bytes
[INFO] ts_ms=1786778623009 request_id=run-1786776644 compacting conversation: 11 messages, ~18988 estimated tokens (threshold 16000)
[WARN] ts_ms=1786778627499 request_id=run-1786776644 compaction summary failed (EmptyResponse), trying local extractive summary
[INFO] ts_ms=1786778627499 request_id=run-1786776644 tool-result pruning reclaimed 5882 bytes from the next request
There's WIP in the workin


--


Three separate things, and none of them is the agent being lazy — the agent has never been told the board exists.

1. Nothing in the script ever writes [x]. claim_on_board() (line 430) is the only code that touches $root/.local/TODO.md. It appends the [-] … in progress line at line 450 and returns. run_pass() calls it once at line 464, runs the agent, pushes, and returns — there is no close_on_board counterpart anywhere. The claim is written; nothing was ever built to retire it.

2. The agent couldn't close it even if it wanted to. The prompt at lines 378–402 says "Do these four steps and nothing else" (status → add → commit → push) followed by "Do NOT do anything else." The board is never mentioned. On top of that, .local/ is gitignored, so the board doesn't appear in the git status --porcelain or git ls-files --others --exclude-standard output the prompt tells it to work from. The agent has no way to know the file exists.

3. The empty session:  on that line is a real bug, and it's why there's only ever one entry. Line 461 runs "$root/.loc, but .local/scripts/ does not exist — the actual script is at scripts/ywy50/scripts/new-session-id.sh. Normally set -e would abort there, but run_with_lock is invoked as run_with_lock || true (line 517), and set -e is suppressed for everything inside a || chain. So the assignment fails with 127, session_id stays empty, and execution continues into claim_on_board with a blank id.

That blank id then poisons the dedup guard at line 447: grep -qF "session: " matches the existing line as a substring,t sees "already claimed" and appends nothing. One permanently in-progress entry, forever.
equence of >>: the claim is appended to the end of the file, which is under ## Done — so an in-progress entry lands in the Done section regardless.

Most impactful remaining work:

- Fix the new-session-id.sh path at line 461 (and the same call at agent-automerge-git.sh:421) — this is the root cause of both the blank id and the dedup swallowing every later claim.
- Add a close_on_board that rewrites [-] … session: $id to [x] … done on success, called from run_pass after the push;t.
- Make claim_on_board insert under ## Active rather than appending to EOF, so entries don't land in ## Done while in progress.