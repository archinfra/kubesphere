#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL_SCRIPT="${ROOT_DIR}/hack/release/install-offline.sh"
TEMP_DIR="${ROOT_DIR}/.build/offline-run-images"
PAYLOAD_FILE="${ROOT_DIR}/.build/payload-from-images.tar.gz"
DIST_DIR="${ROOT_DIR}/dist"

VERSION="v0.1.0"
ARCH="amd64"
PLATFORM="linux/amd64"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-ghcr.io}"
IMAGE_NAMESPACE="${IMAGE_NAMESPACE:-archinfra}"
IMAGE_PREFIX=""
APISERVER_IMAGE="${APISERVER_IMAGE:-}"
CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-}"
CONSOLE_IMAGE="${CONSOLE_IMAGE:-}"
KUBECTL_IMAGE="${KUBECTL_IMAGE:-bitnami/kubectl:1.33.1}"
KUBECTL_TARGET_TAG="${KUBECTL_TARGET_TAG:-v1.33.1}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7.2.7-alpine}"
REDIS_TARGET_TAG="${REDIS_TARGET_TAG:-7.2.7-alpine}"
IMAGE_PULL_RETRIES="${IMAGE_PULL_RETRIES:-60}"
IMAGE_PULL_INTERVAL_SECONDS="${IMAGE_PULL_INTERVAL_SECONDS:-30}"
INSTALLER_NAME=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
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
Usage:
  hack/release/package-offline-run-from-images.sh [options]

Options:
  --version VERSION              Installer and component image tag, default: v0.1.0
  --arch amd64|arm64             Target architecture, default: amd64
  --image-registry REGISTRY      Source image registry, default: ghcr.io
  --image-namespace NAMESPACE    Source image namespace/org, default: archinfra
  --apiserver-image IMAGE        Source ks-apiserver image override
  --controller-image IMAGE       Source ks-controller-manager image override
  --console-image IMAGE          Source ks-console image override
  --kubectl-image IMAGE          Source kubectl image, default: bitnami/kubectl:1.33.1
  --redis-image IMAGE            Source redis image, default: redis:7.2.7-alpine

Environment:
  IMAGE_PULL_RETRIES             Pull retry count, default: 60
  IMAGE_PULL_INTERVAL_SECONDS    Seconds between retries, default: 30

Examples:
  hack/release/package-offline-run-from-images.sh --version v0.1.0 --arch amd64
  hack/release/package-offline-run-from-images.sh --version v0.1.0 --image-registry ghcr.io --image-namespace archinfra
EOF
}

normalize_arch() {
  case "$1" in
    amd64|amd|x86_64)
      ARCH="amd64"
      PLATFORM="linux/amd64"
      ;;
    arm64|arm|aarch64)
      ARCH="arm64"
      PLATFORM="linux/arm64"
      ;;
    *)
      die "Unsupported arch: $1"
      ;;
  esac

  INSTALLER_NAME="ai-k8s-platform-${VERSION}-${ARCH}.run"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        VERSION="$2"
        shift 2
        ;;
      --arch|-a)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        normalize_arch "$2"
        shift 2
        ;;
      --image-registry)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        IMAGE_REGISTRY="$2"
        shift 2
        ;;
      --image-namespace)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        IMAGE_NAMESPACE="$2"
        shift 2
        ;;
      --apiserver-image)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        APISERVER_IMAGE="$2"
        shift 2
        ;;
      --controller-image)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        CONTROLLER_IMAGE="$2"
        shift 2
        ;;
      --console-image)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        CONSOLE_IMAGE="$2"
        shift 2
        ;;
      --kubectl-image)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        KUBECTL_IMAGE="$2"
        shift 2
        ;;
      --redis-image)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        REDIS_IMAGE="$2"
        shift 2
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
}

