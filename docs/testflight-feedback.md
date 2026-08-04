# TestFlight feedback setup

The bundled `testflight-feedback` skill turns private App Store Connect feedback into local artifacts and a reviewable implementation workflow. It is intentionally fail-closed: missing configuration, missing tester eligibility, an unreserved branch, or an unvalidated profile stops the operation.

## One-time local setup

From the app repository that contains the skill:

```bash
scripts/init_testflight_feedback.sh
```

Edit the ignored files under `.codex/skills/testflight-feedback/config/`:

- `settings.json` — app ID, read profile, repository, and base branch;
- `allowed-emails.json` — exact normalized tester emails approved for this private workflow;
- `baseline.json` — the app-specific UTC timestamp at which this workflow became active.

The repository tracks only the opaque `handled-feedback.json` ledger. Commit its update after triage; never replace its fingerprints with raw IDs or feedback content.

Do not commit the local settings/allowlist files or reproduce their values in documentation, PRs, or agent messages.

## Auth profiles

Create the read-only App Store Connect profile using the approved `asc` CLI flow, then validate it:

```bash
asc auth status --profile '<READ_PROFILE>' --validate
```

Configure a separately named write-capable profile only if the team explicitly wants to archive/delete addressed feedback. Never pass the read profile to a delete command. The skill does not create keys, upload credentials, or print auth output.

## Safe lifecycle

1. Reserve one draft PR from an `agent/testflight-feedback-*` branch.
2. Fetch feedback with the read-only profile into `tmp/testflight-feedback/`.
3. Inspect the private JSON/screenshots locally and decide what is actionable.
4. Mark only addressed submissions in the opaque handled ledger.
5. Implement and test the app change.
6. Post a private-safe top-level PR comment using the generated pending marker.
7. Only after explicit confirmation, run the delete operation with the separate write profile.
8. Remove the local feedback run after the archive is confirmed.

The skill never treats a screenshot URL, submission ID, tester identity, or verbatim comment as safe PR content.

## Do not use this skill for

- App Store reviews;
- crash-only diagnostics;
- TestFlight upload or release promotion; or
- feedback from a tester who is not in the local, explicitly approved allowlist.
