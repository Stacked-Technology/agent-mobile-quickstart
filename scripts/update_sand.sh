#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_SAND_SOURCE_REPOSITORY="https://github.com/Stacked-Technology/sand.git"
readonly DEFAULT_SAND_REVISION="c1632d93ce0b63ae52cc28a03d31eaff4b2c82fa"
readonly DEFAULT_SAND_SOURCE_DIR="$HOME/Github/sand"
readonly DEFAULT_SAND_INSTALL_PATH="$HOME/.local/bin/sand"

MODE="${1:-plan}"
APPLY="${2:-}"
SAND_SOURCE_REPOSITORY_WAS_SET="${SAND_SOURCE_REPOSITORY+x}"
SAND_REVISION_WAS_SET="${SAND_REVISION+x}"
SAND_SOURCE_REPOSITORY="${SAND_SOURCE_REPOSITORY:-$DEFAULT_SAND_SOURCE_REPOSITORY}"
SAND_REVISION="${SAND_REVISION:-$DEFAULT_SAND_REVISION}"
SAND_SOURCE_DIR="${SAND_SOURCE_DIR:-$DEFAULT_SAND_SOURCE_DIR}"
SAND_INSTALL_PATH="${SAND_INSTALL_PATH:-${SAND_BIN:-$DEFAULT_SAND_INSTALL_PATH}}"
SAND_BIN="${SAND_BIN:-$SAND_INSTALL_PATH}"
BUILD_DIRECTORY=""
SOURCE_CLONE_IN_PROGRESS=false
INSTALL_TRANSACTION_ACTIVE=false
INSTALL_STAGING_DIRECTORY=""
INSTALL_BACKUP_DIRECTORY=""

fail() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  scripts/update_sand.sh plan
  scripts/update_sand.sh install --apply

The default source is the maintained public Sand fork and the default revision
is an immutable full commit SHA. Override the source and revision together
when using another public fork. The install command clones/fetches source,
builds only that exact commit, and replaces the local Sand binary after the
build and binary self-check succeed.

Environment overrides:
  SAND_SOURCE_REPOSITORY  SAND_REVISION
  SAND_SOURCE_DIR         SAND_INSTALL_PATH  SAND_BIN
EOF
}

require_macos_host() {
  [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] ||
    fail "Sand requires an Apple Silicon macOS host."
  [[ "$(id -u)" != "0" ]] || fail "Run Sand as the normal runner user, not root."
}

validate_plan_inputs() {
  [[ "$SAND_SOURCE_REPOSITORY_WAS_SET" == "$SAND_REVISION_WAS_SET" ]] ||
    fail "set SAND_SOURCE_REPOSITORY and SAND_REVISION together; both are pinned as one source selection."
  [[ "$SAND_SOURCE_REPOSITORY" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(\.git)?$ ]] ||
    fail "SAND_SOURCE_REPOSITORY must be an HTTPS GitHub repository URL."
  [[ "$SAND_REVISION" =~ ^[0-9a-f]{40}$ ]] ||
    fail "SAND_REVISION must be a full lowercase commit SHA."
  [[ "$SAND_INSTALL_PATH" == "$SAND_BIN" ]] ||
    fail "SAND_INSTALL_PATH and SAND_BIN must refer to the same path."
}

validate_inputs() {
  validate_plan_inputs
  for path_value in "$SAND_SOURCE_DIR" "$SAND_INSTALL_PATH"; do
    [[ "$path_value" == /* && "$path_value" =~ ^[A-Za-z0-9_./\ -]+$ ]] ||
      fail "path must be absolute and contain only supported characters: $path_value"
    [[ "$path_value" != *"/../"* && "$path_value" != */.. ]] ||
      fail "path must not contain parent-directory traversal: $path_value"
    reject_symlinked_ancestors "$path_value"
  done
  [[ ! -L "$SAND_SOURCE_DIR" ]] || fail "refusing to use a symlinked Sand source directory."
  [[ ! -L "$SAND_INSTALL_PATH" ]] || fail "refusing to replace a symlinked Sand binary."
  [[ ! -L "$SAND_INSTALL_PATH.provenance" ]] || fail "refusing to replace symlinked Sand provenance."
  for target_path in "$SAND_INSTALL_PATH" "$SAND_INSTALL_PATH.provenance"; do
    [[ ! -e "$target_path" || -f "$target_path" ]] ||
      fail "Sand install target must be absent or a regular file: $target_path"
  done
}

