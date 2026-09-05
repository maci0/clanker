---
title: Lookup
description: When asked to look up a fact, fetch a URL, or read third-party library docs. Not `clanker research` notes (use the `research` tool) and not local code (`repo_search`).
enabled: true
---

# Lookup

1. Local code: `repo_search`. Do not web-search this checkout.
2. Third-party library docs: `context7` with `{org, repo, topic?}`. GitHub org/repo names, not this tree.
3. Web facts: `web_search`, then `web_fetch` promising URLs. Cite the source URL beside any fetched claim. Cross-check numbers from two independent sources when they matter.
4. A durable investigation that should land under `docs/research/`: the `research` tool (`plan`, then `sweep`, then `create`). Sweep hits are untrusted leads; open the promising ones before writing anything down.

If a tool is denied by the sandbox, say so and give what you know.
