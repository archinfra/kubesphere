#!/usr/bin/env bash
set -Eeuo pipefail

BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONSOLE_DIR="${CONSOLE_DIR:-${BACKEND_DIR}/../kubesphere-console}"
VERSION=""
PUSH_TAGS="false"
GIT_BIN="${GIT_BIN:-git}"
ANNOTATED_TAG="${ANNOTATED_TAG:-false}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
  echo -e "${CYAN}[INFO]${NC} $*"
}

success() {
  echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

die() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Create the same release tag in kubesphere-console and kubesphere.

Usage:
  hack/release/tag-frontend-backend.sh --version v0.1.6 [--console-dir ../kubesphere-console] [--push] [--annotated]

Notes:
  - Pushes the console tag first when --push is used, because the backend release workflow checks out the console tag.
  - Refuses to continue if either worktree has uncommitted changes.
  - Does not overwrite an existing tag.
  - Creates lightweight tags by default so local git identity is not required.
  - Set GIT_BIN=/path/to/git if git is not available in the current shell PATH.
EOF
}

resolve_git() {
  if command -v "${GIT_BIN}" >/dev/null 2>&1; then
    return 0
  fi

  local candidate
  for candidate in \
    "/d/software/Git/cmd/git.exe" \
    "/d/software/Git/bin/git.exe" \
    "/c/Program Files/Git/cmd/git.exe" \
    "/c/Program Files/Git/bin/git.exe"; do
    if [[ -x "${candidate}" ]]; then
      GIT_BIN="${candidate}"
      return 0
    fi
  done

  die "git is required; set GIT_BIN=/path/to/git if it is not in PATH"
}

git_cmd() {
  "${GIT_BIN}" "$@"
}

normalize_version() {
  local value="$1"
  value="${value#refs/tags/}"
  value="${value#v}"
  [[ -n "${value}" ]] || die "version cannot be empty"
  [[ "${value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([._+-][0-9A-Za-z._+-]+)*$ ]] || die "unsupported version format: $1"
  VERSION="v${value}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        normalize_version "$2"
        shift 2
        ;;
      --console-dir)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        CONSOLE_DIR="$2"
        shift 2
        ;;
      --push)
        PUSH_TAGS="true"
        shift
        ;;
      --annotated)
        ANNOTATED_TAG="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  [[ -n "${VERSION}" ]] || die "--version is required"
}

require_repo() {
  local dir="$1"
  [[ -d "${dir}/.git" ]] || die "not a git repository: ${dir}"
}

require_clean_worktree() {
  local dir="$1"
  local label="$2"
  if [[ -n "$(git_cmd -C "${dir}" status --porcelain)" ]]; then
    die "${label} worktree is not clean: ${dir}"
  fi
}

create_tag_if_missing() {
  local dir="$1"
  local label="$2"
  if git_cmd -C "${dir}" rev-parse -q --verify "refs/tags/${VERSION}" >/dev/null; then
    warn "${label} already has tag ${VERSION}; keeping it"
    return 0
  fi

  log "Create ${label} tag ${VERSION}"
  if [[ "${ANNOTATED_TAG}" == "true" ]]; then
    git_cmd -C "${dir}" tag -a "${VERSION}" -m "Release ${VERSION}"
  else
    git_cmd -C "${dir}" tag "${VERSION}"
  fi
}

push_tag() {
  local dir="$1"
  local label="$2"
  log "Push ${label} tag ${VERSION}"
  git_cmd -C "${dir}" push origin "refs/tags/${VERSION}"
}

main() {
  parse_args "$@"
  resolve_git
  require_repo "${BACKEND_DIR}"
  require_repo "${CONSOLE_DIR}"
  require_clean_worktree "${CONSOLE_DIR}" "console"
  require_clean_worktree "${BACKEND_DIR}" "backend"

  create_tag_if_missing "${CONSOLE_DIR}" "console"
  create_tag_if_missing "${BACKEND_DIR}" "backend"

  if [[ "${PUSH_TAGS}" == "true" ]]; then
    push_tag "${CONSOLE_DIR}" "console"
    push_tag "${BACKEND_DIR}" "backend"
  else
    warn "Tags were created locally only. Re-run with --push to push console first and backend second."
  fi

  success "Prepared ${VERSION} for kubesphere-console and kubesphere"
}

main "$@"