require_commands() {
  local command_name
  for command_name in git swift sw_vers tar install shasum; do
    command -v "$command_name" >/dev/null || fail "missing required command: $command_name"
  done
}

require_platform_versions() {
  local macos_version macos_major swift_version swift_major swift_minor
  macos_version="$(sw_vers -productVersion 2>/dev/null || true)"
  macos_major="${macos_version%%.*}"
  [[ "$macos_major" =~ ^[0-9]+$ ]] && (( macos_major >= 15 )) ||
    fail "Sand source requires macOS 15 or newer; detected: ${macos_version:-unknown}."

  swift_version="$(swift --version 2>/dev/null | awk '{for (field = 1; field <= NF - 3; field++) if ($field == "Apple" && $(field + 1) == "Swift" && $(field + 2) == "version") { print $(field + 3); exit }}')"
  [[ "$swift_version" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]] ||
    fail "could not determine an Apple Swift toolchain version; Sand requires Swift 6.2 or newer."
  swift_major="${swift_version%%.*}"
  swift_minor="${swift_version#*.}"
  swift_minor="${swift_minor%%.*}"
  (( swift_major > 6 || (swift_major == 6 && swift_minor >= 2) )) ||
    fail "Sand source requires Swift 6.2 or newer; detected: $swift_version."
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

safe_git() {
  GIT_CONFIG_GLOBAL=/dev/null \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_TERMINAL_PROMPT=0 \
    git -c credential.helper= -c core.hooksPath=/dev/null "$@"
}

normalize_repository_reference() {
  local value="$1"
  value="${value%.git}"
  case "$value" in
    https://github.com/*)
      printf '%s\n' "${value#https://github.com/}"
      ;;
    git@github.com:*)
      printf '%s\n' "${value#git@github.com:}"
      ;;
    ssh://git@github.com/*)
      printf '%s\n' "${value#ssh://git@github.com/}"
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
}

require_owned_install_directory() {
  local install_directory
  install_directory="$(dirname "$SAND_INSTALL_PATH")"
  mkdir -p "$install_directory"
  [[ -d "$install_directory" && ! -L "$install_directory" ]] ||
    fail "Sand install directory is missing or symlinked: $install_directory"
  [[ "$(file_owner "$install_directory")" == "$(id -u)" ]] ||
    fail "Sand install directory must be owned by the runner user."
  [[ "$((8#$(file_mode "$install_directory") & 8#022))" == 0 ]] ||
    fail "Sand install directory must not be group/world writable."
}

