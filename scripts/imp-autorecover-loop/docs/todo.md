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