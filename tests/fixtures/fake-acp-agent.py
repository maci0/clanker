#!/usr/bin/env python3
"""Minimal ACP v1 stdio agent for clanker backend tests. Also handles grok/claude -p and codex exec."""
import json
import os
import sys


def send(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main_acp():
    session_id = "fake-1"
    hang = os.environ.get("FAKE_ACP_HANG") == "1"
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        msg = json.loads(line)
        method = msg.get("method")
        mid = msg.get("id")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "protocolVersion": 1,
                "agentCapabilities": {},
                "authMethods": [],
            }})
        elif method == "authenticate":
            send({"jsonrpc": "2.0", "id": mid, "result": {}})
        elif method == "session/new":
            send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": session_id}})
        elif method == "session/prompt":
            if hang:
                continue
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": session_id,
                "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "fake-acp-answer"},
                },
            }})
            send({"jsonrpc": "2.0", "id": 77, "method": "session/request_permission", "params": {
                "sessionId": session_id,
                "toolCall": {"toolCallId": "t1", "title": "echo"},
                "options": [
                    {"optionId": "allow-once", "name": "Allow once", "kind": "allow_once"},
                    {"optionId": "reject-once", "name": "Reject", "kind": "reject_once"},
                ],
            }})
            send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
        elif method == "session/cancel":
            if mid is not None:
                send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "cancelled"}})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found"}})


def main_headless():
    sys.stdout.write("fake-headless-answer\n")


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:2] == ["agent", "stdio"] or not args:
        main_acp()
    elif "-p" in args or "--print" in args or (args and args[0] == "exec"):
        main_headless()
    else:
        main_acp()
