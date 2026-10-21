# Onboarding Tracker

Salesforce onboarding tracker: Opportunity won → Onboarding created → auto-assigned to the least-loaded CSM within capacity → six enforced stages with per-stage timing.

## The spec

`docs/project-spec.md` is the source of truth. **Do not read it end to end.** Each task names the sections you need; read only those (find them by heading). If the spec and the code disagree, stop and ask. Never edit the spec without asking.

## Non-negotiables

- Every class declares a sharing keyword. Every SOQL declares `WITH USER_MODE` or `WITH SYSTEM_MODE`. Every DML declares `as user` / `as system` or `AccessLevel`. Every system-mode use has a one-line comment saying why.
- No hardcoded record, user, queue, profile IDs or usernames. Look up by DeveloperName / API name.
- Every object, field, validation rule, permission set, flow, custom metadata type, custom setting and Apex class has a short, useful description. Validation rules have plain-English error messages. Apex user-facing messages come from Custom Labels.
- Everything bulk-safe.
- One trigger per object, logic in handlers extending `TriggerHandler`. Add a separate class only when it earns its place.
- Tests assert behaviour, not just coverage.

## Workflow

- One build step per task, on its own `feature/*` branch.
- Plan first, then build. Stop after each step deploys and tests pass, and show me what changed before committing.
- Commit prefixes: `feat:`, `fix:`, `test:`, `docs:`, `chore:`

## Commands

```bash
sf project deploy start --target-org <default org>
sf apex run test --test-level RunLocalTests --wait 10 --result-format human
sf data query --query "SELECT ..."
```

Check a command's flags with `--help` before using an unfamiliar one.
