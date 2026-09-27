# ADR 0018 — Each record store is its own guest over shared scaffolding

## Status

Accepted — 2026-08-16.

## Context

clanker keeps six record stores under docs/ — reports, runbooks, rfcs, adrs, research, prds — and adding the adr and prd tools meant choosing between one parameterised 'records' guest taking a store descriptor, and one guest per store sharing a pure helper module. The stores look alike from a distance: numbered files, a TEMPLATE.md, a README.md inventory, compare-and-swap writes. They differ exactly where the code has to branch. The ADR index is a bullet list and the PRD index is a Markdown table with a Notes column, so an inventory insert is not one operation. PRD statuses are phrases ('In progress') and every other store's are single words, so status parsing is not one operation. The RFC carries a confidence score, the ADR a supersede rule, the PRD a Draft bar; each store's refusals are its own. A single guest would have carried all of that as conditionals on a descriptor field.

## Decision

Each store is its own guest module, and everything genuinely shared lives in a pure helper module outside the guest ABI, host-tested with it: `tools/zig/doc_scaffold.zig` (dates, slugs, numbering, template substitution, Markdown section arithmetic, both inventory shapes), `tools/zig/record_rename.zig` (rename arithmetic, shared by adr/rfc/prd), and `tools/zig/records_grep.zig` (the cross-store search). A new shared mechanic goes in one of these, not in a caller.

## Consequences

Makes easy: a store's own rules stay local and readable, so adr.zig's supersede refusal sits next to the status it refuses, not behind a descriptor flag. The shared modules stay host-testable, which matters more than it looks: a wrong section boundary silently corrupts a document, and that is the one class of bug a wasm-only helper can never be tested for. Adding a seventh store is a new guest plus whatever it genuinely shares. Makes hard, and this is the real cost: the CLI halves are now five near-identical files of roughly 440-650 lines each (~2,800 total) that differ in a renderer and a noun. A change to how every store reports a compare-and-swap conflict is five edits, and they will drift. The bet is that store-specific rules change more often than cross-store mechanics, so locality is worth the duplication; if that turns out backwards, the fix is a shared renderer over a store descriptor, which is a refactor of the CLI halves only and does not touch the guests.


See [PRD 0037 — Decision and spec stores on the CLI](../prds/0037-decision-and-spec-stores-on-the-cli.md) for the resulting design.