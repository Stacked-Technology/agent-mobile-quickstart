#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_RUNNER_GROUP="mobile-sandbox"
readonly DEFAULT_RUNNER_LABEL="mobile-sandbox"
readonly DEFAULT_REPOSITORY_SCOPE="organization"
readonly DEFAULT_SAND_SOURCE_REPOSITORY="https://github.com/Stacked-Technology/sand.git"
readonly DEFAULT_SAND_REVISION="74e03ba4c76fc2b741b89fcfccf4f1f6cbcd1b9f"
readonly DEFAULT_CONFIG_PATH="$HOME/.config/sand/mobile-runner.yml"
readonly DEFAULT_LAUNCH_AGENT_PATH="$HOME/Library/LaunchAgents/com.local.sand.mobile-runner.plist"
readonly DEFAULT_LAUNCH_AGENT_LABEL="com.local.sand.mobile-runner"
readonly DEFAULT_LOG_PATH="$HOME/Library/Logs/sand-mobile-runner.log"
readonly DEFAULT_STDOUT_PATH="$HOME/Library/Logs/sand-mobile-runner.out.log"
readonly DEFAULT_STDERR_PATH="$HOME/Library/Logs/sand-mobile-runner.err.log"
readonly DEFAULT_WORKFLOWS="mobile-ci.yml,mobile-testflight.yml"

MODE="${1:-plan}"
APPLY="${2:-}"
ORGANIZATION="${SAND_GITHUB_ORGANIZATION:-}"
REPOSITORY="${SAND_GITHUB_REPOSITORY:-}"
REPOSITORY_SCOPE="${SAND_REPOSITORY_SCOPE:-$DEFAULT_REPOSITORY_SCOPE}"
EXCLUDE_REPOSITORIES="${SAND_EXCLUDE_REPOSITORIES:-}"
APP_ID="${SAND_GITHUB_APP_ID:-}"
KEY_PATH="${SAND_GITHUB_APP_KEY_PATH:-$HOME/.config/sand/github-app.pem}"
VM_IMAGE="${SAND_VM_IMAGE:-}"
SAND_SOURCE_REPOSITORY_WAS_SET="${SAND_SOURCE_REPOSITORY+x}"
SAND_REVISION_WAS_SET="${SAND_REVISION+x}"
SAND_REVISION="${SAND_REVISION:-$DEFAULT_SAND_REVISION}"
SAND_SOURCE_REPOSITORY="${SAND_SOURCE_REPOSITORY:-$DEFAULT_SAND_SOURCE_REPOSITORY}"
RUNNER_GROUP="${SAND_RUNNER_GROUP:-$DEFAULT_RUNNER_GROUP}"
RUNNER_GROUP_CONFIRM="${SAND_RUNNER_GROUP_CONFIRM:-}"
RUNNER_LABEL="${SAND_RUNNER_LABEL:-$DEFAULT_RUNNER_LABEL}"
RUNNER_NAME="${SAND_RUNNER_NAME:-}"
BASE_BRANCH="${SAND_BASE_BRANCH:-main}"
WORKFLOWS="${SAND_ALLOWED_WORKFLOWS:-$DEFAULT_WORKFLOWS}"
VM_RAM_GB="${SAND_VM_RAM_GB:-8}"
VM_CPU_CORES="${SAND_VM_CPU_CORES:-6}"
POOL_MIN="${SAND_POOL_MIN:-1}"
POOL_MAX="${SAND_POOL_MAX:-2}"
POOL_POLL_INTERVAL="${SAND_POOL_POLL_INTERVAL:-30}"
CONFIG_PATH="${SAND_CONFIG_PATH:-$DEFAULT_CONFIG_PATH}"
LAUNCH_AGENT_PATH="${SAND_LAUNCH_AGENT_PATH:-$DEFAULT_LAUNCH_AGENT_PATH}"
SAND_INSTALL_PATH="${SAND_INSTALL_PATH:-}"
SAND_BIN="${SAND_BIN:-${SAND_INSTALL_PATH:-$HOME/.local/bin/sand}}"
MANAGED_LOGS_RECREATED=false
GITHUB_SNAPSHOT_DIRECTORY=""
GITHUB_MUTATION_ACTIVE=false
GITHUB_MUTATION_GROUP_ID=""
GITHUB_GROUP_ETAG=""
GITHUB_REPOSITORIES_ETAG=""

usage() {
  cat <<'EOF'
Usage:
  scripts/setup_sand_github_runner.sh plan
  scripts/setup_sand_github_runner.sh render
  scripts/setup_sand_github_runner.sh configure-github --apply
  scripts/setup_sand_github_runner.sh validate
  scripts/setup_sand_github_runner.sh install --apply
  scripts/setup_sand_github_runner.sh status

Read-only commands are the default. GitHub and launch-agent mutations require
the literal second argument --apply.

Required environment for validate/configure/install:
  SAND_GITHUB_ORGANIZATION  SAND_GITHUB_APP_ID  SAND_VM_IMAGE
  SAND_GITHUB_REPOSITORY is additionally required for selected scope.

Useful overrides:
  SAND_REPOSITORY_SCOPE     SAND_EXCLUDE_REPOSITORIES
  SAND_GITHUB_REPOSITORY    SAND_GITHUB_APP_KEY_PATH SAND_REVISION
  SAND_RUNNER_GROUP         SAND_SOURCE_REPOSITORY   SAND_INSTALL_PATH
  SAND_RUNNER_LABEL
  SAND_RUNNER_GROUP_CONFIRM
  SAND_RUNNER_NAME          SAND_BASE_BRANCH        SAND_ALLOWED_WORKFLOWS
  SAND_VM_RAM_GB            SAND_VM_CPU_CORES       SAND_POOL_MIN
  SAND_POOL_MAX             SAND_POOL_POLL_INTERVAL SAND_CONFIG_PATH
  SAND_LAUNCH_AGENT_PATH    SAND_BIN
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

require_macos_host() {
  [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] ||
    fail "Sand requires an Apple Silicon macOS host."
  [[ "$(id -u)" != "0" ]] || fail "Run Sand as the normal runner user, not root."
  local macos_version macos_major
  macos_version="$(sw_vers -productVersion 2>/dev/null || true)"
  macos_major="${macos_version%%.*}"
  [[ "$macos_major" =~ ^[0-9]+$ ]] && (( macos_major >= 15 )) ||
    fail "the pinned Sand fork requires macOS 15 or newer; detected: ${macos_version:-unknown}."
}

positive_integer() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || fail "$1 must be a positive integer."
}

