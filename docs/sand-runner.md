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

- Apple Silicon macOS host, running as a non-root user;
- an approved, digest-pinned Sand binary already installed locally;
- a pinned macOS VM image compatible with the Xcode version required by the app;
- `gh`, `tart`, `softnet`, `plutil`, and the host's normal networking tools;
- a GitHub App installed on the organization; and
- an empty or dedicated runner group for the mobile workflows.

The GitHub App should have only the permissions needed for the selected organization and repository. The setup script checks for Actions read access, organization self-hosted runner write access, and selected-repository installation scope; an organization owner must approve the installation permission changes.

## Configure the operator environment

Set placeholders in the shell session, or use a private shell profile that is not checked in:

```bash
export SAND_GITHUB_ORGANIZATION='<ORG>'
export SAND_GITHUB_REPOSITORY='<ORG>/<REPOSITORY>'
export SAND_GITHUB_APP_ID='<APP_ID>'
export SAND_GITHUB_APP_KEY_PATH="$HOME/.config/sand/github-app.pem"
export SAND_VM_IMAGE='ghcr.io/<OWNER>/<IMAGE>@sha256:<DIGEST>'
export SAND_REVISION='<40_CHARACTER_SAND_COMMIT_SHA>'
export SAND_RUNNER_GROUP='mobile-sandbox'
export SAND_RUNNER_LABEL='mobile-sandbox'
export SAND_RUNNER_NAME='mobile-sandbox-host-01'
```

The private key file is created through the GitHub App administration process, not by this repository. Verify it is a regular file with mode `600` or `400`.

## Read-only first

From the app repository after copying the script:

```bash
scripts/setup_sand_github_runner.sh plan
scripts/setup_sand_github_runner.sh validate
```

`validate` checks the rendered Sand config, the pinned binary provenance, and the launch-agent plist. It does not register a runner, alter GitHub, or start a service.

Copy the workflow templates into the app repository before configuring the runner group. The default allowlist expects these exact active paths:

```bash
mkdir -p .github/workflows
cp templates/github/workflows/mobile-ci.yml.example .github/workflows/mobile-ci.yml
cp templates/github/workflows/mobile-testflight.yml.example .github/workflows/mobile-testflight.yml
```

Review the copied files and replace the app-specific command placeholders before setting `SAND_ALLOWED_WORKFLOWS` or applying the GitHub runner-group restriction.

## Apply in stages

Apply one stage at a time and inspect the output:

```bash
scripts/setup_sand_github_runner.sh configure-github --apply
scripts/setup_sand_github_runner.sh install --apply
scripts/setup_sand_github_runner.sh status
```

The first command mutates the GitHub runner group. The second installs a per-user launch agent and starts Sand. Wait for the runner to appear online before enabling workflows. If the host or image is not ready, stop at `plan`/`validate` and fix the prerequisite rather than bypassing the checks.

## Workflow labels

Use a narrow label set in app workflows:

```yaml
runs-on: [self-hosted, macOS, ARM64, mobile-sandbox]
```

Do not use a broad `self-hosted` label alone; it can schedule sensitive mobile jobs onto an unintended machine. Keep release workflows behind a repository/environment variable such as `MOBILE_SANDBOX_ENABLED == 'true'` until the runner has been tested.

## Troubleshooting

- `GitHub App installation not found`: verify the app is installed in the organization and that the authenticated `gh` user can inspect organization installations.
- `runner group not found`: create the group in GitHub first, then rerun the read-only plan.
- `Sand binary provenance is missing`: install the approved pinned binary and its one-line provenance file; do not accept an unpinned download.
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
