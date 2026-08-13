# PRD — `write-goal` Skill / Tool for Agent Harness

**Status:** Draft
**Owner:** Harness / Agent Runtime
**Feature:** `write-goal`
**Type:** Built-in skill with optional structured tool integration

## 1. Summary

Implement a built-in `write-goal` capability that helps users turn a rough task, idea, or desired outcome into a **precise, execution-ready goal specification**.

`write-goal` does **not** execute the goal, run an autonomous loop, or implement goal-mode behavior.

Its responsibility is strictly:

> Convert fuzzy user intent into a clear completion contract that another agent, harness, or goal runner can reliably execute and know when to stop.

The capability should behave similarly to Kimi Code's `write-goal` skill, which describes its purpose as turning rough intent into a goal with a clear **finish line, proof, boundaries, and stop rule**. Kimi's own goal design notes make the same distinction and explicitly describe `write-goal` as an auxiliary capability for constructing good goals.

---

# 2. Problem

Users frequently give coding agents requests such as:

> "Clean up the auth code."

> "Make this service production ready."

> "Fix the flaky tests."

> "Improve the performance."

These are understandable to a human, but poor long-running agent goals because they do not define:

* what exact state should exist when the work is finished;
* how the agent can prove that state exists;
* what is inside or outside the scope;
* how aggressively the agent should iterate;
* when the agent should stop instead of continuing indefinitely.

The result is unnecessary clarification during execution, scope creep, premature completion, endless polishing, and agents claiming success without sufficient verification.

The harness needs a lightweight mechanism for turning intent into a **verifiable completion contract before execution begins**.

---

# 3. Product Goal

Provide a `write-goal` capability that produces goals which answer five questions:

1. **End state** — What must be true when the task is finished?
2. **Proof** — What observable evidence demonstrates that it is finished?
3. **Boundaries** — What may and may not be changed?
4. **Loop** — How should the agent investigate, implement, test, and iterate?
5. **Stop rule** — When must the agent stop and report instead of continuing?

The resulting goal should be usable directly by:

* an autonomous coding agent;
* a future harness goal runner;
* a subagent;
* a task execution API;
* a human copying the goal into another coding agent.

---

# 4. Non-goals

`write-goal` MUST NOT:

* start autonomous execution;
* create or manage persistent goal state;
* implement a goal state machine;
* automatically modify project files;
* execute shell commands that change the workspace;
* create implementation plans unless needed to define completion;
* invent product requirements;
* silently expand the user's requested scope;
* add arbitrary token, turn, cost, or time limits;
* turn every ordinary prompt into a formal goal.

Goal execution and goal lifecycle management are separate harness capabilities.

---

# 5. Core Product Principle

`write-goal` is best understood as a **compiler**:

```text
rough user intent
        ↓
context inspection
        ↓
material clarification
        ↓
completion contract
        ↓
execution-ready goal
```

It transforms intent rather than executing it.

---

# 6. Invocation

The capability SHOULD support explicit invocation:

```text
/write-goal Fix the flaky integration tests
```

or:

```text
/write-goal
```

followed by the user's task.

It SHOULD also be available as a named skill:

```text
write-goal
```

so the agent may invoke it when the user says things such as:

> Help me write a goal for fixing this.

> Turn this into a proper agent task.

> Make this task precise enough to run autonomously.

The harness MAY automatically suggest `write-goal` for obviously underspecified long-running work, but SHOULD NOT silently replace ordinary user requests with `write-goal`.

Explicit user invocation always wins.

---

# 7. Interaction Model

## 7.1 Initial input

The skill receives:

```text
user intent
+ conversation context
+ workspace context when available
```

Example:

```text
Make our Kubernetes deployment safer during rollouts.
```

The skill first determines whether enough information already exists to write a useful goal.

---

## 7.2 Inspect before asking

When appropriate, the skill SHOULD use read-only harness capabilities to resolve questions itself.

For example:

* inspect repository structure;
* inspect existing tests;
* inspect CI configuration;
* inspect package scripts;
* inspect deployment manifests;
* inspect relevant documentation;
* inspect existing coding conventions.

It SHOULD NOT ask the user questions whose answers are already available from the workspace.

Example:

Instead of asking:

> What test command should be used?

the skill should discover:

```text
pnpm test
```

if that information is readily available.

---

## 7.3 Clarification

The skill asks questions only when the answer would materially change the goal.

