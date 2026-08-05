# Mobile agent quickstart

This repository is a reusable, app-neutral starting point for letting coding agents work on mobile apps safely. It centralizes the operational pieces that are easy to forget:

- a private TestFlight feedback workflow with local-only artifacts;
- a generic Apple Silicon Sand/VM runner setup for GitHub Actions;
- an optional plain macOS self-hosted runner fallback;
- app, signing, App Store Connect, GitHub, and CI setup checklists; and
- a small agent playbook for recording durable, non-secret mobile knowledge.

It intentionally does not contain an app, credentials, tester identities, bundle IDs, organization settings, or production deployment policy. It references the maintained public Sand source as a pinned build dependency; copy the templates into an app repository and fill in the app-specific placeholders there.

## Start here

1. Read [docs/app-setup.md](docs/app-setup.md) and identify the app-specific values.
2. Read [docs/auth-and-secrets.md](docs/auth-and-secrets.md) before creating any local profile or GitHub secret.
3. Configure the isolated runner with [docs/sand-runner.md](docs/sand-runner.md).
4. Add the TestFlight skill from [.codex/skills/testflight-feedback/SKILL.md](.codex/skills/testflight-feedback/SKILL.md).
5. Copy the workflow templates from [templates/github/workflows](templates/github/workflows) into the app repository only after reviewing their `runs-on`, app path, branch guard, and release commands.

## Configure environment variables

Use a private shell profile, an untracked local file, or GitHub's protected settings for these values. Do not commit the file or paste real values into issues, pull requests, agent prompts, or logs. The `plan` commands are safe before authentication; `validate`, `configure-github --apply`, and `install --apply` need the values marked as required below. The source and revision already default to the public pinned Sand fork.

For a local Sand setup, start with this placeholder-only profile:

```bash
export SAND_GITHUB_ORGANIZATION='<ORG>'
export SAND_GITHUB_REPOSITORY='<ORG>/<REPOSITORY>'
export SAND_GITHUB_APP_ID='<APP_ID>'
export SAND_GITHUB_APP_KEY_PATH="$HOME/.config/sand/github-app.pem"
export SAND_VM_IMAGE='ghcr.io/<OWNER>/<IMAGE>@sha256:<DIGEST>'
export SAND_RUNNER_GROUP='mobile-sandbox'
export SAND_RUNNER_GROUP_CONFIRM='mobile-sandbox'
export SAND_RUNNER_LABEL='mobile-sandbox'
export SAND_RUNNER_NAME='mobile-sandbox-host-01'
export SAND_BASE_BRANCH='main'
export SAND_ALLOWED_WORKFLOWS='mobile-ci.yml,mobile-testflight.yml'
export SAND_SOURCE_DIR="$HOME/Github/sand"
export SAND_INSTALL_PATH="$HOME/.local/bin/sand"
```

