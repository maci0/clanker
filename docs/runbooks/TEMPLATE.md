# Runbook — <recurring symptom>

## TL;DR

- **Use when:** <observable trigger and preconditions>
- **Recover by:** <one-sentence current procedure>
- **Verify with:** <the proof that normal operation is restored>

## Scope and preconditions

State precisely when this runbook applies and when it does not. Link the
underlying report and name any required access, environment, or version.

## Diagnose

Give the shortest safe checks in decision order. State what each result means
and when to stop rather than applying a recovery meant for another symptom.

## Recover

Give the minimal, reversible steps that restore the service or development
flow. Explain any action with material side effects before its command.

## Verify

State the command, test, or observation that proves recovery. Include the
expected result and a next step if verification fails.

## Escalate or follow up

Name the condition that requires a new investigation, any cleanup, and the
owner or issue path when applicable.

## References

- Report: <link>
- Code or configuration: <paths>
- Last verified: <date and version or commit>