Good clarification:

> Should the change preserve the existing public API, or may callers be updated?

Bad clarification:

> What programming language is this project?

when the repository already makes this obvious.

Questions SHOULD:

* be few;
* be concrete;
* focus on scope or completion;
* preferably offer useful choices;
* be grouped when possible.

A single drafting interaction SHOULD normally ask no more than **1–4 questions**.

---

# 8. Required Goal Structure

Every completed goal MUST contain the following conceptual fields.

## 8.1 Objective

A concise description of the desired final state.

Example:

```text
Eliminate the currently reproducible flaky behavior in the integration
test suite without weakening test assertions or disabling tests.
```

The objective describes the **outcome**, not a sequence of commands.

---

## 8.2 Completion Criteria

Concrete conditions that must all be true before the task may be considered finished.

Example:

```text
- The identified flaky tests no longer fail under repeated execution.
- Existing assertions remain equivalent or stronger.
- No tests are skipped, disabled, or quarantined to achieve passing results.
- The normal project test suite passes.
```

Criteria SHOULD be:

* observable;
* binary where possible;
* tied to the user's requested outcome.

Avoid vague criteria such as:

```text
Code quality is improved.
```

---

## 8.3 Proof / Verification

Define how completion will be demonstrated.

Example:

```text
Run the affected tests repeatedly enough to reproduce the previous failure
conditions, then run the repository's standard test suite. Report the
commands executed and their final results.
```

Proof may include:

* tests;
* builds;
* linting;
* type checking;
* benchmarks;
* runtime observations;
* API responses;
* screenshots;
* generated artifacts;
* diff inspection.

A completion criterion without a reasonable proof mechanism SHOULD be treated as weak.

---

## 8.4 Boundaries

State important constraints and out-of-scope work.

Example:

```text
Do not disable tests, reduce assertions, change externally visible API
behavior, or perform unrelated refactoring.
```

Boundaries may originate from:

* explicit user requirements;
* repository instructions;
* compatibility requirements;
* safety constraints;
* known architecture constraints.

The skill MUST NOT invent arbitrary restrictions merely to make the goal look detailed.

---

## 8.5 Execution Loop

Define the expected general behavior while pursuing the goal.

Example:

```text
Reproduce the failure, identify its cause, make the smallest appropriate
fix, run focused verification, and iterate until the completion criteria
are satisfied.
```

This is intentionally higher-level than an implementation plan.

The goal should leave the executing agent free to choose techniques based on what it discovers.

---

## 8.6 Stop Rule

Define conditions under which the executing agent should stop without claiming completion.

Example:

```text
Stop and report if completion requires changing the public API, removing
test coverage, accessing unavailable external credentials, or making a
product decision not established by the repository or user.
```

The stop rule prevents an autonomous agent from forcing progress through genuine blockers.

---

# 9. Optional Fields

The generated goal MAY additionally contain:

### Context

Facts useful to execution but not themselves requirements.

### Known symptoms

Reproduction details, error messages, affected components, etc.

### Assumptions

Only assumptions that materially influence the goal.

### Deliverables

Specific files, artifacts, documentation, or outputs requested by the user.

### User-specified budget

Only when explicitly requested.

Examples:

```text
Stop after 20 agent turns.
```

```text
Do not spend more than 30 minutes investigating.
```

```text
Maximum 500k tokens.
```

Budgets MUST be opt-in rather than invented by `write-goal`, matching the separation described in Kimi's goal design notes.

---

# 10. Output Format

The default user-facing output SHOULD remain readable natural language rather than exposing raw internal schema.

Recommended format:

```markdown
## Goal

<concise objective>

### Completion criteria

- ...
- ...

### Verification

- ...

### Boundaries

- ...

### Execution approach

<high-level loop>

### Stop and report if

- ...
```

The output SHOULD be directly copyable into an agent or goal runner.

---

# 11. Structured Representation

Internally, the harness SHOULD represent the result in structured form even if the UI renders Markdown.

Example:

```json
{
  "objective": "Eliminate the reproducible flaky behavior in the integration test suite.",
  "completionCriteria": [
    "Affected tests pass under repeated execution.",
    "No tests are disabled or assertions weakened.",
    "The normal repository test suite passes."
  ],
  "verification": [
    "Run affected tests repeatedly.",
    "Run the normal repository test suite."
  ],
  "boundaries": [
    "Do not disable tests.",
    "Do not weaken assertions.",
    "Do not perform unrelated refactoring."
  ],
  "executionLoop": "Reproduce, diagnose, fix, verify, and iterate.",
  "stopRules": [
    "Stop if fixing the issue requires an unresolved product decision.",
    "Stop if required external credentials are unavailable."
  ]
}
```

