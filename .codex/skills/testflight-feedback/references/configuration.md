# TestFlight feedback configuration

The helper reads JSON under `.codex/skills/testflight-feedback/config/`. `settings.json`, `allowed-emails.json`, and the app-specific `baseline.json` are ignored; the opaque `handled-feedback.json` ledger is intentionally trackable. Start from the `.example` files and never add completed settings, allowlist, or baseline files to Git.

## `settings.json`

Required fields:

```json
{
  "schema_version": 1,
  "app_id": "<APP_STORE_CONNECT_APP_ID>",
  "read_profile": "<READ_ONLY_ASC_PROFILE>",
  "delete_profile": "<SEPARATE_WRITE_ASC_PROFILE>",
  "github_repository": "<OWNER>/<REPOSITORY>",
  "base_branch": "main",
  "github_host": "github.com"
}
```

The app ID is an App Store Connect numeric identifier, not a bundle ID. The read profile and delete profile must be different names. The helper accepts environment overrides for temporary use: `TESTFLIGHT_APP_ID`, `TESTFLIGHT_READ_PROFILE`, `TESTFLIGHT_DELETE_PROFILE`, `TESTFLIGHT_GITHUB_REPOSITORY`, `TESTFLIGHT_BASE_BRANCH`, and `TESTFLIGHT_GITHUB_HOST`.

## `allowed-emails.json`

Store only the exact tester emails that the app owner approved for this private workflow:

```json
{
  "schema_version": 1,
  "emails": ["tester@example.invalid"]
}
```

The example domain above is intentionally non-routable. Replace it locally; never commit real addresses. Matching trims surrounding whitespace and is case-insensitive, but does not perform aliases, substring matches, or domain-wide matches.

## `baseline.json`

Set the UTC timestamp at which the workflow became active:

```json
{
  "ignore_created_at_or_before": "<SET_APP_FEEDBACK_BASELINE_UTC_TIMESTAMP>"
}
```

Replace the placeholder with the UTC timestamp at which this app's workflow became active. The helper fails closed until an explicit timestamp is configured; feedback at or before it is ignored unless the operator explicitly requests historical intake.

## `handled-feedback.json`

Track only opaque submission fingerprints:

```json
{
  "schema_version": 1,
  "submission_id_sha256": []
}
```

Never replace fingerprints with raw submission IDs or feedback content.

## Auth expectations

The helper invokes `asc --profile <name> ...` and suppresses command output unless a safe status is needed. Authenticate profiles through the approved App Store Connect CLI flow. Do not put `.p8` key material, passwords, or JWTs in these JSON files.
