# ADR 0007 — Plugin manifests are declarative and unsigned; distribution is out of scope

## Status

Accepted.

## Context

The plugin manifest SDK ([docs/prds/0010-plugin-manifest-sdk.md](../prds/0010-plugin-manifest-sdk.md))
formalises `*.tool.json`: a version key, a written field reference, a validator,
and a scaffolder. That much is uncontroversial — the format already existed and
was already enforced, it just had no spec and no way to check a file against it.

What is contentious is how far "third-party tool packaging and distribution"
(the roadmap's wording) should go. Three things usually travel together in a
plugin ecosystem and each is a separate decision:

1. **A package format.** What a plugin is when it is not in this repo.
2. **A fetch path.** `clanker plugins install <url>` or a registry index.
3. **Trust.** Signatures, publisher identity, revocation, a policy for what a
   plugin is allowed to declare about itself.

Options considered:

- **All three.** Matches what a mature ecosystem looks like. It also means
  standing up an index, choosing a signing scheme and a key distribution story,
  and — the part that actually decides it — writing a trust *policy*: what
  clanker does when a signature is missing, stale, or valid but from someone the
  user has never heard of. A local-first single-binary tool with no server and
  no account has nowhere to put the answer to that question.
- **A fetch path with no signing.** `clanker plugins install <url>` is twenty
  lines over the existing HTTP client. It is also the worst of the three: it
  makes running someone else's code one command easier while making it no safer,
  and it converts "you copied a file you read" into "you ran a URL". A
  half-built trust story reads as a trust story to the person relying on it.
- **A package format and nothing else.** A plugin is a directory holding a
  manifest and the module it names; `agent.tools_dir` already points at a
  directory of manifests; validation already exists. The user moves the bytes
  themselves, by whatever means they already trust.

Worth stating plainly, because it is what makes the third option defensible:
the manifest is *already* the security boundary and it is already enforced. A
guest gets no filesystem, no network, no exec, no environment and no model
access unless its manifest names them, and the host checks every call. A signed
plugin whose manifest says `"fs_prefixes": ["."]` is not safer than an unsigned
one that says the same thing. Signing answers "who wrote this", which is a real
question, but it is not the question the sandbox answers and it does not make
the sandbox's answer better.

## Decision

The manifest is a declarative, human-readable, **unsigned** local file. The SDK
ships the format, the validator and the scaffolder, plus one packaging
affordance: a `wasm` value with no path separator resolves beside its own
manifest, so `{name.tool.json, name.wasm}` in one directory is a self-contained
plugin that `agent.tools_dir` can be pointed at.

Fetching, installing, signing, publisher identity and a registry index are
explicit non-goals. Not "not yet" in the sense of a missing sprint — not until
there is a real distribution need to design them against, and then as their own
decision, together.

## Consequences

Makes easy: writing and checking a plugin outside this repo, with no new
concepts. `clanker plugins new` gives a working pair, `clanker plugins validate`
gives an answer with a file and a key in it, and the reference in
[docs/manifest.md](../manifest.md) is derived from the loader rather than from
intent. Nothing about the format forecloses a package archive or an index later;
`manifest_version` is precisely the seam a distribution format would need.

Makes hard: installing a plugin is a copy, by hand. There is no `clanker plugins
install`, no update path, no way to tell where a manifest came from, and no way
to revoke one. On a machine where several plugins come from several places,
keeping them current is the user's problem.

Costs, honestly: the sandbox is the whole of the defence, so a manifest that
over-grants is a manifest that over-grants — the validator can say
`"fs_prefixes": ["."]` is *valid*, and cannot say it is *reasonable*. The
mitigation is that a manifest is short and readable and the policy is in it,
which is only a mitigation if people read it. If plugins ever arrive by any
route other than a human copying two files they looked at, this ADR is the first
thing to revisit, and the revisit is the whole of item 3 — not a signature field
bolted onto the schema.
