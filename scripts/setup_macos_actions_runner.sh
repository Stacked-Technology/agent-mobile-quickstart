#!/usr/bin/env bash
set -euo pipefail

REPOSITORY="${1:-${GITHUB_REPOSITORY:-}}"
RUNNER_HOME="${RUNNER_HOME:-$HOME/actions-runner-mobile}"
RUNNER_NAME="${RUNNER_NAME:-}"
RUNNER_LABELS="${RUNNER_LABELS:-mobile-host-fallback,ios,android}"
RUNNER_REGISTRATION_TOKEN="${RUNNER_REGISTRATION_TOKEN:-}"
RUNNER_VERSION="${RUNNER_VERSION:-}"
RUNNER_ARCHIVE_SHA256="${RUNNER_ARCHIVE_SHA256:-}"
APPLY="${2:-}"

fail() {
  echo "error: $*" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]; then
  cat <<'EOF'
Usage:
  scripts/setup_macos_actions_runner.sh OWNER/REPOSITORY --apply

The registration token is read from RUNNER_REGISTRATION_TOKEN for this
invocation only. This script mutates the host runner installation and requires
the explicit --apply confirmation. Set RUNNER_VERSION and the independently
verified RUNNER_ARCHIVE_SHA256 before applying; the download is never resolved
through a mutable latest-release URL.
EOF
  exit 0
fi

[[ "$APPLY" == "--apply" ]] ||
  fail "runner installation is mutating; rerun with --apply"

[[ "$REPOSITORY" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
  fail "pass the repository as OWNER/REPOSITORY or set GITHUB_REPOSITORY"
[[ "$RUNNER_NAME" =~ ^[A-Za-z0-9._-]+$ ]] ||
  fail "set RUNNER_NAME to an explicit opaque runner name"
[[ "$RUNNER_VERSION" =~ ^[0-9]+(\.[0-9]+){2}$ ]] ||
  fail "set RUNNER_VERSION to a pinned Actions runner version"
[[ "$RUNNER_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
  fail "set RUNNER_ARCHIVE_SHA256 to the pinned ARM64 archive SHA-256"
[[ "$RUNNER_LABELS" != *[$'\n\r']* ]] ||
  fail "RUNNER_LABELS must not contain newlines"
IFS=',' read -r -a label_list <<< "$RUNNER_LABELS"
for label in "${label_list[@]}"; do
  [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || fail "runner label is invalid: $label"
  [[ "$label" != "mobile-sandbox" ]] || fail "fallback runner must not use the Sand label mobile-sandbox"
done
[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] ||
  fail "this runner requires an Apple Silicon macOS host"
[[ "$(id -u)" != "0" ]] || fail "run this as the user that owns the signing keychain, not root"

for command_name in curl tar shasum xcodebuild xcrun; do
  command -v "$command_name" >/dev/null || fail "missing required command: $command_name"
done

xcodebuild -version
xcrun simctl list devices >/dev/null ||
  fail "Xcode simulator services are not ready; run the approved Xcode first-launch setup"

mkdir -p "$RUNNER_HOME"
cd "$RUNNER_HOME"

if [[ ! -f .runner ]]; then
  [[ -n "$RUNNER_REGISTRATION_TOKEN" ]] ||
    fail "set RUNNER_REGISTRATION_TOKEN to a short-lived registration token; it is not stored by this script"
  [[ -z "$(find . -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
    fail "$RUNNER_HOME is not empty and is not a configured runner"

  asset_url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"

  archive="$(mktemp -t actions-runner.XXXXXX.tar.gz)"
  trap 'rm -f "${archive:-}"' EXIT
  curl --fail --location --proto '=https' --tlsv1.2 "$asset_url" --output "$archive"
  actual_digest="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [[ "$actual_digest" == "$RUNNER_ARCHIVE_SHA256" ]] || fail "runner archive checksum mismatch"
  tar xzf "$archive"

  ./config.sh \
    --url "https://github.com/$REPOSITORY" \
    --token "$RUNNER_REGISTRATION_TOKEN" \
    --name "$RUNNER_NAME" \
    --ephemeral \
    --labels "$(IFS=','; printf '%s' "${label_list[*]}")" \
    --work _work \
    --unattended \
    --replace
  printf '%s\n' "$REPOSITORY" > .runner-repository
  chmod 600 .runner-repository
elif [[ ! -f .runner-repository || "$(<.runner-repository)" != "$REPOSITORY" ]]; then
  fail "$RUNNER_HOME contains a runner configured for a different repository"
fi

./svc.sh install >/dev/null 2>&1 || true
./svc.sh start
./svc.sh status

cat <<EOF

Runner configured at $RUNNER_HOME.
Keep this Mac on AC power and logged into the runner user.
The registration token was read from the process environment only.
For release jobs, prefer the isolated Sand runner and protect the workflow with an environment approval.
EOF