check_requirements() {
  command -v docker >/dev/null 2>&1 || die "docker is required"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  command -v tar >/dev/null 2>&1 || die "tar is required"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"
  [[ -f "${INSTALL_SCRIPT}" ]] || die "install-offline.sh is missing"
  [[ -d "${ROOT_DIR}/config/ks-core" ]] || die "config/ks-core is missing"
  grep -q '^__PAYLOAD_BELOW__$' "${INSTALL_SCRIPT}" || die "install-offline.sh is missing __PAYLOAD_BELOW__ marker"
}

resolve_images() {
  IMAGE_REGISTRY="${IMAGE_REGISTRY%/}"
  IMAGE_NAMESPACE="${IMAGE_NAMESPACE#/}"
  IMAGE_NAMESPACE="${IMAGE_NAMESPACE%/}"
  IMAGE_PREFIX="${IMAGE_REGISTRY}/${IMAGE_NAMESPACE}"

  APISERVER_IMAGE="${APISERVER_IMAGE:-${IMAGE_PREFIX}/ks-apiserver:${VERSION}}"
  CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-${IMAGE_PREFIX}/ks-controller-manager:${VERSION}}"
  CONSOLE_IMAGE="${CONSOLE_IMAGE:-${IMAGE_PREFIX}/ks-console:${VERSION}}"
}

prepare_directories() {
  rm -rf "${TEMP_DIR}" "${PAYLOAD_FILE}"
  mkdir -p "${TEMP_DIR}/charts" "${TEMP_DIR}/images" "${DIST_DIR}"
}

pull_image() {
  local image="$1"
  local attempt
  for ((attempt = 1; attempt <= IMAGE_PULL_RETRIES; attempt++)); do
    log "Pull ${image} (${PLATFORM}), attempt ${attempt}/${IMAGE_PULL_RETRIES}"
    if docker pull --platform "${PLATFORM}" "${image}"; then
      return
    fi
    if [[ "${attempt}" -lt "${IMAGE_PULL_RETRIES}" ]]; then
      sleep "${IMAGE_PULL_INTERVAL_SECONDS}"
    fi
  done

  die "Failed to pull image: ${image}"
}

write_image_manifest() {
  local image_json="${TEMP_DIR}/images/image.json"
  cat >"${image_json}" <<JSON
[
  {
    "arch": "${ARCH}",
    "platform": "${PLATFORM}",
    "component": "ks-apiserver",
    "tag": "${APISERVER_IMAGE}",
    "targetRepository": "ks-apiserver",
    "targetTag": "${VERSION}",
    "tar": "ks-apiserver-${ARCH}.tar"
  },
  {
    "arch": "${ARCH}",
    "platform": "${PLATFORM}",
    "component": "ks-controller-manager",
    "tag": "${CONTROLLER_IMAGE}",
    "targetRepository": "ks-controller-manager",
    "targetTag": "${VERSION}",
    "tar": "ks-controller-manager-${ARCH}.tar"
  },
  {
    "arch": "${ARCH}",
    "platform": "${PLATFORM}",
    "component": "ks-console",
    "tag": "${CONSOLE_IMAGE}",
    "targetRepository": "ks-console",
    "targetTag": "${VERSION}",
    "tar": "ks-console-${ARCH}.tar"
  },
  {
    "arch": "${ARCH}",
    "platform": "${PLATFORM}",
    "component": "kubectl",
    "tag": "${KUBECTL_IMAGE}",
    "targetRepository": "kubectl",
    "targetTag": "${KUBECTL_TARGET_TAG}",
    "tar": "kubectl-${ARCH}.tar"
  },
  {
    "arch": "${ARCH}",
    "platform": "${PLATFORM}",
    "component": "redis",
    "tag": "${REDIS_IMAGE}",
    "targetRepository": "redis",
    "targetTag": "${REDIS_TARGET_TAG}",
    "tar": "redis-${ARCH}.tar"
  }
]
JSON
  jq empty "${image_json}"
}