prepare_source() {
  local source_parent remote_url
  source_parent="$(dirname "$SAND_SOURCE_DIR")"
  mkdir -p "$source_parent"
  if [[ -e "$SAND_SOURCE_DIR" ]]; then
    [[ -d "$SAND_SOURCE_DIR" ]] || fail "Sand source path is not a directory: $SAND_SOURCE_DIR"
    [[ "$(file_owner "$SAND_SOURCE_DIR")" == "$(id -u)" ]] ||
      fail "Sand source directory must be owned by the runner user."
    safe_git -C "$SAND_SOURCE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
      fail "Sand source directory is not a Git worktree: $SAND_SOURCE_DIR"
    [[ -z "$(safe_git -C "$SAND_SOURCE_DIR" status --porcelain)" ]] ||
      fail "Sand source directory has local changes; use a clean dedicated checkout."
    remote_url="$(safe_git -C "$SAND_SOURCE_DIR" remote get-url origin 2>/dev/null || true)"
    [[ "$(normalize_repository_reference "$remote_url")" == "$(normalize_repository_reference "$SAND_SOURCE_REPOSITORY")" ]] ||
      fail "Sand source origin does not match SAND_SOURCE_REPOSITORY."
  else
    SOURCE_CLONE_IN_PROGRESS=true
    safe_git clone --no-checkout "$SAND_SOURCE_REPOSITORY" "$SAND_SOURCE_DIR"
    SOURCE_CLONE_IN_PROGRESS=false
  fi
  safe_git -C "$SAND_SOURCE_DIR" fetch --no-tags --depth=1 origin "$SAND_REVISION"
  GIT_NO_REPLACE_OBJECTS=1 safe_git -C "$SAND_SOURCE_DIR" cat-file -e "$SAND_REVISION^{commit}" 2>/dev/null ||
    fail "pinned Sand revision is unavailable from the configured source."
  local resolved_revision
  resolved_revision="$(GIT_NO_REPLACE_OBJECTS=1 safe_git -C "$SAND_SOURCE_DIR" rev-parse --verify "$SAND_REVISION^{commit}")"
  [[ "$resolved_revision" == "$SAND_REVISION" ]] ||
    fail "pinned Sand revision did not resolve to its exact commit SHA."
}

build_sand() {
  local build_directory="$1"
  GIT_NO_REPLACE_OBJECTS=1 safe_git -C "$SAND_SOURCE_DIR" archive "$SAND_REVISION" | tar -x -C "$build_directory"
  [[ -f "$build_directory/Package.resolved" && ! -L "$build_directory/Package.resolved" ]] ||
    fail "pinned Sand source is missing Package.resolved."
  local resolved_before resolved_after
  resolved_before="$(shasum -a 256 "$build_directory/Package.resolved")"
  resolved_before="${resolved_before%% *}"
  swift build \
    --configuration release \
    --package-path "$build_directory" >&2
  resolved_after="$(shasum -a 256 "$build_directory/Package.resolved")"
  resolved_after="${resolved_after%% *}"
  [[ "$resolved_before" == "$resolved_after" ]] ||
    fail "SwiftPM changed Package.resolved during the build."
  local binary="$build_directory/.build/release/sand"
  [[ -f "$binary" && -x "$binary" ]] || fail "Sand release binary was not produced."
  "$binary" --help >/dev/null || fail "built Sand binary failed its self-check."
  printf '%s\n' "$binary"
}

install_sand() {
  local built_binary="$1" resolved_sha="$2" toolchain_sha="$3"
  local install_directory staging_directory backup_directory binary_sha
  install_directory="$(dirname "$SAND_INSTALL_PATH")"
  require_owned_install_directory
  staging_directory="$(mktemp -d "$install_directory/.sand-install.XXXXXX")"
  backup_directory="$(mktemp -d "$install_directory/.sand-backup.XXXXXX")"
  INSTALL_STAGING_DIRECTORY="$staging_directory"
  INSTALL_BACKUP_DIRECTORY="$backup_directory"
  if [[ -f "$SAND_INSTALL_PATH" ]]; then
    install -m 755 "$SAND_INSTALL_PATH" "$backup_directory/sand"
    : > "$backup_directory/sand.present"
  else
    : > "$backup_directory/sand.absent"
  fi
  if [[ -f "$SAND_INSTALL_PATH.provenance" ]]; then
    install -m 644 "$SAND_INSTALL_PATH.provenance" "$backup_directory/sand.provenance"
    : > "$backup_directory/sand.provenance.present"
  else
    : > "$backup_directory/sand.provenance.absent"
  fi
  install -m 755 "$built_binary" "$staging_directory/sand"
  binary_sha="$(shasum -a 256 "$staging_directory/sand")"
  binary_sha="${binary_sha%% *}"
  printf '%s %s source=%s resolved_sha256=%s toolchain_sha256=%s\n' \
    "$SAND_REVISION" "$binary_sha" "$SAND_SOURCE_REPOSITORY" "$resolved_sha" "$toolchain_sha" \
    > "$staging_directory/sand.provenance"
  chmod 644 "$staging_directory/sand.provenance"
  INSTALL_TRANSACTION_ACTIVE=true
  mv "$staging_directory/sand" "$SAND_INSTALL_PATH" ||
    fail "Sand binary installation failed; the previous binary and provenance were restored."
  mv "$staging_directory/sand.provenance" "$SAND_INSTALL_PATH.provenance" ||
    fail "Sand binary installation failed; the previous binary and provenance were restored."
  INSTALL_TRANSACTION_ACTIVE=false
  rm -rf "$staging_directory"
  rm -rf "$backup_directory"
  INSTALL_STAGING_DIRECTORY=""
  INSTALL_BACKUP_DIRECTORY=""
  echo "Installed Sand revision $SAND_REVISION from $SAND_SOURCE_REPOSITORY."
  echo "Binary SHA-256: $binary_sha"
}

