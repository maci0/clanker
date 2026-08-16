# ADR 0019 — Record stores are exposed over HTTP as one relay endpoint per tool

## Status

Accepted — 2026-08-16. Records the decision opened in [RFC 0007 — HTTP surface for the five record-store tools](../rfcs/0007-records-http-surface.md).

## Context

Every web UI view in clanker is a thin client over an /api/ endpoint, and none of the six docs/ record stores had one, so a view for reports, RFCs, ADRs, PRDs and research notes had nothing to call. The five guests behind those stores (reports, rfc, adr, prd, research) already own path policy, record scaffolding and numbering, the second copy of every status in each store's README inventory, and compare-and-swap writes.

Four alternatives were considered seriously in RFC 0007. A resource-style REST grammar per store would give each record a real URL, but a record id is itself a path with slashes and a .md suffix, so every id route needs percent-decoding and a traversal check in src/ — a second path policy beside the guest's own fs_prefixes. Relaying reads while keeping writes native is the shape /api/sessions uses, but that precedent does not transfer: session mutations are branch, fork and compact over live transcript state, whereas a record write is a text edit to a file the guest already owns, and a second writer would double the surface for exactly the bug the stores have already produced (a status written to the record but not to the README inventory). Doing nothing left the view blocked and pushed anyone wanting records in a browser toward a plugin that reads docs/ itself. A generic POST /api/tools/<name> relay was the smallest option but puts the whole tool catalog behind one route, which clanker mcp already does deliberately and with a protocol.

## Decision

Each record store gets one HTTP endpoint per tool — /api/reports, /api/rfc, /api/adr, /api/prd, /api/research — that relays straight to that guest and carries the guest's own field names. GET accepts only the read actions and takes its fields from the query string; POST accepts only the write actions and takes the guest's input object as its JSON body. No record logic is implemented natively and src/ never reads or writes docs/.


> The RFC recommended: **Recommended option:** Option A — a method-split relay, one endpoint per tool: GET carries only the read actions (list, search, open, checklist) in the query string, POST carries only the write actions (create, append, update, status, recommend) as the guest's own input object, and both go straight to the guest through toolJson.

## Consequences

What it makes easy: the record-store web UI view becomes buildable as a plugin over five endpoints; a new guest action reaches HTTP by adding one name to one method allowlist rather than by designing a URL; the tools' input_schema stays the single description of a request across CLI, agent and HTTP; and compare-and-swap, record numbering and the inventory copy of every status keep working untouched, because the guest is still the only writer.

What it forecloses: a record has no URL of its own. GET /api/rfc?action=open&path=... is a procedure call wearing a URL, so a UI that wants to deep-link one record must link by query string, and HTTP caches and bookmarks are less useful than they would be under a REST grammar. It also declines, for now, to expose research sweep: it performs network egress and can take tens of seconds, and nothing has asked for it over HTTP.

What it costs if the context changes: if the deferred view turns out to need stable per-record URLs, id routes have to be added beside the query form — additive, not a rewrite, but two ways to address one record from then on. And the query-string vocabulary becomes a public API the moment a third-party plugin calls it; the mitigation is that the vocabulary is the guests' own input_schema, which is already kept stable for the agent. If a store action ever cannot be expressed faithfully in a query string, that read would need a body and the method split would stop paying for itself.