non_negative_integer() {
  [[ "$2" =~ ^[0-9]+$ ]] || fail "$1 must be a non-negative integer."
}

validate_source_overrides() {
  [[ "$SAND_SOURCE_REPOSITORY_WAS_SET" == "$SAND_REVISION_WAS_SET" ]] ||
    fail "set SAND_SOURCE_REPOSITORY and SAND_REVISION together; both are pinned as one source selection."
}

validate_plan_inputs() {
  local repository_owner excluded_repository
  validate_source_overrides
  [[ "$SAND_SOURCE_REPOSITORY" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(\.git)?$ ]] ||
    fail "SAND_SOURCE_REPOSITORY must be an HTTPS GitHub repository URL."
  [[ "$SAND_REVISION" =~ ^[0-9a-f]{40}$ ]] ||
    fail "SAND_REVISION must be a full lowercase commit SHA."
  [[ -z "$SAND_INSTALL_PATH" || "$SAND_INSTALL_PATH" == "$SAND_BIN" ]] ||
    fail "SAND_INSTALL_PATH and SAND_BIN must refer to the same path."
  [[ "$REPOSITORY_SCOPE" == "organization" || "$REPOSITORY_SCOPE" == "selected" ]] ||
    fail "SAND_REPOSITORY_SCOPE must be organization or selected."
  if [[ "$REPOSITORY_SCOPE" == "organization" && -n "$REPOSITORY" ]]; then
    fail "SAND_GITHUB_REPOSITORY requires SAND_REPOSITORY_SCOPE=selected."
  fi
  if [[ -n "$ORGANIZATION" || -n "$REPOSITORY" ]]; then
    [[ "$ORGANIZATION" =~ ^[A-Za-z0-9._-]+$ ]] || fail "SAND_GITHUB_ORGANIZATION is invalid."
    if [[ -n "$REPOSITORY" ]]; then
      [[ "$REPOSITORY" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail "SAND_GITHUB_REPOSITORY must have the form OWNER/REPOSITORY."
      repository_owner="$(printf '%s\n' "$REPOSITORY" | cut -d/ -f1)"
      [[ "$repository_owner" == "$ORGANIZATION" ]] || fail "repository owner must match SAND_GITHUB_ORGANIZATION."
    fi
  fi
  if [[ -n "$EXCLUDE_REPOSITORIES" ]]; then
    [[ "$REPOSITORY_SCOPE" == "organization" ]] ||
      fail "SAND_EXCLUDE_REPOSITORIES requires SAND_REPOSITORY_SCOPE=organization."
    IFS=',' read -r -a excluded_repository_list <<< "$EXCLUDE_REPOSITORIES"
    for excluded_repository in "${excluded_repository_list[@]}"; do
      [[ "$excluded_repository" =~ ^[A-Za-z0-9._-]+$ ]] ||
        fail "SAND_EXCLUDE_REPOSITORIES must be a comma-separated list of repository names."
    done
  fi
  if [[ -n "$APP_ID" ]]; then
    positive_integer SAND_GITHUB_APP_ID "$APP_ID"
  fi
  if [[ -n "$VM_IMAGE" ]]; then
    [[ "$VM_IMAGE" =~ ^[A-Za-z0-9._/@:-]+@sha256:[0-9a-f]{64}$ ]] || fail "SAND_VM_IMAGE must end with an exact sha256 digest."
  fi
  if [[ -n "$RUNNER_NAME" ]]; then
    [[ "$RUNNER_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || fail "SAND_RUNNER_NAME is invalid."
  fi
}

validate_inputs() {
  local path_value workflow
  validate_plan_inputs
  [[ "$ORGANIZATION" =~ ^[A-Za-z0-9._-]+$ ]] || fail "SAND_GITHUB_ORGANIZATION is missing or invalid."
  if [[ "$REPOSITORY_SCOPE" == "selected" ]]; then
    [[ "$REPOSITORY" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail "SAND_GITHUB_REPOSITORY must have the form OWNER/REPOSITORY for selected scope."
    [[ "${REPOSITORY%%/*}" == "$ORGANIZATION" ]] || fail "repository owner must match SAND_GITHUB_ORGANIZATION."
  fi
  positive_integer SAND_GITHUB_APP_ID "$APP_ID"
  positive_integer SAND_VM_RAM_GB "$VM_RAM_GB"
  positive_integer SAND_VM_CPU_CORES "$VM_CPU_CORES"
  non_negative_integer SAND_POOL_MIN "$POOL_MIN"
  positive_integer SAND_POOL_MAX "$POOL_MAX"
  positive_integer SAND_POOL_POLL_INTERVAL "$POOL_POLL_INTERVAL"
  (( POOL_MIN <= POOL_MAX )) || fail "SAND_POOL_MIN cannot exceed SAND_POOL_MAX."
  (( POOL_MAX <= 16 )) || fail "SAND_POOL_MAX cannot exceed 16."
  (( POOL_POLL_INTERVAL >= 15 )) || fail "SAND_POOL_POLL_INTERVAL must be at least 15 seconds."
  [[ "$BASE_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "SAND_BASE_BRANCH is invalid."
  [[ "$RUNNER_GROUP" =~ ^[A-Za-z0-9._\ -]+$ ]] || fail "SAND_RUNNER_GROUP is invalid."
  [[ "$RUNNER_LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || fail "SAND_RUNNER_LABEL is invalid."
  [[ "$RUNNER_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || fail "set SAND_RUNNER_NAME to an explicit opaque runner name."
  [[ "$VM_IMAGE" =~ ^[A-Za-z0-9._/@:-]+@sha256:[0-9a-f]{64}$ ]] || fail "SAND_VM_IMAGE must end with an exact sha256 digest."
  [[ "$SAND_REVISION" =~ ^[0-9a-f]{40}$ ]] || fail "SAND_REVISION must be a full lowercase commit SHA."
  for path_value in "$KEY_PATH" "$CONFIG_PATH" "$LAUNCH_AGENT_PATH" "$SAND_BIN" "$DEFAULT_LOG_PATH" "$DEFAULT_STDOUT_PATH" "$DEFAULT_STDERR_PATH"; do
    [[ "$path_value" == /* && "$path_value" =~ ^[A-Za-z0-9_./\ -]+$ ]] || fail "path must be absolute and contain only supported characters: $path_value"
    reject_symlinked_ancestors "$path_value"
  done
  [[ "$WORKFLOWS" != *[$'\n\r']* ]] || fail "SAND_ALLOWED_WORKFLOWS contains a newline."
  IFS=',' read -r -a workflow_list <<< "$WORKFLOWS"
  ((${#workflow_list[@]} > 0)) || fail "SAND_ALLOWED_WORKFLOWS must not be empty."
  for workflow in "${workflow_list[@]}"; do
    [[ "$workflow" =~ ^[A-Za-z0-9._/-]+\.yml$ ]] || fail "workflow name is invalid: $workflow"
  done
}

require_commands() {
  local command_name
  for command_name in gh jq plutil launchctl shasum install tart softnet sshpass ssh; do
    command -v "$command_name" >/dev/null || fail "missing required command: $command_name"
  done
}

version_at_least() {
  local actual="$1" required="$2"
  local actual_major actual_minor actual_patch required_major required_minor required_patch version_part
  IFS='.' read -r actual_major actual_minor actual_patch _ <<< "$actual"
  IFS='.' read -r required_major required_minor required_patch _ <<< "$required"
  for version_part in "$actual_major" "$actual_minor" "$actual_patch" "$required_major" "$required_minor" "$required_patch"; do
    [[ "$version_part" =~ ^[0-9]+$ ]] || return 1
  done
  (( actual_major > required_major ||
    (actual_major == required_major && actual_minor > required_minor) ||
    (actual_major == required_major && actual_minor == required_minor && actual_patch >= required_patch) ))
}

require_tart_version() {
  local tart_version
  tart_version="$(tart --version 2>/dev/null | sed -nE 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1)"
  [[ -n "$tart_version" ]] && version_at_least "$tart_version" "2.34.0" ||
    fail "Tart 2.34.0 or newer is required; detected: ${tart_version:-unknown}."
}

require_softnet_version() {
  local detected_version=""
  if command -v brew >/dev/null 2>&1; then
    detected_version="$(HOMEBREW_NO_AUTO_UPDATE=1 brew list --versions softnet 2>/dev/null | awk '{print $2}')"
  fi
  if [[ -z "$detected_version" ]]; then
    detected_version="$(softnet --version 2>/dev/null | sed -nE 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1 || true)"
  fi
  if [[ -z "$detected_version" ]]; then
    detected_version="$(softnet version 2>/dev/null | sed -nE 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1 || true)"
  fi
  [[ -n "$detected_version" ]] && version_at_least "$detected_version" "0.21.0" ||
    fail "Softnet 0.21.0 or newer is required; install a release that exposes its version or use the Homebrew package metadata check."
}

file_owner() {
  stat -f '%u' "$1"
}

file_mode() {
  stat -f '%Lp' "$1"
}

reject_symlinked_ancestors() {
  local path_value="$1" parent
  parent="$(dirname "$path_value")"
  while [[ "$parent" != "/" ]]; do
    [[ ! -L "$parent" || "$parent" == "/var" || "$parent" == "/tmp" ]] ||
      fail "path has a symlinked parent: $parent"
    parent="$(dirname "$parent")"
  done
}

require_secure_parent_directory() {
  local target_path="$1" parent
  parent="$(dirname "$target_path")"
  [[ -d "$parent" && ! -L "$parent" ]] || fail "managed path parent is missing or symlinked: $parent"
  [[ "$(file_owner "$parent")" == "$(id -u)" ]] || fail "managed path parent must be owned by the runner user: $parent"
  [[ "$((8#$(file_mode "$parent") & 8#022))" == 0 ]] || fail "managed path parent must not be group/world writable: $parent"
}

require_key() {
  [[ -f "$KEY_PATH" && ! -L "$KEY_PATH" ]] || fail "GitHub App private key is missing or symlinked: $KEY_PATH"
  [[ "$(file_mode "$KEY_PATH")" == "600" || "$(file_mode "$KEY_PATH")" == "400" ]] || fail "GitHub App private key must have mode 600 or 400."
  [[ "$(file_owner "$KEY_PATH")" == "$(id -u)" ]] || fail "GitHub App private key must be owned by the runner user."
}

require_pinned_sand() {
  local provenance_path="${SAND_BIN}.provenance" recorded_revision recorded_sha recorded_source recorded_resolved recorded_toolchain actual_sha extra
  [[ -f "$SAND_BIN" && ! -L "$SAND_BIN" && -x "$SAND_BIN" ]] || fail "Sand binary is missing or not executable: $SAND_BIN"
  [[ -f "$provenance_path" && ! -L "$provenance_path" ]] || fail "Sand provenance is missing: $provenance_path"
  [[ "$(file_owner "$SAND_BIN")" == "$(id -u)" ]] || fail "Sand binary must be owned by the runner user."
  [[ "$(file_mode "$provenance_path")" =~ ^[0-9]+$ ]] || fail "Sand provenance permissions are invalid."
  (( (8#$(file_mode "$provenance_path") & 8#022) == 0 )) || fail "Sand provenance must not be group/world writable."
  [[ "$(wc -l < "$provenance_path" | tr -d '[:space:]')" == "1" ]] || fail "Sand provenance must contain exactly one record."
  IFS=' ' read -r recorded_revision recorded_sha recorded_source recorded_resolved recorded_toolchain extra < "$provenance_path"
  [[ -z "${extra:-}" && "$recorded_revision" == "$SAND_REVISION" && "$recorded_sha" =~ ^[0-9a-f]{64}$ && "$recorded_source" == "source=$SAND_SOURCE_REPOSITORY" && "$recorded_resolved" =~ ^resolved_sha256=[0-9a-f]{64}$ && "$recorded_toolchain" =~ ^toolchain_sha256=[0-9a-f]{64}$ ]] || fail "Sand provenance does not match the pinned source, revision, or build inputs."
  actual_sha="$(shasum -a 256 "$SAND_BIN")"
  actual_sha="${actual_sha%% *}"
  [[ "$actual_sha" == "$recorded_sha" ]] || fail "Sand binary differs from its pinned provenance."
}

cleanup_github_snapshot() {
  if [[ -n "$GITHUB_SNAPSHOT_DIRECTORY" ]]; then
    rm -rf "$GITHUB_SNAPSHOT_DIRECTORY"
    GITHUB_SNAPSHOT_DIRECTORY=""
  fi
}

snapshot_runner_group() {
  local snapshot_directory="$1" runner_group_id="$2"
  gh api "/orgs/$ORGANIZATION/actions/runner-groups/$runner_group_id" > "$snapshot_directory/group.json" ||
    fail "could not snapshot runner group before mutation"
  gh api --paginate --slurp "/orgs/$ORGANIZATION/actions/runner-groups/$runner_group_id/repositories?per_page=100" > "$snapshot_directory/repositories.json" ||
    fail "could not snapshot runner group repositories before mutation"
}

require_dedicated_runner_group() {
  local visibility allows_public is_default inherited network_configuration_id selected_repositories existing_runners hosted_runners
  [[ "$RUNNER_GROUP_CONFIRM" == "$RUNNER_GROUP" ]] ||
    fail "set SAND_RUNNER_GROUP_CONFIRM to the exact runner group name before mutating GitHub."
  visibility="$(jq -r '.visibility // ""' "$GITHUB_SNAPSHOT_DIRECTORY/group.json")"
  allows_public="$(jq -r '.allows_public_repositories // false' "$GITHUB_SNAPSHOT_DIRECTORY/group.json")"
  is_default="$(jq -r '.default // false' "$GITHUB_SNAPSHOT_DIRECTORY/group.json")"
  inherited="$(jq -r '.inherited // false' "$GITHUB_SNAPSHOT_DIRECTORY/group.json")"
  network_configuration_id="$(jq -r '.network_configuration_id // ""' "$GITHUB_SNAPSHOT_DIRECTORY/group.json")"
  [[ "$visibility" == "selected" && "$allows_public" == "false" && "$is_default" == "false" && "$inherited" == "false" && -z "$network_configuration_id" ]] ||
    fail "runner group must be a non-default, selected-only, non-inherited group without a network configuration."
  selected_repositories="$(jq -r '[.[].repositories[]?.full_name] | sort | join("\n")' "$GITHUB_SNAPSHOT_DIRECTORY/repositories.json")"
  [[ -z "$selected_repositories" || "$selected_repositories" == "$REPOSITORY" ]] ||
    fail "runner group is not dedicated to $REPOSITORY; refusing to change its repository allowlist."
  existing_runners="$(gh api --paginate "/orgs/$ORGANIZATION/actions/runner-groups/$1/runners?per_page=100" --jq '.runners[]?.name')" ||
    fail "could not inspect existing runners in group $RUNNER_GROUP."
  [[ -z "$existing_runners" ]] ||
    fail "runner group $RUNNER_GROUP already has runners; use an empty dedicated group."
  hosted_runners="$(gh api --paginate "/orgs/$ORGANIZATION/actions/runner-groups/$1/hosted-runners?per_page=100" --jq '.hosted_runners[]?.id')" ||
    fail "could not inspect hosted runners in group $RUNNER_GROUP."
  [[ -z "$hosted_runners" ]] ||
    fail "runner group $RUNNER_GROUP already has hosted runners; use an empty dedicated group."
}

read_api_etag() {
  local endpoint="$1" etag
  etag="$(gh api --include "$endpoint" | awk 'tolower($1) == "etag:" {print $2; exit}')" ||
    fail "could not read the GitHub resource version for $endpoint."
  etag="${etag#W/}"
  [[ -n "$etag" ]] || fail "GitHub did not return a resource version for $endpoint."
  printf '%s\n' "$etag"
}

assert_repository_snapshot_unchanged() {
  local current_repositories expected_repositories repositories_endpoint
  repositories_endpoint="/orgs/$ORGANIZATION/actions/runner-groups/$GITHUB_MUTATION_GROUP_ID/repositories?per_page=100"
  current_repositories="$(gh api --paginate --slurp "$repositories_endpoint" | jq -c '[.[].repositories[]?.id] | sort')" ||
    fail "could not revalidate runner group repositories before mutation."
  expected_repositories="$(jq -c '[.[].repositories[]?.id] | sort' "$GITHUB_SNAPSHOT_DIRECTORY/repositories.json")" ||
    fail "could not read the runner group repository snapshot."
  [[ "$current_repositories" == "$expected_repositories" ]] ||
    fail "runner group repository membership changed after review; refusing to overwrite it."
  GITHUB_REPOSITORIES_ETAG="$(read_api_etag "$repositories_endpoint")"
}

assert_runner_group_snapshot_unchanged() {
  local current_group expected_group group_endpoint
  group_endpoint="/orgs/$ORGANIZATION/actions/runner-groups/$GITHUB_MUTATION_GROUP_ID"
  current_group="$(gh api "$group_endpoint" | jq -c '{name, visibility, allows_public_repositories, default, inherited, network_configuration_id, restricted_to_workflows, selected_workflows: ((.selected_workflows // .workflow_restrictions.workflows // []) | sort)}')" ||
    fail "could not revalidate runner group before mutation."
  expected_group="$(jq -c '{name, visibility, allows_public_repositories, default, inherited, network_configuration_id, restricted_to_workflows, selected_workflows: ((.selected_workflows // .workflow_restrictions.workflows // []) | sort)}' "$GITHUB_SNAPSHOT_DIRECTORY/group.json")" ||
    fail "could not read the runner group snapshot."
  [[ "$current_group" == "$expected_group" ]] ||
    fail "runner group settings changed after review; refusing to overwrite them."
  GITHUB_GROUP_ETAG="$(read_api_etag "$group_endpoint")"
  assert_repository_snapshot_unchanged
}

assert_runner_group_configuration() {
  local group_endpoint current_visibility current_public current_restricted current_workflows expected_workflows
  group_endpoint="/orgs/$ORGANIZATION/actions/runner-groups/$GITHUB_MUTATION_GROUP_ID"
  current_visibility="$(gh api "$group_endpoint" --jq '.visibility')" || fail "could not verify runner group visibility after mutation."
  current_public="$(gh api "$group_endpoint" --jq '.allows_public_repositories // false')" || fail "could not verify runner group public-repository access after mutation."
  current_restricted="$(gh api "$group_endpoint" --jq '.restricted_to_workflows // .workflow_restrictions.restricted_to_workflows // false')" || fail "could not verify runner group workflow restrictions after mutation."
  current_workflows="$(gh api "$group_endpoint" --jq '(.selected_workflows // .workflow_restrictions.workflows // []) | sort | join("\n")')" || fail "could not verify runner group workflows after mutation."
  IFS=',' read -r -a workflow_list <<< "$WORKFLOWS"
  expected_workflows="$(printf '%s\n' "${workflow_list[@]}" | awk -v repository="$REPOSITORY" -v branch="$BASE_BRANCH" 'BEGIN { first = 1 } { if (!first) printf "\n"; printf "%s/.github/workflows/%s@refs/heads/%s", repository, $0, branch; first = 0 }' | sort)"
  [[ "$current_visibility" == "selected" && "$current_public" == "false" && "$current_restricted" == "true" && "$current_workflows" == "$expected_workflows" ]] ||
    fail "runner group configuration did not converge to the requested private workflow allowlist."
}

restore_runner_group() {
  local snapshot_directory="$1" runner_group_id="$2" group_payload repository_payload
  group_payload="$(jq -c '{
    name,
    visibility,
    allows_public_repositories,
    default,
    restricted_to_workflows: (.restricted_to_workflows // .workflow_restrictions.restricted_to_workflows // false),
    selected_workflows: (.selected_workflows // .workflow_restrictions.workflows // [])
  } | with_entries(select(.value != null))' "$snapshot_directory/group.json")" || return 1
  repository_payload="$(jq -c '{selected_repository_ids: [.[].repositories[]?.id]}' "$snapshot_directory/repositories.json")" || return 1
  gh api --method PATCH "/orgs/$ORGANIZATION/actions/runner-groups/$runner_group_id" --input - <<< "$group_payload" --silent || return 1
  gh api --method PUT "/orgs/$ORGANIZATION/actions/runner-groups/$runner_group_id/repositories" --input - <<< "$repository_payload" --silent || return 1
}

cleanup_github_configuration() {
  local status="$?"
  trap - EXIT INT TERM HUP
  set +e
  if [[ "$GITHUB_MUTATION_ACTIVE" == true && -n "$GITHUB_SNAPSHOT_DIRECTORY" && -n "$GITHUB_MUTATION_GROUP_ID" ]]; then
    restore_runner_group "$GITHUB_SNAPSHOT_DIRECTORY" "$GITHUB_MUTATION_GROUP_ID" ||
      echo "error: GitHub runner-group rollback failed; inspect the group before enabling workflows." >&2
  fi
  cleanup_github_snapshot
  exit "$status"
}

configure_organization_github() {
  local permissions runner_permission installation_record installation_id installation_selection runner_group_id group_payload
  permissions="$(gh api "/orgs/$ORGANIZATION/installations" --paginate --jq ".installations[] | select(.app_id == $APP_ID) | .permissions.actions // \"none\"")"
  runner_permission="$(gh api "/orgs/$ORGANIZATION/installations" --paginate --jq ".installations[] | select(.app_id == $APP_ID) | .permissions.organization_self_hosted_runners // \"none\"")"
  [[ "$permissions" == "read" ]] || fail "the Sand GitHub App must have Actions: read."
  [[ "$runner_permission" == "write" ]] || fail "the Sand GitHub App must have organization self-hosted runners: write."
  installation_record="$(gh api "/orgs/$ORGANIZATION/installations" --paginate --jq ".installations[] | select(.app_id == $APP_ID) | [.id, .repository_selection] | @tsv")"
  [[ "$(printf '%s\n' "$installation_record" | wc -l | tr -d '[:space:]')" == "1" ]] || fail "the Sand GitHub App installation was not found or was ambiguous."
  IFS=$'\t' read -r installation_id installation_selection <<< "$installation_record"
  [[ "$installation_id" =~ ^[1-9][0-9]*$ && "$installation_selection" == "all" ]] ||
    fail "organization repository scope requires the Sand GitHub App installation to use all-repository scope. Use SAND_REPOSITORY_SCOPE=selected for a selected installation."
  runner_group_id="$(gh api "/orgs/$ORGANIZATION/actions/runner-groups?per_page=100" --paginate --jq ".runner_groups[] | select(.name == \"$RUNNER_GROUP\") | .id")"
  [[ "$runner_group_id" =~ ^[1-9][0-9]*$ ]] || fail "runner group was not found or was ambiguous: $RUNNER_GROUP"
  group_payload="$(gh api "/orgs/$ORGANIZATION/actions/runner-groups/$runner_group_id")"
  [[ "$(jq -r '.visibility // ""' <<< "$group_payload")" == "all" ]] ||
    fail "organization repository scope requires runner group $RUNNER_GROUP to have visibility=all."
  [[ "$(jq -r '.allows_public_repositories // false' <<< "$group_payload")" == "false" ]] ||
    fail "runner group $RUNNER_GROUP must not allow public repositories."
  [[ "$(jq -r '.default // false' <<< "$group_payload")" == "false" ]] ||
    fail "runner group $RUNNER_GROUP must not be the organization default group."
  [[ "$(jq -r '.inherited // false' <<< "$group_payload")" == "false" ]] ||
    fail "runner group $RUNNER_GROUP must not be inherited."
  [[ "$(jq -r '.restricted_to_workflows // .workflow_restrictions.restricted_to_workflows // false' <<< "$group_payload")" == "false" ]] ||
    fail "runner group $RUNNER_GROUP must not be restricted to a workflow allowlist in organization scope."
  echo "Verified organization-wide Sand access through GitHub App $APP_ID and runner group $RUNNER_GROUP."
  echo "The group remains private-only; no GitHub runner-group mutation was needed."
}

configure_github() {
  gh auth status >/dev/null 2>&1 || fail "Authenticate gh with an organization-owner account first."
  if [[ "$REPOSITORY_SCOPE" == "organization" ]]; then
    configure_organization_github
    return
  fi
  local permissions runner_permission installation_record installation_id installation_selection installation_repositories runner_group_id repository_id repository_default_branch required_review_count selected workflow
  permissions="$(gh api "/orgs/$ORGANIZATION/installations" --paginate --jq ".installations[] | select(.app_id == $APP_ID) | .permissions.actions // \"none\"")"
  runner_permission="$(gh api "/orgs/$ORGANIZATION/installations" --paginate --jq ".installations[] | select(.app_id == $APP_ID) | .permissions.organization_self_hosted_runners // \"none\"")"
  [[ "$permissions" == "read" ]] || fail "the Sand GitHub App must have Actions: read."
  [[ "$runner_permission" == "write" ]] || fail "the Sand GitHub App must have organization self-hosted runners: write."
  installation_record="$(gh api "/orgs/$ORGANIZATION/installations" --paginate --jq ".installations[] | select(.app_id == $APP_ID) | [.id, .repository_selection] | @tsv")"
  [[ "$(printf '%s\n' "$installation_record" | wc -l | tr -d '[:space:]')" == "1" ]] || fail "the Sand GitHub App installation was not found or was ambiguous."
  IFS=$'\t' read -r installation_id installation_selection <<< "$installation_record"
  [[ "$installation_id" =~ ^[1-9][0-9]*$ && "$installation_selection" == "selected" ]] || fail "the Sand GitHub App must use selected-repository installation scope."
  installation_repositories="$(gh api "/user/installations/$installation_id/repositories?per_page=100" --paginate --jq '.repositories[].full_name')"
  printf '%s\n' "$installation_repositories" | grep -Fxq "$REPOSITORY" || fail "the Sand GitHub App installation does not include $REPOSITORY."
  runner_group_id="$(gh api "/orgs/$ORGANIZATION/actions/runner-groups?per_page=100" --paginate --jq ".runner_groups[] | select(.name == \"$RUNNER_GROUP\") | .id")"
  [[ "$runner_group_id" =~ ^[1-9][0-9]*$ ]] || fail "runner group was not found or was ambiguous: $RUNNER_GROUP"
  repository_id="$(gh api "/repos/$REPOSITORY" --jq .id)"
  [[ "$repository_id" =~ ^[1-9][0-9]*$ ]] || fail "repository was not found: $REPOSITORY"
  repository_default_branch="$(gh api "/repos/$REPOSITORY" --jq .default_branch)"
  [[ "$BASE_BRANCH" == "$repository_default_branch" ]] ||
    fail "SAND_BASE_BRANCH must match the repository default branch ($repository_default_branch)."
  required_review_count="$(gh api "/repos/$REPOSITORY/branches/$BASE_BRANCH/protection" --jq '.required_pull_request_reviews.required_approving_review_count // 0' 2>/dev/null)" ||
    fail "the repository default branch must have branch protection before configuring a privileged runner."
  [[ "$required_review_count" =~ ^[1-9][0-9]*$ ]] ||
    fail "the repository default branch must require at least one pull-request approval before configuring a privileged runner."
  GITHUB_SNAPSHOT_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/mobile-sand-github.XXXXXX")"
  GITHUB_MUTATION_GROUP_ID="$runner_group_id"
  trap cleanup_github_configuration EXIT INT TERM HUP
  snapshot_runner_group "$GITHUB_SNAPSHOT_DIRECTORY" "$runner_group_id"
  require_dedicated_runner_group "$runner_group_id"
  assert_runner_group_snapshot_unchanged
  local patch_args=(
    --method PATCH "/orgs/$ORGANIZATION/actions/runner-groups/$runner_group_id"
    -H "If-Match: $GITHUB_GROUP_ETAG"
    -f "name=$RUNNER_GROUP" -f visibility=selected -F allows_public_repositories=false
    -F restricted_to_workflows=true
  )
  GITHUB_MUTATION_ACTIVE=true
  IFS=',' read -r -a workflow_list <<< "$WORKFLOWS"
  for workflow in "${workflow_list[@]}"; do
    patch_args+=( -f "selected_workflows[]=$REPOSITORY/.github/workflows/$workflow@refs/heads/$BASE_BRANCH" )
  done
  if ! gh api "${patch_args[@]}" --silent; then
    restore_runner_group "$GITHUB_SNAPSHOT_DIRECTORY" "$runner_group_id" || fail "runner group update failed and rollback failed"
    GITHUB_MUTATION_ACTIVE=false
    fail "runner group update failed; the previous group settings were restored"
  fi
  assert_repository_snapshot_unchanged
  if ! gh api --method PUT "/orgs/$ORGANIZATION/actions/runner-groups/$runner_group_id/repositories" -H "If-Match: $GITHUB_REPOSITORIES_ETAG" -F "selected_repository_ids[]=$repository_id" --silent; then
    restore_runner_group "$GITHUB_SNAPSHOT_DIRECTORY" "$runner_group_id" || fail "runner repository restriction failed and rollback failed"
    GITHUB_MUTATION_ACTIVE=false
    fail "runner repository restriction failed; the previous group settings were restored"
  fi
  if ! assert_runner_group_configuration; then
    restore_runner_group "$GITHUB_SNAPSHOT_DIRECTORY" "$runner_group_id" || fail "runner group convergence failed and rollback failed"
    GITHUB_MUTATION_ACTIVE=false
    fail "runner group configuration did not converge; the previous group settings were restored"
  fi
  if ! selected="$(gh api "/orgs/$ORGANIZATION/actions/runner-groups/$runner_group_id/repositories?per_page=100" --paginate --jq '.repositories[].full_name')"; then
    restore_runner_group "$GITHUB_SNAPSHOT_DIRECTORY" "$runner_group_id" || fail "runner group convergence check failed and rollback failed"
    GITHUB_MUTATION_ACTIVE=false
    fail "runner group convergence check failed; the previous group settings were restored"
  fi
  if [[ "$selected" != "$REPOSITORY" ]]; then
    restore_runner_group "$GITHUB_SNAPSHOT_DIRECTORY" "$runner_group_id" || fail "runner group convergence failed and rollback failed"
    GITHUB_MUTATION_ACTIVE=false
    fail "runner group repository restriction did not converge; the previous group settings were restored"
  fi
  GITHUB_MUTATION_ACTIVE=false
  cleanup_github_snapshot
  trap - EXIT INT TERM HUP
  echo "Configured restricted runner group $RUNNER_GROUP for $REPOSITORY."
}

render_pool_scope() {
  local repository
  if [[ "$REPOSITORY_SCOPE" == "organization" ]]; then
    printf '      repositoryScope: organization\n'
    if [[ -n "$EXCLUDE_REPOSITORIES" ]]; then
      printf '      excludeRepositories:\n'
      IFS=',' read -r -a excluded_repository_list <<< "$EXCLUDE_REPOSITORIES"
      for repository in "${excluded_repository_list[@]}"; do
        printf '        - %s\n' "$repository"
      done
    fi
  else
    printf '      repositoryScope: selected\n'
    printf '      repositories:\n'
    printf '        - %s\n' "${REPOSITORY#*/}"
  fi
}

render_config() {
  cat <<EOF
runners:
  - name: $RUNNER_NAME
    vm:
      source:
        type: oci
        image: $VM_IMAGE
      hardware:
        ramGb: $VM_RAM_GB
        cpuCores: $VM_CPU_CORES
        audio: false
      run:
        noGraphics: true
        noClipboard: true
        network: softnet
        softnetBlock: "@host"
        guestDNS:
          networkService: Ethernet
          servers:
            - 1.1.1.1
          probeHost: broker.actions.githubusercontent.com
    provisioner:
      type: github
      config:
        appId: $APP_ID
        organization: $ORGANIZATION
        privateKeyPath: $KEY_PATH
        runnerName: $RUNNER_NAME
        ephemeral: true
        runnerGroup: $RUNNER_GROUP
        extraLabels:
          - mobile
          - $RUNNER_LABEL
    pool:
      min: $POOL_MIN
      max: $POOL_MAX
      pollInterval: $POOL_POLL_INTERVAL
$(render_pool_scope)
      matchLabels:
        - $RUNNER_LABEL
    healthCheck:
      command: 'pgrep -fl Runner.Listener'
      interval: 30
      delay: 60
EOF
}

render_launch_agent() {
  local config_path="$1" binary_sha
  binary_sha="$(shasum -a 256 "$SAND_BIN")"
  binary_sha="${binary_sha%% *}"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$DEFAULT_LAUNCH_AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SAND_BIN</string>
    <string>run</string>
    <string>--config</string>
    <string>$config_path</string>
    <string>--log-file</string>
    <string>$DEFAULT_LOG_PATH</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>SAND_BINARY_SHA256</key>
    <string>$binary_sha</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>$HOME</string>
  <key>KeepAlive</key>
  <true/>
  <key>RunAtLoad</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>$DEFAULT_STDOUT_PATH</string>
  <key>StandardErrorPath</key>
  <string>$DEFAULT_STDERR_PATH</string>
</dict>
</plist>
EOF
}

prepare_logs() {
  local path
  mkdir -p "$HOME/Library/Logs"
  [[ "$(file_owner "$HOME/Library/Logs")" == "$(id -u)" ]] || fail "log directory is not owned by the runner user"
  [[ "$((8#$(file_mode "$HOME/Library/Logs") & 8#022))" == 0 ]] || fail "log directory is group/world writable"
  for path in "$DEFAULT_LOG_PATH" "$DEFAULT_STDOUT_PATH" "$DEFAULT_STDERR_PATH"; do
    [[ ! -L "$path" ]] || fail "refusing to manage symlinked log: $path"
    if [[ -e "$path" ]]; then
      [[ -f "$path" && "$(file_owner "$path")" == "$(id -u)" ]] || fail "managed log is not a user-owned regular file: $path"
      chmod 600 "$path"
    else
      MANAGED_LOGS_RECREATED=true
    fi
    install -m 600 /dev/null "$path"
  done
}

stop_agent() {
  local target="gui/$(id -u)/$DEFAULT_LAUNCH_AGENT_LABEL"
  if launchctl print "$target" >/dev/null 2>&1; then
    launchctl bootout "$target" >/dev/null 2>&1 || true
    launchctl print "$target" >/dev/null 2>&1 && fail "existing Sand LaunchAgent did not stop"
  fi
}

backup_managed_file() {
  local source="$1" name="$2"
  if [[ -e "$source" ]]; then
    [[ -f "$source" && ! -L "$source" ]] || fail "managed file is not a regular file: $source"
    install -m 600 "$source" "$INSTALL_BACKUP_DIR/$name"
    : > "$INSTALL_BACKUP_DIR/$name.present"
  else
    : > "$INSTALL_BACKUP_DIR/$name.absent"
  fi
}

restore_managed_file() {
  local target="$1" name="$2"
  if [[ -f "$INSTALL_BACKUP_DIR/$name.present" ]]; then
    install -m 600 "$INSTALL_BACKUP_DIR/$name" "$target"
  else
    rm -f "$target"
  fi
}

rollback_install() {
  local status="$1"
  set +e
  local target="gui/$(id -u)/$DEFAULT_LAUNCH_AGENT_LABEL"
  launchctl bootout "$target" >/dev/null 2>&1 || true
  restore_managed_file "$CONFIG_PATH" config
  restore_managed_file "$LAUNCH_AGENT_PATH" plist
  restore_managed_file "$DEFAULT_LOG_PATH" sand.log
  restore_managed_file "$DEFAULT_STDOUT_PATH" stdout.log
  restore_managed_file "$DEFAULT_STDERR_PATH" stderr.log
  if [[ -f "$INSTALL_BACKUP_DIR/plist.present" ]]; then
    launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PATH" >/dev/null 2>&1 || true
    launchctl kickstart -k "$target" >/dev/null 2>&1 || true
  fi
  rm -f "${config_temporary:-}" "${plist_temporary:-}"
  rm -rf "$INSTALL_BACKUP_DIR"
  echo "Sand install failed; previous managed files were restored where possible." >&2
  exit "$status"
}

cleanup_install() {
  local status="$?"
  trap - EXIT
  if [[ "$status" -ne 0 ]]; then
    rollback_install "$status"
  fi
  rm -f "${config_temporary:-}" "${plist_temporary:-}"
  rm -rf "$INSTALL_BACKUP_DIR"
  exit "$status"
}

print_plan() {
  cat <<EOF
Sand runner plan (read-only)
  scope:         $REPOSITORY_SCOPE
  repository:    ${REPOSITORY:-<automatic organization discovery>}
  exclusions:    ${EXCLUDE_REPOSITORIES:-<none>}
  organization:  ${ORGANIZATION:-<set SAND_GITHUB_ORGANIZATION>}
  runner group:  $RUNNER_GROUP
  runner label:  $RUNNER_LABEL
  GitHub App ID: ${APP_ID:-<set SAND_GITHUB_APP_ID>}
  VM image:      ${VM_IMAGE:-<set SAND_VM_IMAGE with a digest>}
  Sand source:   $SAND_SOURCE_REPOSITORY
  Sand revision: ${SAND_REVISION:-<set SAND_REVISION>}
  config:        $CONFIG_PATH
  LaunchAgent:   $LAUNCH_AGENT_PATH
  isolation:     no graphics, no clipboard, no host mounts, softnet @host block
  workflows:     $WORKFLOWS

Apply only after reviewing the generated values:
  $0 configure-github --apply
  $0 validate
  $0 install --apply
EOF
}

if [[ "$MODE" == "-h" || "$MODE" == "--help" || "$MODE" == "help" ]]; then
  usage
  exit 0
fi

case "$MODE" in
  plan)
    [[ -z "$APPLY" ]] || fail "plan does not accept a second argument"
    validate_plan_inputs
    print_plan
    ;;
  render)
    [[ -z "$APPLY" ]] || fail "render does not accept a second argument"
    require_macos_host
    validate_inputs
    render_config
    ;;
  configure-github)
    [[ "$APPLY" == "--apply" ]] || fail "configure-github is mutating; rerun with --apply"
    require_macos_host
    validate_inputs
    command -v gh >/dev/null || fail "missing required command: gh"
    command -v jq >/dev/null || fail "missing required command: jq"
    configure_github
    ;;
  validate)
    [[ -z "$APPLY" ]] || fail "validate does not accept a second argument"
    require_macos_host
    validate_inputs
    require_commands
    require_tart_version
    require_softnet_version
    require_key
    require_pinned_sand
    temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/mobile-sand-validate.XXXXXX")"
    trap 'rm -rf "${temporary_directory:-}"' EXIT
    render_config > "$temporary_directory/sand.yml"
    render_launch_agent "$CONFIG_PATH" > "$temporary_directory/mobile-runner.plist"
    chmod 600 "$temporary_directory"/*
    "$SAND_BIN" validate --config "$temporary_directory/sand.yml"
    "$SAND_BIN" pool-check --config "$temporary_directory/sand.yml"
    plutil -lint "$temporary_directory/mobile-runner.plist"
    echo "Sand configuration and launch agent validated."
    ;;
  install)
    [[ "$APPLY" == "--apply" ]] || fail "install is mutating; rerun with --apply"
    require_macos_host
    validate_inputs
    require_commands
    require_tart_version
    require_softnet_version
    require_key
    require_pinned_sand
    config_directory="$(dirname "$CONFIG_PATH")"
    launch_directory="$(dirname "$LAUNCH_AGENT_PATH")"
    mkdir -p "$config_directory" "$launch_directory"
    require_secure_parent_directory "$CONFIG_PATH"
    require_secure_parent_directory "$LAUNCH_AGENT_PATH"
    require_secure_parent_directory "$SAND_BIN"
    chmod 700 "$config_directory"
    config_temporary="$(mktemp "$config_directory/.mobile-runner.yml.XXXXXX")"
    plist_temporary="$(mktemp "$launch_directory/.mobile-runner.plist.XXXXXX")"
    INSTALL_BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mobile-sand-install.XXXXXX")"
    trap cleanup_install EXIT
    [[ ! -L "$CONFIG_PATH" && ! -L "$LAUNCH_AGENT_PATH" ]] || fail "refusing to replace a symlinked managed file"
    backup_managed_file "$CONFIG_PATH" config
    backup_managed_file "$LAUNCH_AGENT_PATH" plist
    backup_managed_file "$DEFAULT_LOG_PATH" sand.log
    backup_managed_file "$DEFAULT_STDOUT_PATH" stdout.log
    backup_managed_file "$DEFAULT_STDERR_PATH" stderr.log
    render_config > "$config_temporary"
    render_launch_agent "$CONFIG_PATH" > "$plist_temporary"
    chmod 600 "$config_temporary" "$plist_temporary"
    "$SAND_BIN" validate --config "$config_temporary"
    "$SAND_BIN" pool-check --config "$config_temporary"
    plutil -lint "$plist_temporary"
    prepare_logs
    stop_agent
    install -m 600 "$config_temporary" "$CONFIG_PATH"
    install -m 600 "$plist_temporary" "$LAUNCH_AGENT_PATH"
    launchctl enable "gui/$(id -u)/$DEFAULT_LAUNCH_AGENT_LABEL"
    launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PATH"
    launchctl kickstart -k "gui/$(id -u)/$DEFAULT_LAUNCH_AGENT_LABEL"
    launchctl print "gui/$(id -u)/$DEFAULT_LAUNCH_AGENT_LABEL"
    echo "Persistent Sand runner installed; wait for the ephemeral GitHub runner to report online."
    ;;
  status)
    [[ -z "$APPLY" ]] || fail "status does not accept a second argument"
    require_macos_host
    launchctl print "gui/$(id -u)/$DEFAULT_LAUNCH_AGENT_LABEL"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
