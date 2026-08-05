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

## Where values come from

Use these sources when filling the placeholders in the README and runner scripts. The values themselves belong in a private shell profile, the operating system credential store, or GitHub's protected settings—not in this repository.

| Value | Where to obtain or choose it |
| --- | --- |
| GitHub organization, repository, and protected default branch | The app repository URL and its GitHub repository settings. The branch must be the protected default branch described in [app setup](app-setup.md#5-github-setup). |
| GitHub App ID | The numeric App ID shown in the GitHub App's settings under the owning organization. Install that app in the organization with the permissions described in [Sand runner setup](sand-runner.md#configure-the-operator-environment). |
| GitHub App private-key path | Create/download the App's private key through GitHub App administration, save it as a local regular file, and set the environment variable to its path. The key itself must never enter Git. |
| Sand VM image digest | Select an approved macOS image with the Tart Guest Agent and record its immutable `@sha256:` reference. The required image and host checks are in [Sand runner prerequisites](sand-runner.md#prerequisites). |
| Runner group, confirmation, name, and label | Create or select an empty dedicated group in the organization's Actions settings. Choose a unique runner name and make the label match the workflow `runs-on` label; review [Sand runner setup](sand-runner.md#configure-the-operator-environment). |
| TestFlight app ID | The numeric App Store Connect app ID from the app record—not the bundle identifier. See the [TestFlight configuration contract](../.codex/skills/testflight-feedback/references/configuration.md#settingsjson). |
| TestFlight profile names | Names created through the approved `asc` CLI authentication flow. Keep read and write profiles separate; see [TestFlight auth profiles](testflight-feedback.md#auth-profiles). |
| Ordinary runner registration token | A short-lived token from the repository or organization Actions runner settings, used only for the one fallback-runner invocation. |
| Fallback runner version and archive SHA-256 | Pin a release from the official GitHub Actions runner releases and independently verify the ARM64 archive digest before using the fallback script. |

## GitHub variables and secrets

Use variables for non-secret settings, for example:

- `MOBILE_APP_DIR`
- `MOBILE_NODE_VERSION`
- `MOBILE_SANDBOX_ENABLED`
- `TESTFLIGHT_RELEASE_ENABLED`

`SAND_RUNNER_GROUP` is a local setup variable consumed by the Sand scripts, not a GitHub Actions variable; see the [README environment setup](../README.md#configure-environment-variables).

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