This allows future harness components to consume goals without parsing prose.

---

# 12. Tool Interface

If implemented as a model-callable harness tool, the logical interface SHOULD resemble:

```text
write_goal(
    intent,
    context?,
    existing_goal?
) -> GoalDraft
```

Suggested result:

```text
GoalDraft {
    objective
    completion_criteria[]
    verification[]
    boundaries[]
    execution_loop
    stop_rules[]
    assumptions[]
    unresolved_questions[]
}
```

The tool SHOULD NOT directly start execution.

A separate capability can consume the returned `GoalDraft`.

For example:

```text
write_goal(...)
      ↓
GoalDraft
      ↓
start_goal(GoalDraft)
```

This separation is intentional.

---

# 13. Skill Behavior

The `SKILL.md` equivalent SHOULD instruct the model to follow this sequence:

```text
1. Understand the user's intended outcome.
2. Inspect available context before asking questions.
3. Identify missing information that materially affects completion.
4. Ask only those questions.
5. Define a concrete end state.
6. Define observable completion evidence.
7. Capture important boundaries.
8. Define a sensible iterative execution loop.
9. Define explicit stop conditions.
10. Review the draft for invented requirements.
11. Present the goal to the user.
```

Before returning the goal, the skill SHOULD internally check:

```text
Can an independent agent tell exactly when this is finished?

Can it prove completion?

Does it know what not to change?

Can it continue when the first attempted solution fails?

Does it know when to stop and ask for help?
```

If any answer is no, the goal is incomplete.

---

# 14. Handling Ambiguity

Not every ambiguity requires clarification.

The skill SHOULD distinguish between:

### Harmless implementation ambiguity

Example:

```text
Should the fix use a map or a set internally?
```

Do not ask.

The executing agent can decide.

### Material product ambiguity

Example:

```text
Should the API remain backward compatible?
```

Ask when the answer affects acceptable completion.

### Discoverable ambiguity

Example:

```text
What command runs the tests?
```

Inspect the workspace.

### Unresolvable ambiguity

Example:

```text
Make it fast enough.
```

Ask what observable performance target defines "fast enough" if no existing benchmark or requirement establishes it.

---

# 15. Do Not Over-specify

A good goal defines the destination without prescribing every implementation step.

Bad:

```text
Open src/auth.ts, add a mutex on line 82, change retryCount to 3,
then add two Jest tests.
```

Better:

```text
Eliminate the authentication race condition while preserving current
external behavior. Add regression coverage reproducing the race and verify
the normal test suite passes.
```

The executing agent must retain freedom to discover that the originally assumed implementation is wrong.

---

# 16. Existing Goal Refinement

`write-goal` SHOULD accept an existing draft:

```text
/write-goal improve
```

or equivalent.

The skill should identify weaknesses such as:

* unverifiable completion;
* missing stop rule;
* excessive implementation prescription;
* unclear scope;
* contradictory criteria;
* requirements disguised as assumptions;
* missing proof;
* ambiguous terminology.

It should preserve requirements that are already explicit rather than rewriting the goal unnecessarily.

---

# 17. User Control

Before handing the goal to an executor, the user SHOULD be able to:

* edit the generated goal;
* answer unresolved questions;
* regenerate only a specific section;
* add/remove boundaries;
* change completion criteria;
* copy the goal;
* explicitly start execution through a separate action.

Drafting a goal MUST NOT itself imply consent to execute it.

---

# 18. Auto / Unattended Mode

Interactive goal drafting and unattended execution are different concerns.

Kimi currently exposes an edge case here: its `write_goal` skill is interactive and uses user questions, while auto permission mode can disable the question mechanism. This has been reported as a UX conflict in Kimi Code.

The harness SHOULD avoid coupling goal drafting to execution permission mode.

Recommended rule:

> Explicit user invocation of `write-goal` creates an interactive drafting session regardless of the permission policy that would later apply to goal execution.

If interactive input genuinely cannot be obtained, the skill SHOULD produce a best-effort draft and clearly expose unresolved assumptions rather than silently inventing answers.

