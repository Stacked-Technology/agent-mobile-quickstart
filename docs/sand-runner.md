# Sand/VM GitHub runner

The Sand setup creates ephemeral macOS VMs for GitHub Actions on an Apple Silicon host. It is intended for mobile builds that need Xcode while limiting host access. The repository only supplies a generic adapter around the Sand CLI; verify the Sand version and configuration schema against the version your team has approved.

## Security model

The default template is designed to:

- run without graphics or clipboard sharing;
- block host-network access while allowing the guest's required external network path;
- avoid host mounts and shared caches;
- use ephemeral GitHub runners;
- restrict a runner group to selected repositories and workflow paths; and
- require explicit `--apply` before GitHub or launch-agent mutations.

It is not a complete security boundary by itself. Review the VM image, Sand release, host OS, GitHub App installation, and workflow contents together.

## Prerequisites

- Apple Silicon macOS 15 or newer, running as a non-root user;
- Swift 6.2 or newer and Git installed locally so the pinned Sand source can be built;
- a pinned macOS VM image compatible with the Xcode version required by the app;
- `gh`, `jq`, `tart` 2.34.0 or newer, `softnet` 0.21.0 or newer, `ssh`, `sshpass`, `plutil`, and the host's normal networking tools;
- a VM image with the Tart Guest Agent;
- a GitHub App installed on the organization; and
- an empty or dedicated runner group for the mobile workflows.

The GitHub App should have only the permissions needed for the selected organization and repository. The setup script checks for Actions read access, organization self-hosted runner write access, and selected-repository installation scope; an organization owner must approve the installation permission changes.

The validation script checks Tart's minimum version directly. It reads Homebrew's installed Softnet version metadata when available, then tries Softnet's version commands for non-Homebrew installations; it fails closed if the installed release cannot be verified as Softnet 0.21.0 or newer.

## Sand source

