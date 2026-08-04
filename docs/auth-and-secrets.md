# Authentication and secrets

This repository contains setup instructions only. It must never contain an API key, private key, JWT, password, provisioning profile, tester email, registration token, or copied credential output.

## Choose the right credential boundary

| Operation | Preferred boundary | Notes |
| --- | --- | --- |
| GitHub read/write from a human workstation | `gh auth login` or an approved enterprise SSO flow | Keep the token in the GitHub CLI credential store. |
| Sand runner provisioning | GitHub App installation | The Sand config references a local private-key path; it does not embed key material. |
| Short-lived ordinary runner registration | Repository/org registration token | Supply through the process environment and never save it. |
| App Store Connect feedback read | Named read-only `asc` profile | Validate it before fetching feedback. |
| App Store Connect feedback deletion | Separately named write-capable `asc` profile | Pass it only to the explicit final archive command. |
| Cloud deployment | Existing repository policy, OIDC, or a secret manager | Do not create a new deployment role from this template. |

## Human workstation setup

Authenticate interactively using the provider's official flow. Examples:

```bash
gh auth login
gh auth status

# Follow the approved asc CLI login/profile flow for your team.
asc auth status --profile "<READ_PROFILE>" --validate
```

Do not paste the resulting token or key into a terminal transcript, issue, pull request, agent prompt, or repository file. If a command prints a credential, stop and rotate it before continuing.

## GitHub variables and secrets

Use variables for non-secret settings, for example:

- `MOBILE_APP_DIR`
- `MOBILE_NODE_VERSION`
- `MOBILE_SANDBOX_ENABLED`
- `TESTFLIGHT_RELEASE_ENABLED`
- `SAND_RUNNER_GROUP`

Use protected secrets or a secret manager for values that cannot be derived from the repository, for example:

- an App Store Connect private key, if the release tooling cannot use a keychain;
- an encrypted signing certificate and password, if the workflow requires them;
- a short-lived runner registration token; and
- any third-party service credential used by the app's release lane.

Prefer environment-scoped secrets and approval gates. Do not use a long-lived personal access token on a self-hosted runner when a GitHub App or OIDC integration provides the needed capability.

## Runner-specific rules

- The Sand runner's GitHub App private key must be a local regular file with restrictive permissions, owned by the runner user.
- The setup script validates the key path but does not create or print a key.
- Registration tokens are read from `RUNNER_REGISTRATION_TOKEN` for one invocation and are not written to disk.
- App Store Connect profile names are configuration, not credentials; the profile's private material stays in the CLI's secure store.
- Keep logs free of environment dumps. Do not run `set -x` around auth or signing commands.

## Incident response

If a credential is exposed:

1. Revoke or rotate it at the provider immediately.
2. Remove the exposed value from local logs and shared artifacts where possible.
3. Search the Git history and CI logs for copies.
4. Recreate the credential with narrower permissions.
5. Record only the remediation pattern in `docs/agent-playbook.md`; never record the secret or private identity.
