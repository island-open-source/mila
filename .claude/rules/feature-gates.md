# Feature Gates for Optional Features

When refactoring optional features that have multi-step setup flows (like diarization):

## Preserve `isConfigured` invariants
`isConfigured` must mean "enabled AND ready to use" — never just "enabled." If you remove a field that was part of the `isConfigured` guard (e.g., removing `hfToken` from `isEnabled && !hfToken.isEmpty`), you must replace it with an equivalent readiness check (e.g., `status.isGood`).

**Why:** Without a readiness check, the app will attempt to launch subprocesses or pipelines that are doomed to fail because dependencies aren't verified. This wastes user time and produces confusing errors.

## Audit all callers when removing a model property
When removing a property from a settings model, search for every reference — not just direct reads, but also compound conditions where the property served as an implicit guard. The compiler will catch direct references but won't catch weakened boolean logic.