save_images() {
  log "Pull and save images"
  write_image_manifest
  # 新增：创建 TSV 索引文件
  local image_tsv="${TEMP_DIR}/images/image-index.tsv"
  > "${image_tsv}"

  jq -c '.[]' "${TEMP_DIR}/images/image.json" | while IFS= read -r item; do
    local image tar_name platform target_repo target_tag target_ref
    image="$(jq -r '.tag' <<<"${item}")"
    tar_name="$(jq -r '.tar' <<<"${item}")"
    platform="$(jq -r '.platform' <<<"${item}")"
    target_repo="$(jq -r '.targetRepository' <<<"${item}")"
    target_tag="$(jq -r '.targetTag' <<<"${item}")"
    target_ref="${IMAGE_PREFIX}/${target_repo}:${target_tag}"
    pull_image "${image}"
    log "Save ${image} -> ${tar_name}"
    docker save -o "${TEMP_DIR}/images/${tar_name}" "${image}"

    # 写入 TSV 记录：安装现场 docker load 来源镜像，再 retag/push 到用户指定 registry。
    printf '%s\t%s\t%s\t%s\n' "${tar_name}" "${image}" "${target_ref}" "${platform}" >> "${image_tsv}"
  done

  success "Saved images and generated ${image_tsv}"
}

sed_escape_replacement() {
  printf '%s' "$1" | sed 's/[\\/&]/\\&/g'
}

render_install_script() {
  local rendered="${TEMP_DIR}/install-offline-rendered.sh"
  local escaped_version
  escaped_version="$(sed_escape_replacement "${VERSION}")"
  sed \
    -e "0,/^INSTALLER_VERSION=.*$/s//INSTALLER_VERSION=\"${escaped_version}\"/" \
    -e "s/ai-k8s-platform-v[0-9][0-9A-Za-z._+-]*/ai-k8s-platform-${escaped_version}/g" \
    "${INSTALL_SCRIPT}" >"${rendered}"
  echo "${rendered}"
}

package_payload() {
  log "Package payload"
  cp -a "${ROOT_DIR}/config/ks-core" "${TEMP_DIR}/charts/ks-core"
  printf '%s\n' "${VERSION}" >"${TEMP_DIR}/VERSION"

  (
    cd "${TEMP_DIR}"
    tar -czf "${PAYLOAD_FILE}" VERSION charts images
  )

  tar -tzf "${PAYLOAD_FILE}" >/dev/null 2>&1 || die "Payload verification failed"
}

build_installer() {
  local installer_path="${DIST_DIR}/${INSTALLER_NAME}"
  local rendered_install_script
  rendered_install_script="$(render_install_script)"
  cat "${rendered_install_script}" "${PAYLOAD_FILE}" >"${installer_path}"
  chmod +x "${installer_path}"
  sha256sum "${installer_path}" >"${installer_path}.sha256"
  success "Built ${installer_path}"
  echo "sha256: ${installer_path}.sha256"
}

cleanup() {
  rm -rf "${TEMP_DIR}" "${PAYLOAD_FILE}" >/dev/null 2>&1 || true
}

main() {
  trap cleanup EXIT
  normalize_arch "${ARCH}"
  parse_args "$@"
  normalize_arch "${ARCH}"
  check_requirements
  resolve_images

  echo -e "${BOLD}AI K8s Platform Offline Run Packager${NC}"
  echo "  version: ${VERSION}"
  echo "  arch: ${ARCH}"
  echo "  platform: ${PLATFORM}"
  echo "  apiserver image: ${APISERVER_IMAGE}"
  echo "  controller image: ${CONTROLLER_IMAGE}"
  echo "  console image: ${CONSOLE_IMAGE}"
  echo "  kubectl image: ${KUBECTL_IMAGE}"
  echo "  redis image: ${REDIS_IMAGE}"

  prepare_directories
  save_images
  package_payload
  build_installer
}

main "$@"
