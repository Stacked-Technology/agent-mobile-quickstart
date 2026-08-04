---
name: testflight-feedback
description: Safely fetch, triage, and optionally archive private App Store Connect TestFlight feedback for a mobile app, keeping tester data local and requiring explicit read/delete profile separation. Use when an agent needs to inspect TestFlight feedback, implement an actionable mobile fix from it, or complete the confirmed feedback archive workflow; do not use for App Store reviews, crash-only diagnostics, or TestFlight uploads.
---

# TestFlight feedback

Use the bundled helper to turn private TestFlight feedback into a reviewable app change without leaking tester data into the repository, logs, pull requests, or chat.

## Guardrails

- Treat feedback JSON, comments, email addresses, submission IDs, screenshot URLs, and screenshots as private.
- Keep fetched artifacts only under the repository's gitignored `tmp/testflight-feedback/` directory. Never stage, commit, paste, or quote them.
- Use a read-only App Store Connect profile for listing and a separately named, validated write-capable profile only for the final explicit archive command.
- Do not delete a record before the implementation is pushed and a private-safe pending archive comment is present on the draft PR.
- Eligibility is an exact normalized email match against the local ignored allowlist. Missing or malformed configuration fails closed.
- Never merge a PR or deploy production from this skill.
- Do not run concurrent feedback intakes or archive operations for the same repository.

## Configuration

Run the setup helper once in the app repository:

```bash
scripts/init_testflight_feedback.sh
```

Fill in the ignored `settings.json`, `allowed-emails.json`, and app-specific `baseline.json` under `config/` using [configuration.md](references/configuration.md). The opaque handled ledger is safe to track; commit the ledger update after triage and before any archive operation. Validate the named read profile before fetching:

```bash
asc auth status --profile '<READ_ONLY_PROFILE>' --validate
```

The skill never creates, prints, or stores credentials. Keep App Store Connect private keys in the CLI's secure store or an approved secret manager.

## Intake workflow

1. Create a clean `agent/testflight-feedback-<suffix>` branch from the default branch and open one draft PR targeting that branch's base.
2. Run the helper from the app repository:

   ```bash
   python3 .codex/skills/testflight-feedback/scripts/fetch_feedback.py fetch
   ```

3. Inspect each private record and screenshot locally. Do not print private JSON to the terminal.
4. Group feedback only when one cohesive app change addresses it. Ask for a product decision when the feedback is ambiguous or not actionable.
5. Mark a selected record after triage:

   ```bash
   python3 .codex/skills/testflight-feedback/scripts/fetch_feedback.py \
     mark-handled --feedback <PRIVATE_FEEDBACK_JSON_PATH>
   ```

6. Implement the smallest complete fix, add regression coverage where practical, and run the app repository's checks.
7. Generate a pending marker for the pushed commit:

   ```bash
   python3 .codex/skills/testflight-feedback/scripts/fetch_feedback.py \
     archive-marker --pr-number <PR_NUMBER> \
     --feedback <PRIVATE_FEEDBACK_JSON_PATH>
   ```

   Put the returned marker as the first line of one top-level PR comment, followed by the exact pending-status line and only a private-safe product-problem paraphrase and implementation summary. Do not include identity, IDs, URLs, screenshots, email addresses, or verbatim feedback.

   ```markdown
   <pendingCommentMarker>
   ### Addressed TestFlight feedback
   - Product problem: <private-safe paraphrase>
   - Implementation: <short description>
   - Deletion status: pending confirmation.
   ```

8. After explicit confirmation, archive the addressed records with the separate write profile:

   ```bash
   python3 .codex/skills/testflight-feedback/scripts/fetch_feedback.py \
     archive --pr-number <PR_NUMBER> \
     --delete-profile '<WRITE_PROFILE>' \
     --feedback <PRIVATE_FEEDBACK_JSON_PATH>
   ```

   The command verifies the pending marker, handled ledger, app/profile provenance, and explicit delete profile before invoking the destructive App Store Connect operation. If deletion or confirmation-comment publication fails, stop and report the result as unconfirmed until manually verified.

9. Remove the private run directory after confirmation. Keep only the opaque handled fingerprint ledger in the app repository.

## Failure handling

- Stop on missing configuration, invalid profile validation, an unreserved branch, a non-draft PR, an unexpected app ID, or a malformed local artifact.
- Stop if a private value appears in output or a proposed PR comment.
- Treat partial archive results as unresolved. Do not rerun blindly; inspect the command's output and App Store Connect state first.
- If the requested change affects legal acceptance, privacy, consent, or accessibility, read and apply the app repository's relevant review checklist before opening the PR.

## Bundled resources

- `scripts/fetch_feedback.py` — deterministic fetch, eligibility, ledger, marker, and explicit archive helper.
- `references/configuration.md` — local configuration contract and privacy notes.
