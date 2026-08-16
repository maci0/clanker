# ADR 0020 — A workspace is a multi-root project whose board is its #general room

## Status

Accepted — 2026-08-16. Records the decision opened in [RFC 0001 — Workspace, room, board, and folder hierarchy](../rfcs/0001-workspace-room-board-hierarchy.md).

## Context

Operators treat a project as one thing with several folders and one shared
feed; the single-folder workspace, one global board room, and untagged goals
could not represent that, and a second clanker could not enter a project as a
first-class act.

## Decision

Adopt Option B from RFC 0001: a workspace is one stable id over one or more
named roots (components). The project's default room `ws:<id>` is its board and
`#general` feed; goals live in `state/goals.json` tagged to the workspace and
own first-class tasks (public, or private to named `instance.id`s). A goal is
never a card — the board card is a projection of public tasks only. A leaf
opened alone is a project with one root.

The RFC recommended Option B (multi-root workspace, `#general` plus optional
per-goal rooms, share/enter/leave/bind), without goal-is-a-card.

## Consequences

The sandbox root becomes a root set, which is a security-sensitive change: a
relative path's first component may name a root. Share/enter/leave/bind,
per-root share, and per-workspace roles remain open (mesh Phase 3). The
empty-id workspace keeps the legacy `board` room, so existing logs do not move.