The quickstart defaults to the maintained public Sand fork at [`Stacked-Technology/sand`](https://github.com/Stacked-Technology/sand), pinned to commit [`7e952d1`](https://github.com/Stacked-Technology/sand/commit/7e952d121a706626e8927d0ba05195a3802961f2). The update script fetches and builds that exact commit, then records the installed binary digest. Override `SAND_SOURCE_REPOSITORY` and `SAND_REVISION` together when using another public fork; never build from an unpinned working tree.

## Configure the operator environment

Set placeholders in the shell session, or use a private shell profile that is not checked in:

```bash
export SAND_GITHUB_ORGANIZATION='<ORG>'
export SAND_GITHUB_REPOSITORY='<ORG>/<REPOSITORY>'
export SAND_GITHUB_APP_ID='<APP_ID>'
export SAND_GITHUB_APP_KEY_PATH="$HOME/.config/sand/github-app.pem"
export SAND_VM_IMAGE='ghcr.io/<OWNER>/<IMAGE>@sha256:<DIGEST>'
export SAND_SOURCE_REPOSITORY='https://github.com/Stacked-Technology/sand.git'
export SAND_REVISION='7e952d121a706626e8927d0ba05195a3802961f2'
export SAND_SOURCE_DIR="$HOME/Github/sand"
export SAND_INSTALL_PATH="$HOME/.local/bin/sand"
export SAND_RUNNER_GROUP='mobile-sandbox'
export SAND_RUNNER_GROUP_CONFIRM='mobile-sandbox'
export SAND_RUNNER_LABEL='mobile-sandbox'
export SAND_RUNNER_NAME='mobile-sandbox-host-01'
export SAND_BASE_BRANCH='main'
```

The runner setup script treats `SAND_INSTALL_PATH` as the default for `SAND_BIN`. If both are set, they must refer to the same path. The updater builds the pinned source with SwiftPM's default sandbox enabled and refuses to continue if the committed `Package.resolved` changes during the build.

The private key file is created through the GitHub App administration process, not by this repository. Verify it is a regular file with mode `600` or `400`. `SAND_RUNNER_GROUP_CONFIRM` must exactly match the group name before `configure-github --apply` will make changes; the script also refuses groups with unrelated repositories or existing runners. `SAND_BASE_BRANCH` must be the protected default branch; the script verifies both before changing GitHub runner-group workflow restrictions.

## Read-only first

Run the commands from this quickstart checkout. If the scripts should live in the app repository, copy them with explicit source and destination paths:

```bash
QUICKSTART_DIR='/path/to/agent-mobile-quickstart'
APP_REPO_DIR='/path/to/app-repository'
```

If copying the scripts into the app repository, run:

```bash
mkdir -p "$APP_REPO_DIR/scripts"
cp "$QUICKSTART_DIR/scripts/update_sand.sh" "$APP_REPO_DIR/scripts/"
cp "$QUICKSTART_DIR/scripts/setup_sand_github_runner.sh" "$APP_REPO_DIR/scripts/"
cd "$APP_REPO_DIR"
```

Then, from the repository that now contains the scripts:

```bash
scripts/update_sand.sh plan
scripts/setup_sand_github_runner.sh plan
```

Both `plan` commands are read-only. After installing the pinned Sand build with `scripts/update_sand.sh install --apply`, run `scripts/setup_sand_github_runner.sh validate`; it checks the rendered Sand config, the local provenance metadata, the required host tools, and the launch-agent plist. The provenance is an audit record, not a cryptographic signature, so only use an approved fork and review the pinned source. These commands do not register a runner, alter GitHub, or start a service.

Copy the workflow templates into the app repository before configuring the runner group. From the quickstart checkout, use explicit destinations:

```bash
mkdir -p "$APP_REPO_DIR/.github/workflows"
cp "$QUICKSTART_DIR/templates/github/workflows/mobile-ci.yml.example" "$APP_REPO_DIR/.github/workflows/mobile-ci.yml"
cp "$QUICKSTART_DIR/templates/github/workflows/mobile-testflight.yml.example" "$APP_REPO_DIR/.github/workflows/mobile-testflight.yml"
```

Review the copied files and replace the app-specific command placeholders before setting `SAND_ALLOWED_WORKFLOWS` or applying the GitHub runner-group restriction.

## Apply in stages

Apply one stage at a time and inspect the output:

```bash
scripts/update_sand.sh install --apply
scripts/setup_sand_github_runner.sh configure-github --apply
scripts/setup_sand_github_runner.sh install --apply
scripts/setup_sand_github_runner.sh status
```

The first command builds and installs the pinned Sand source. The second mutates the GitHub runner group. The third installs a per-user launch agent and starts Sand. Wait for the runner to appear online before enabling workflows. If the host or image is not ready, stop at `plan`/`validate` and fix the prerequisite rather than bypassing the checks.

## Workflow labels

Use a narrow label set in app workflows:

```yaml
runs-on: [self-hosted, macOS, ARM64, mobile-sandbox]
```

Do not use a broad `self-hosted` label alone; it can schedule sensitive mobile jobs onto an unintended machine. Keep release workflows behind a repository/environment variable such as `MOBILE_SANDBOX_ENABLED == 'true'` until the runner has been tested.

## Troubleshooting

- `GitHub App installation not found`: verify the app is installed in the organization and that the authenticated `gh` user can inspect organization installations.
- `runner group not found`: create the group in GitHub first, then rerun the read-only plan.
- `Sand binary provenance is missing`: run `scripts/update_sand.sh install --apply` for the configured exact source commit; do not accept an unpinned download.
- `pool-check` fails: inspect the VM image digest, network service name, guest DNS, and App Store Connect/GitHub reachability from inside the guest.
- Runner is offline: check `launchctl print`, the Sand log path printed by the script, and the GitHub runner group restriction.

Never solve a runner failure by making the group public, enabling host mounts, or copying a private key into the repository.

## Non-VM fallback

If the app temporarily cannot use Sand, the optional plain macOS runner script can install a one-job repository runner after the host has passed the same Xcode checks. Its `mobile-host-fallback` label is intentionally disjoint from the `mobile-sandbox` release workflows:

```bash
export RUNNER_REGISTRATION_TOKEN='<SHORT_LIVED_TOKEN>'
export RUNNER_VERSION='<PINNED_ACTIONS_RUNNER_VERSION>'
export RUNNER_ARCHIVE_SHA256='<64_HEX_ARCHIVE_SHA256>'
export RUNNER_NAME='mobile-host-fallback-01'
bash scripts/setup_macos_actions_runner.sh '<ORG>/<REPOSITORY>' --apply
```

The token is read from the process environment only. The fallback script also requires an explicit runner version and independently verified archive digest; it does not resolve the mutable latest-release endpoint. Prefer the isolated runner for release jobs, and remove the fallback runner when the VM path is healthy.