restore_install_transaction() {
  set +e
  rm -f "$SAND_INSTALL_PATH" "$SAND_INSTALL_PATH.provenance"
  if [[ -f "${INSTALL_BACKUP_DIRECTORY:-}/sand.present" ]]; then
    mv "$INSTALL_BACKUP_DIRECTORY/sand" "$SAND_INSTALL_PATH"
  fi
  if [[ -f "${INSTALL_BACKUP_DIRECTORY:-}/sand.provenance.present" ]]; then
    mv "$INSTALL_BACKUP_DIRECTORY/sand.provenance" "$SAND_INSTALL_PATH.provenance"
  fi
}

cleanup_update() {
  local status="$?"
  trap - EXIT INT TERM HUP
  if [[ "$INSTALL_TRANSACTION_ACTIVE" == true ]]; then
    restore_install_transaction
  fi
  rm -rf "${INSTALL_STAGING_DIRECTORY:-}" "${INSTALL_BACKUP_DIRECTORY:-}" "${BUILD_DIRECTORY:-}"
  if [[ "$status" -ne 0 && "$SOURCE_CLONE_IN_PROGRESS" == true && -d "$SAND_SOURCE_DIR" && ! -L "$SAND_SOURCE_DIR" && "$(file_owner "$SAND_SOURCE_DIR")" == "$(id -u)" ]]; then
    rm -rf "$SAND_SOURCE_DIR"
  fi
  exit "$status"
}

print_plan() {
  cat <<EOF
Sand source plan (read-only)
  source:       $SAND_SOURCE_REPOSITORY
  revision:     $SAND_REVISION
  source dir:   $SAND_SOURCE_DIR
  install path: $SAND_INSTALL_PATH

Apply only after reviewing the immutable source and target path:
  $0 install --apply
  scripts/setup_sand_github_runner.sh validate
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
  install)
    [[ "$APPLY" == "--apply" ]] || fail "install is mutating; rerun with --apply"
    require_macos_host
    validate_inputs
    require_commands
    require_platform_versions
    trap cleanup_update EXIT INT TERM HUP
    prepare_source
    BUILD_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/mobile-sand-build.XXXXXX")"
    build_sand "$BUILD_DIRECTORY"
    built_binary="$BUILD_DIRECTORY/.build/release/sand"
    resolved_sha="$(shasum -a 256 "$BUILD_DIRECTORY/Package.resolved")"
    resolved_sha="${resolved_sha%% *}"
    toolchain_sha="$(swift --version | shasum -a 256)"
    toolchain_sha="${toolchain_sha%% *}"
    install_sand "$built_binary" "$resolved_sha" "$toolchain_sha"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