The [authentication and secrets guide](docs/auth-and-secrets.md#where-values-come-from) explains where each collected value comes from. The [Sand runner guide](docs/sand-runner.md#configure-the-operator-environment) explains the complete environment, defaults, and apply order.

| Variable | Required for | Where to obtain or choose it |
| --- | --- | --- |
| `SAND_GITHUB_ORGANIZATION` | Sand validation/configuration | The organization that owns the app repository and runner group; see [GitHub setup](docs/app-setup.md#5-github-setup). |
| `SAND_GITHUB_REPOSITORY` | Sand validation/configuration | The app repository as `OWNER/REPOSITORY`; see [GitHub setup](docs/app-setup.md#5-github-setup). |
| `SAND_GITHUB_APP_ID` | Sand GitHub configuration | The numeric ID in the GitHub App settings; see [where values come from](docs/auth-and-secrets.md#where-values-come-from). |
| `SAND_GITHUB_APP_KEY_PATH` | Sand validation/configuration | A local path to the GitHub App private key; create it through GitHub App administration and follow the [key handling rules](docs/auth-and-secrets.md#runner-specific-rules). |
| `SAND_VM_IMAGE` | Sand validation/install | An approved macOS VM image with a Tart Guest Agent and an immutable digest; see [Sand prerequisites](docs/sand-runner.md#prerequisites). |
| `SAND_RUNNER_GROUP` | Sand configuration | An empty, dedicated organization Actions runner group; see [runner-group setup](docs/sand-runner.md#configure-the-operator-environment). |
| `SAND_RUNNER_GROUP_CONFIRM` | `configure-github --apply` | Repeat `SAND_RUNNER_GROUP` exactly as an explicit mutation confirmation; see [runner-group safety](docs/sand-runner.md#configure-the-operator-environment). |
| `SAND_RUNNER_NAME` | Sand validation/install | A unique name for this host's ephemeral runner; choose it locally and see [runner setup](docs/sand-runner.md#configure-the-operator-environment). |
| `SAND_RUNNER_LABEL` | Sand config/workflows | A narrow label that matches the app workflow's `runs-on`; see [workflow labels](docs/sand-runner.md#workflow-labels). |
| `SAND_BASE_BRANCH` | Sand GitHub configuration | The protected default branch of the app repository; see [GitHub setup](docs/app-setup.md#5-github-setup). |
| `SAND_ALLOWED_WORKFLOWS` | Sand config/workflow restriction | The copied workflow filenames, comma-separated; see [workflow template setup](docs/sand-runner.md#read-only-first). |
| `SAND_SOURCE_REPOSITORY` and `SAND_REVISION` | Optional fork override | Leave the defaults in place, or set both to another public HTTPS GitHub fork and full commit SHA; see [Sand source](docs/sand-runner.md#sand-source). |
| `SAND_SOURCE_DIR`, `SAND_INSTALL_PATH`, `SAND_BIN` | Optional local paths | Choose user-owned paths. `SAND_INSTALL_PATH` feeds the runner's default `SAND_BIN`; see [path configuration](docs/sand-runner.md#configure-the-operator-environment). |

### Optional TestFlight environment overrides

The preferred source of TestFlight settings is the ignored JSON configuration created by [`init_testflight_feedback.sh`](scripts/init_testflight_feedback.sh). These environment variables are temporary overrides for local commands; use placeholders until you have read the [TestFlight configuration contract](.codex/skills/testflight-feedback/references/configuration.md#settingsjson).

```bash
export TESTFLIGHT_APP_ID='<APP_STORE_CONNECT_APP_ID>'
export TESTFLIGHT_READ_PROFILE='<READ_ONLY_ASC_PROFILE>'
export TESTFLIGHT_DELETE_PROFILE='<SEPARATE_WRITE_ASC_PROFILE>'
export TESTFLIGHT_GITHUB_REPOSITORY='<OWNER>/<REPOSITORY>'
export TESTFLIGHT_BASE_BRANCH='main'
# Only change this for an approved GitHub Enterprise host.
export TESTFLIGHT_GITHUB_HOST='github.com'
```

| Variable | Where to obtain or choose it |
| --- | --- |
| `TESTFLIGHT_APP_ID` | The numeric App Store Connect app ID; see [app setup](docs/app-setup.md#4-apple-setup) and the [configuration contract](.codex/skills/testflight-feedback/references/configuration.md#settingsjson). |
| `TESTFLIGHT_READ_PROFILE` | A validated read-only `asc` profile; see [TestFlight auth profiles](docs/testflight-feedback.md#auth-profiles). |
| `TESTFLIGHT_DELETE_PROFILE` | A separately named write-capable profile, only if explicit archive/delete is approved; see [TestFlight auth profiles](docs/testflight-feedback.md#auth-profiles). |
| `TESTFLIGHT_GITHUB_REPOSITORY` and `TESTFLIGHT_BASE_BRANCH` | The app repository and its protected default branch; see [app setup](docs/app-setup.md#5-github-setup). |
| `TESTFLIGHT_GITHUB_HOST` | Keep the default `github.com` unless the app uses an approved GitHub Enterprise host; see the [configuration contract](.codex/skills/testflight-feedback/references/configuration.md#settingsjson). |

### GitHub Actions variables

These are repository or environment variables—not shell exports. Set them in GitHub after copying and adapting the workflow templates; keep release enablement behind the protected environment described in [app setup](docs/app-setup.md#5-github-setup).

| GitHub variable | Value/source |
| --- | --- |
| `MOBILE_APP_DIR` | App path from the [app contract](docs/app-setup.md#1-establish-the-app-contract). |
| `MOBILE_NODE_VERSION` | The app's supported Node version from the [app contract](docs/app-setup.md#1-establish-the-app-contract). |
| `MOBILE_SANDBOX_ENABLED` | Set to `true` only after [Sand validation](docs/sand-runner.md#read-only-first) and runner testing. |
| `TESTFLIGHT_RELEASE_ENABLED` | Set to `true` only after the release lane, signing, and protected TestFlight environment are reviewed; see [Apple setup](docs/app-setup.md#4-apple-setup). |

`SAND_RUNNER_GROUP` is a local setup variable, not a GitHub Actions variable. The copied workflow templates use the `mobile-sandbox` runner label in `runs-on`; if you choose a different label, update the templates and `SAND_RUNNER_LABEL` together. The group name and label are related but configured separately in the [Sand runner setup](docs/sand-runner.md#configure-the-operator-environment).

### Optional non-VM fallback variables

The fallback runner is intentionally separate from Sand. The token is short-lived and process-only; the version and archive digest must be independently pinned before applying the [fallback setup](docs/sand-runner.md#non-vm-fallback).

| Variable | Where to obtain or choose it |
| --- | --- |
| `RUNNER_REGISTRATION_TOKEN` | Short-lived token from the repository or organization Actions runner settings; see [authentication and secrets](docs/auth-and-secrets.md#where-values-come-from). |
| `RUNNER_VERSION` | An approved ARM64 GitHub Actions runner release version; see [fallback setup](docs/sand-runner.md#non-vm-fallback). |
| `RUNNER_ARCHIVE_SHA256` | The independently verified SHA-256 for that exact runner archive; see [authentication and secrets](docs/auth-and-secrets.md#where-values-come-from). |
| `RUNNER_NAME` | A unique fallback-host name; see [fallback setup](docs/sand-runner.md#non-vm-fallback) and do not reuse the Sand `mobile-sandbox` label. |

## Repository map

| Path | Purpose |
| --- | --- |
| `.codex/skills/testflight-feedback/` | Agent skill, deterministic helper, and local-only configuration examples |
| `scripts/update_sand.sh` | Fetch and build the pinned public Sand fork revision, with an override for another fork |
| `scripts/setup_sand_github_runner.sh` | Plan, validate, and explicitly apply the Sand/VM runner configuration |
| `scripts/setup_macos_actions_runner.sh` | Optional non-VM Apple Silicon runner bootstrap |
| `scripts/init_testflight_feedback.sh` | Create ignored local TestFlight configuration placeholders |
| `docs/` | Human setup and maintenance documentation |
| `templates/github/workflows/*.yml.example` | App-repository workflow templates; not active in this repository |

## Scope boundary

The setup scripts can configure local files, GitHub runner groups, and launch agents when an operator explicitly passes `--apply`. They do not create cloud resources, change production releases, or mint credentials. Review generated configuration before applying it, and keep all actual secrets in the operating system keychain, a dedicated secret manager, or GitHub's protected secret store.