---

# 19. Example

User:

```text
/write-goal Fix our Terraform module pipeline. Versioning keeps getting
messed up and releases occasionally publish the wrong module.
```

Possible output:

```markdown
## Goal

Make Terraform module releases deterministic so each release publishes
the intended module version and cannot silently publish a different
version.

### Completion criteria

- The pipeline derives or receives the module version from one
  authoritative source.
- The version being published is visible before publication.
- A mismatch between the requested and resolved version causes the
  pipeline to fail rather than publish.
- Existing supported module release workflows continue to work.
- Regression coverage exists for the identified failure mode.

### Verification

Reproduce or cover the current failure condition, run the relevant
pipeline/unit tests, and demonstrate both a successful valid release path
and rejection of a mismatched version.

### Boundaries

Do not redesign unrelated Terraform modules or change their public
interfaces unless required to fix the release mechanism.

### Execution approach

Trace how versions flow through the current release process, identify the
source of inconsistency, make the smallest coherent correction, add
regression protection, and iterate against the verification criteria.

### Stop and report if

Completion requires choosing a new organization-wide versioning policy
that is not established by the repository or existing process.
```

Notice that the goal does not tell the agent exactly which file to modify or how the bug must be implemented.

---

# 20. Functional Requirements

**FR-1 — Explicit invocation**
The harness MUST expose `write-goal` as an explicit skill or command.

**FR-2 — Rough-intent input**
The skill MUST accept incomplete natural-language requests.

**FR-3 — Context awareness**
The skill SHOULD use available conversation and read-only workspace context.

**FR-4 — Material clarification only**
The skill SHOULD ask questions only when answers materially affect completion or scope.

**FR-5 — Completion contract**
Every final goal MUST include an end state, verification/proof, boundaries, execution loop, and stop rule.

**FR-6 — No execution**
`write-goal` MUST NOT start goal execution.

**FR-7 — No invented budgets**
Time, token, cost, or turn limits MUST only be included when supplied by the user.

**FR-8 — Structured output**
The harness SHOULD expose a machine-readable representation of the goal.

**FR-9 — Editable output**
The user MUST be able to modify the draft before execution.

**FR-10 — Refinement**
The skill SHOULD support improving an existing goal without discarding valid requirements.

**FR-11 — Best-effort fallback**
When interaction is unavailable, unresolved information MUST be surfaced instead of silently invented.

---

# 21. Acceptance Criteria

The feature is ready when all of the following are true:

* A vague coding request can be converted into a structured goal.
* The resulting goal contains a checkable final state.
* Completion criteria can be evaluated independently of the model that wrote them.
* Verification evidence is explicitly specified.
* Important scope boundaries are retained.
* A stop condition exists for external blockers or unresolved decisions.
* The draft avoids prescribing implementation details unnecessarily.
* Workspace facts are discovered rather than unnecessarily asked of the user.
* User requirements are not silently expanded.
* No budget is added unless requested.
* `write-goal` never starts autonomous execution itself.
* An existing draft can be refined.
* The same structured goal can later be consumed by another harness component.

---

# 22. Success Metrics

Useful product-level metrics include:

* percentage of generated goals accepted without editing;
* average number of clarification questions;
* percentage of executed goals that terminate with objectively verifiable evidence;
* frequency of execution-time clarification requests;
* percentage of goals stopped because their completion criteria were ambiguous;
* user edits by field, especially completion criteria and boundaries;
* rate of goals that require scope correction after execution begins.

The desired outcome is not simply "more detailed prompts."

The desired outcome is:

> **Fewer ambiguous execution loops because the agent knows exactly what success means before it starts.**

---

# 23. Future Extensions

These should remain separate from the initial `write-goal` implementation:

```text
write-goal
    ↓
GoalDraft
    ├── start-goal
    ├── delegate-goal
    ├── save-goal
    ├── estimate-goal
    └── validate-goal
```

A future `validate-goal` capability could score an existing goal for:

* verifiability;
* ambiguity;
* scope completeness;
* evidence quality;
* autonomy suitability;
* stop-rule quality.

A future goal runner may then consume exactly the structured contract emitted by `write-goal`, without changing the drafting feature itself.

---

# 24. Product Definition

The simplest useful definition of the feature is:

> **`write-goal` helps a user define what "done" means before an agent starts doing the work.**

Everything else should serve that purpose.
