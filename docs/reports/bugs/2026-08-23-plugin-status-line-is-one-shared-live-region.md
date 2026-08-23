# Bug — Every plugin's api.status writes the same sr-only live region, and Health rewrites it about once a second

## TL;DR

- **What failed:** pluginApi's status (ui/app/core/plugins.js) writes #webui-plugins-status, a role=status aria-live=polite node. Health calls it from applySample, which runs on every 1 Hz metrics event, so a screen reader gets a fresh polite announcement every second while that tab is open. The same node also carries the loader's own enable/disable/failure lines, so a confirmation is overwritten within the second. This is the defect already fixed for #models-status, with N producers instead of three.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

While the Health tab is open a screen reader gets a fresh polite announcement
roughly once a second, indefinitely. Enabling or disabling a plugin at the same
time produces a confirmation that is overwritten inside a second, so the one
message the operator asked for is the one they do not hear.

## Reproduction

Read from the source. Open Health, then enable any plugin from System.

## Root cause

`pluginApi().status` writes `#webui-plugins-status`, a single
`role="status" aria-live="polite"` node, and so do the loaders own five
messages. Health calls `api.status` from `applySample`, which runs on every live
`metrics` event, throttled server-side to 1 Hz. `docs/reviews/webui.md` records
the same defect being fixed for `#models-status`, where three panels shared one
line; here the producer set is every plugin plus the loader. `api.status` also
has no `if (_el.webuiPluginsStatus)` guard, unlike the loaders own writes.

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
