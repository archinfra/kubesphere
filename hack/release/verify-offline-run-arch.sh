#!/usr/bin/env bash
set -Eeuo pipefail

RUN_FILE="${1:-}"
EXPECTED_ARCH="${2:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
die() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  hack/release/verify-offline-run-arch.sh dist/ai-k8s-platform-v0.1.0-arm64.run [amd64|arm64]

What it checks:
  - extracts the embedded payload without installing it
  - reads images/image-index.tsv
  - reads every docker-save tar's config JSON
  - verifies os/architecture matches the package platform
USAGE
}

normalize_arch() {
  case "$1" in
    amd64|x86_64) echo "linux/amd64" ;;
    arm64|aarch64) echo "linux/arm64" ;;
    linux/amd64|linux/arm64) echo "$1" ;;
    "") echo "" ;;
    *) die "Unsupported expected architecture: $1" ;;
  esac
}

[[ -n "${RUN_FILE}" ]] || { usage; exit 2; }
[[ -f "${RUN_FILE}" ]] || die "run file not found: ${RUN_FILE}"
command -v tar >/dev/null 2>&1 || die "tar is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

EXPECTED_PLATFORM="$(normalize_arch "${EXPECTED_ARCH}")"
TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t offline-run-verify.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

marker_line="$(awk '/^__PAYLOAD_BELOW__$/ { print NR + 1; exit 0; }' "${RUN_FILE}")"
[[ -n "${marker_line}" ]] || die "Payload marker not found in ${RUN_FILE}"

tail -n +"${marker_line}" "${RUN_FILE}" | tar -xz -C "${TMP_DIR}"
IMAGE_INDEX="${TMP_DIR}/images/image-index.tsv"
[[ -f "${IMAGE_INDEX}" ]] || die "image-index.tsv not found in package"

count=0
while IFS=$'\t' read -r tar_name load_ref target_ref platform || [[ -n "${tar_name}${load_ref}${target_ref}${platform}" ]]; do
  [[ -n "${tar_name}" ]] || continue
  [[ -n "${platform}" ]] || die "Missing platform column for ${tar_name}"
  [[ -z "${EXPECTED_PLATFORM}" || "${platform}" == "${EXPECTED_PLATFORM}" ]] || die "Package platform mismatch: expected ${EXPECTED_PLATFORM}, index has ${platform}"

  tar_path="${TMP_DIR}/images/${tar_name}"
  [[ -f "${tar_path}" ]] || die "Image tar not found: ${tar_path}"

  config_file="$(tar -O -xf "${tar_path}" manifest.json | jq -r '.[0].Config')"
  [[ -n "${config_file}" && "${config_file}" != "null" ]] || die "Cannot find config file in ${tar_name}"

  os="$(tar -O -xf "${tar_path}" "${config_file}" | jq -r '.os')"
  arch="$(tar -O -xf "${tar_path}" "${config_file}" | jq -r '.architecture')"
  actual="${os}/${arch}"

  [[ "${actual}" == "${platform}" ]] || die "Image tar platform mismatch: ${tar_name}, index=${platform}, actual=${actual}, image=${load_ref}"
  success "${tar_name}: ${actual}"
  count=$((count + 1))
done < "${IMAGE_INDEX}"

[[ ${count} -gt 0 ]] || die "No images found in ${IMAGE_INDEX}"
success "Verified ${count} image tar files in ${RUN_FILE}"
