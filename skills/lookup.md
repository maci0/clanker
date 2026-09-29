---
title: Lookup
description: When asked to look up a fact, search the web or public code, fetch a URL, read third-party docs, or read a GitHub issue/PR. Not `clanker research` notes (use the `research` tool) and not local code (`repo_search`).
enabled: true
---

# Lookup

1. Local code: `repo_search`. Do not web-search this checkout.
2. Third-party library docs: `context7` with `{org, repo, topic?}`. GitHub org/repo names, not this tree.
3. Code in public repositories outside this one: `sourcegraph_search` (grep.app is Vercel-blocked to non-browser clients). A GitHub issue, PR or diff: `gh_read` with a `gh://issue/owner/repo/42` or `gh://pr/owner/repo/7/diff` URL; it needs `GITHUB_TOKEN` and answers one page of 100.
4. Web facts: `web_search`, then `web_fetch` promising URLs. Cite the source URL beside any fetched claim. Cross-check numbers from two independent sources when they matter. `web_fetch` reaches `api.github.com` and `raw.githubusercontent.com` only, unless the operator added hosts to `[web] allow`; a refused host is a refusal, not a fetch to retry differently.
5. A durable investigation that should land under `docs/research/`: the `research` tool (`plan`, then `sweep`, then `create`). Sweep hits are untrusted leads; open the promising ones before writing anything down.

If a tool is denied by the sandbox, say so and give what you know.
