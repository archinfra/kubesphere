#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL_SCRIPT="${ROOT_DIR}/hack/release/install-offline.sh"
TEMP_DIR="${ROOT_DIR}/.build/offline-run"
PAYLOAD_FILE="${ROOT_DIR}/.build/payload.tar.gz"
DIST_DIR="${ROOT_DIR}/dist"

VERSION="v0.1.0"
ARCH="amd64"
PLATFORM="linux/amd64"
BUILD_ALL="false"
CONSOLE_DIR="${CONSOLE_DIR:-${ROOT_DIR}/../console}"
IMAGE_PREFIX="${IMAGE_PREFIX:-docker.io/archinfra}"
INSTALLER_NAME=""
# Backward compatible host toolchain path. NODE_HOME is accepted as an alias,
# but it is no longer copied into runtime images automatically because an
# x64 Node.js directory would break arm64 packages.
HOST_NODE_HOME="${HOST_NODE_HOME:-${NODE_HOME:-}}"
RUNTIME_NODE_HOME="${RUNTIME_NODE_HOME:-}"
BACKEND_BASE_IMAGE="${BACKEND_BASE_IMAGE:-alpine:3.21.3}"
CONSOLE_BASE_IMAGE="${CONSOLE_BASE_IMAGE:-node:18-alpine}"

KUBECTL_PULL_IMAGE="${KUBECTL_PULL_IMAGE:-bitnami/kubectl:1.33.1}"
KUBECTL_TARGET_TAG="${KUBECTL_TARGET_TAG:-v1.33.1}"
REDIS_PULL_IMAGE="${REDIS_PULL_IMAGE:-redis:7.2.7-alpine}"
REDIS_TARGET_TAG="${REDIS_TARGET_TAG:-7.2.7-alpine}"

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

prepare_toolchain_path() {
  if [[ -z "${HOST_NODE_HOME}" && -d /opt/node-v18.20.4-linux-x64 ]]; then
    HOST_NODE_HOME="/opt/node-v18.20.4-linux-x64"
  fi

  if [[ -n "${HOST_NODE_HOME}" ]]; then
    export PATH="${HOST_NODE_HOME}/bin:${PATH}"
  fi
}

usage() {
  cat <<'EOF'
Usage:
  hack/release/build-offline-run.sh [--version v0.1.0] [--arch amd64|arm64|all] [--console-dir PATH]

Environment:
  HOST_NODE_HOME       Optional host Node.js directory used only to build console assets.
                       NODE_HOME is accepted as a backward-compatible alias.
  RUNTIME_NODE_HOME    Optional runtime Node.js directory copied into the console image.
                       Leave empty when CONSOLE_BASE_IMAGE is node:18-alpine.

Examples:
  hack/release/build-offline-run.sh --version v0.1.0 --arch amd64 --console-dir ../console
  hack/release/build-offline-run.sh --version v0.1.0 --arch all --console-dir .build/console-src
EOF
}

normalize_arch() {
  case "$1" in
    amd64|amd|x86_64)
      ARCH="amd64"
      PLATFORM="linux/amd64"
      BUILD_ALL="false"
      ;;
    arm64|arm|aarch64)
      ARCH="arm64"
      PLATFORM="linux/arm64"
      BUILD_ALL="false"
      ;;
    all)
      BUILD_ALL="true"
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
      --console-dir)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        CONSOLE_DIR="$2"
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
  prepare_toolchain_path
  command -v docker >/dev/null 2>&1 || die "docker is required"
  command -v go >/dev/null 2>&1 || die "go is required"
  command -v node >/dev/null 2>&1 || die "node is required"
  command -v yarn >/dev/null 2>&1 || die "yarn is required"
  command -v tar >/dev/null 2>&1 || die "tar is required"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"
  [[ -f "${INSTALL_SCRIPT}" ]] || die "install-offline.sh is missing"
  [[ -d "${ROOT_DIR}/config/ks-core" ]] || die "config/ks-core is missing"
  [[ -d "${CONSOLE_DIR}" ]] || die "console directory does not exist: ${CONSOLE_DIR}"
  [[ -f "${CONSOLE_DIR}/package.json" ]] || die "console package.json is missing: ${CONSOLE_DIR}/package.json"
  grep -q '^__PAYLOAD_BELOW__$' "${INSTALL_SCRIPT}" || die "install-offline.sh is missing __PAYLOAD_BELOW__ marker"
  log "Toolchain: $(go version)"
  log "Toolchain: node $(node -v), yarn $(yarn -v)"
}

prepare_directories() {
  rm -rf "${TEMP_DIR}" "${PAYLOAD_FILE}"
  mkdir -p \
    "${TEMP_DIR}/apiserver" \
    "${TEMP_DIR}/controller" \
    "${TEMP_DIR}/charts" \
    "${TEMP_DIR}/images" \
    "${TEMP_DIR}/console-image/app/server" \
    "${DIST_DIR}"
}

normalize_shell_scripts() {
  find "${ROOT_DIR}/hack" "${ROOT_DIR}/build" -type f -name '*.sh' -exec sed -i 's/\r$//' {} +
}

backend_binary_path() {
  local name="$1"
  printf '%s/_output/local/bin/linux/%s/%s' "${ROOT_DIR}" "${ARCH}" "${name}"
}

assert_binary_arch() {
  local binary="$1"
  [[ -f "${binary}" ]] || die "Binary not found: ${binary}"
  chmod +x "${binary}"

  if command -v file >/dev/null 2>&1; then
    local info
    info="$(file "${binary}")"
    log "${info}"
    case "${ARCH}" in
      amd64)
        grep -Eq 'x86-64|x86_64' <<<"${info}" || die "Binary architecture mismatch for ${binary}, expected amd64"
        ;;
      arm64)
        grep -Eq 'aarch64|ARM aarch64' <<<"${info}" || die "Binary architecture mismatch for ${binary}, expected arm64"
        ;;
    esac
  else
    warn "file command is not available; skip binary architecture check for ${binary}"
  fi
}

build_backend_binaries() {
  log "Build backend binaries for linux/${ARCH}"
  normalize_shell_scripts
  rm -rf "${ROOT_DIR}/_output"
  (
    cd "${ROOT_DIR}"
    KUBE_BUILD_PLATFORMS="linux/${ARCH}" make binary
  )

  assert_binary_arch "$(backend_binary_path ks-apiserver)"
  assert_binary_arch "$(backend_binary_path ks-controller-manager)"
}

build_console_assets() {
  log "Build console assets from ${CONSOLE_DIR}"
  (
    cd "${CONSOLE_DIR}"
    yarn config set registry https://registry.npmmirror.com
    yarn install --frozen-lockfile --network-timeout 600000
    NODE_OPTIONS=--openssl-legacy-provider yarn build:locales
    NODE_OPTIONS=--openssl-legacy-provider yarn build:dll
    NODE_OPTIONS=--openssl-legacy-provider yarn build:prod
    NODE_OPTIONS=--openssl-legacy-provider yarn build:server
  )
}

assert_image_platform() {
  local image="$1"
  local expected="${PLATFORM}"
  local actual
  actual="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "${image}" 2>/dev/null || true)"
  [[ -n "${actual}" ]] || die "Cannot inspect image platform: ${image}"
  [[ "${actual}" == "${expected}" ]] || die "Image platform mismatch: ${image}, expected ${expected}, got ${actual}"
  success "Verified image platform ${image}: ${actual}"
}

assert_runtime_node_arch() {
  [[ -n "${RUNTIME_NODE_HOME}" ]] || return 0
  local node_bin="${RUNTIME_NODE_HOME}/bin/node"
  [[ -x "${node_bin}" ]] || die "RUNTIME_NODE_HOME does not contain executable bin/node: ${RUNTIME_NODE_HOME}"

  if command -v file >/dev/null 2>&1; then
    local info
    info="$(file "${node_bin}")"
    log "Runtime node: ${info}"
    case "${ARCH}" in
      amd64)
        grep -Eq 'x86-64|x86_64' <<<"${info}" || die "RUNTIME_NODE_HOME architecture mismatch, expected amd64"
        ;;
      arm64)
        grep -Eq 'aarch64|ARM aarch64' <<<"${info}" || die "RUNTIME_NODE_HOME architecture mismatch, expected arm64"
        ;;
    esac
  else
    warn "file command is not available; skip RUNTIME_NODE_HOME architecture check"
  fi
}

docker_build_load() {
  local image="$1"
  local context="$2"
  local dockerfile="$3"

  if docker buildx version >/dev/null 2>&1; then
    docker buildx build --platform "${PLATFORM}" --load -t "${image}" -f "${dockerfile}" "${context}"
  else
    docker build --platform "${PLATFORM}" -t "${image}" -f "${dockerfile}" "${context}"
  fi

  assert_image_platform "${image}"
}

build_component_images() {
  local apiserver_image="${IMAGE_PREFIX}/ks-apiserver:${VERSION}"
  local controller_image="${IMAGE_PREFIX}/ks-controller-manager:${VERSION}"
  local console_image="${IMAGE_PREFIX}/ks-console:${VERSION}"

  cp "$(backend_binary_path ks-apiserver)" "${TEMP_DIR}/apiserver/ks-apiserver"
  cp "$(backend_binary_path ks-controller-manager)" "${TEMP_DIR}/controller/ks-controller-manager"
  chmod +x "${TEMP_DIR}/apiserver/ks-apiserver" "${TEMP_DIR}/controller/ks-controller-manager"
  cp -a "${ROOT_DIR}/config/ks-core" "${TEMP_DIR}/controller/ks-core"

  log "Build ${apiserver_image}"
  cat >"${TEMP_DIR}/Dockerfile.ks-apiserver" <<DOCKERFILE
FROM ${BACKEND_BASE_IMAGE}
COPY ks-apiserver /usr/local/bin/ks-apiserver
WORKDIR /app
EXPOSE 9090
CMD ["ks-apiserver", "--logtostderr=true"]
DOCKERFILE
  docker_build_load "${apiserver_image}" "${TEMP_DIR}/apiserver" "${TEMP_DIR}/Dockerfile.ks-apiserver"

  log "Build ${controller_image}"
  cat >"${TEMP_DIR}/Dockerfile.ks-controller-manager" <<DOCKERFILE
FROM ${BACKEND_BASE_IMAGE}
COPY ks-controller-manager /usr/local/bin/ks-controller-manager
COPY ks-core /var/helm-charts/ks-core
WORKDIR /app
EXPOSE 8080 8443
CMD ["ks-controller-manager", "--logtostderr=true", "--leader-elect=true", "--controllers=*"]
DOCKERFILE
  docker_build_load "${controller_image}" "${TEMP_DIR}/controller" "${TEMP_DIR}/Dockerfile.ks-controller-manager"

  log "Prepare console runtime image context"
  cp -a "${CONSOLE_DIR}/dist" "${TEMP_DIR}/console-image/app/dist"
  cp -a \
    "${CONSOLE_DIR}/server/locales" \
    "${CONSOLE_DIR}/server/public" \
    "${CONSOLE_DIR}/server/views" \
    "${CONSOLE_DIR}/server/sample" \
    "${CONSOLE_DIR}/server/configs" \
    "${TEMP_DIR}/console-image/app/server/"
  cp "${CONSOLE_DIR}/package.json" "${TEMP_DIR}/console-image/app/package.json"
  assert_runtime_node_arch
  if [[ -n "${RUNTIME_NODE_HOME}" ]]; then
    mkdir -p "${TEMP_DIR}/console-image/node"
    cp -a "${RUNTIME_NODE_HOME}/." "${TEMP_DIR}/console-image/node/"
  fi

  log "Build ${console_image}"
  cat >"${TEMP_DIR}/console-image/Dockerfile" <<DOCKERFILE
FROM ${CONSOLE_BASE_IMAGE}
USER root
ENV NODE_ENV=production
WORKDIR /opt/kubesphere/console
COPY app/ /opt/kubesphere/console/
EXPOSE 8080
CMD ["npm", "run", "serve"]
DOCKERFILE
  if [[ -n "${RUNTIME_NODE_HOME}" ]]; then
    sed -i '/^WORKDIR /i ENV PATH=/opt/node/bin:$PATH\nCOPY node /opt/node' "${TEMP_DIR}/console-image/Dockerfile"
    sed -i '/^EXPOSE /i RUN mv dist/server.js server/server.js && chmod -R a+rX /opt/kubesphere/console /opt/node' "${TEMP_DIR}/console-image/Dockerfile"
  else
    sed -i '/^EXPOSE /i RUN mv dist/server.js server/server.js && chmod -R a+rX /opt/kubesphere/console' "${TEMP_DIR}/console-image/Dockerfile"
  fi
  docker_build_load "${console_image}" "${TEMP_DIR}/console-image" "${TEMP_DIR}/console-image/Dockerfile"
}

pull_support_images() {
  log "Pull support images for ${PLATFORM}"

  docker pull --platform "${PLATFORM}" "${KUBECTL_PULL_IMAGE}"
  assert_image_platform "${KUBECTL_PULL_IMAGE}"
  docker tag "${KUBECTL_PULL_IMAGE}" "${IMAGE_PREFIX}/kubectl:${KUBECTL_TARGET_TAG}"
  assert_image_platform "${IMAGE_PREFIX}/kubectl:${KUBECTL_TARGET_TAG}"

  docker pull --platform "${PLATFORM}" "${REDIS_PULL_IMAGE}"
  assert_image_platform "${REDIS_PULL_IMAGE}"
  docker tag "${REDIS_PULL_IMAGE}" "${IMAGE_PREFIX}/redis:${REDIS_TARGET_TAG}"
  assert_image_platform "${IMAGE_PREFIX}/redis:${REDIS_TARGET_TAG}"
}

save_images() {
  log "Save images"
  local image_json="${TEMP_DIR}/images/image.json"
  local image_tsv="${TEMP_DIR}/images/image-index.tsv"
  local arch="${ARCH}"
  local platform="${PLATFORM}"

  cat >"${image_json}" <<JSON
[
  {
    "arch": "${ARCH}",
    "platform": "${PLATFORM}",
    "component": "ks-apiserver",
    "tag": "${IMAGE_PREFIX}/ks-apiserver:${VERSION}",
    "targetRepository": "ks-apiserver",
    "targetTag": "${VERSION}",
    "tar": "ks-apiserver-${ARCH}.tar"
  },
  {
    "arch": "${ARCH}",
    "platform": "${PLATFORM}",
    "component": "ks-controller-manager",
    "tag": "${IMAGE_PREFIX}/ks-controller-manager:${VERSION}",
    "targetRepository": "ks-controller-manager",
    "targetTag": "${VERSION}",
    "tar": "ks-controller-manager-${ARCH}.tar"
  },
  {
    "arch": "${ARCH}",
    "platform": "${PLATFORM}",
    "component": "ks-console",
    "tag": "${IMAGE_PREFIX}/ks-console:${VERSION}",
    "targetRepository": "ks-console",
    "targetTag": "${VERSION}",
    "tar": "ks-console-${ARCH}.tar"
  },
  {
    "arch": "${ARCH}",
    "platform": "${PLATFORM}",
    "component": "kubectl",
    "tag": "${IMAGE_PREFIX}/kubectl:${KUBECTL_TARGET_TAG}",
    "targetRepository": "kubectl",
    "targetTag": "${KUBECTL_TARGET_TAG}",
    "tar": "kubectl-${ARCH}.tar"
  },
  {
    "arch": "${ARCH}",
    "platform": "${PLATFORM}",
    "component": "redis",
    "tag": "${IMAGE_PREFIX}/redis:${REDIS_TARGET_TAG}",
    "targetRepository": "redis",
    "targetTag": "${REDIS_TARGET_TAG}",
    "tar": "redis-${ARCH}.tar"
  }
]
JSON

  # 定义镜像列表（每行格式：tar_name|load_ref|target_ref）
  # 注意：load_ref 和 target_ref 在这里相同，因为构建时直接使用最终镜像名
  local images=(
    "ks-apiserver-${arch}.tar|${IMAGE_PREFIX}/ks-apiserver:${VERSION}|${IMAGE_PREFIX}/ks-apiserver:${VERSION}"
    "ks-controller-manager-${arch}.tar|${IMAGE_PREFIX}/ks-controller-manager:${VERSION}|${IMAGE_PREFIX}/ks-controller-manager:${VERSION}"
    "ks-console-${arch}.tar|${IMAGE_PREFIX}/ks-console:${VERSION}|${IMAGE_PREFIX}/ks-console:${VERSION}"
    "kubectl-${arch}.tar|${IMAGE_PREFIX}/kubectl:${KUBECTL_TARGET_TAG}|${IMAGE_PREFIX}/kubectl:${KUBECTL_TARGET_TAG}"
    "redis-${arch}.tar|${IMAGE_PREFIX}/redis:${REDIS_TARGET_TAG}|${IMAGE_PREFIX}/redis:${REDIS_TARGET_TAG}"
  )

  # 写入 TSV 文件头（可选，不加头也可以）
  > "${image_tsv}"  # 清空或创建文件

  # 循环处理每个镜像
  for img in "${images[@]}"; do
    IFS='|' read -r tar_name load_ref target_ref <<< "$img"

    assert_image_platform "${load_ref}"
    log "Save ${load_ref} -> ${tar_name}"
    # 保存镜像
    docker save -o "${TEMP_DIR}/images/${tar_name}" "${load_ref}"

    # 写入 TSV 记录（制表符分隔）
    printf '%s\t%s\t%s\t%s\n' "${tar_name}" "${load_ref}" "${target_ref}" "${platform}" >> "${image_tsv}"
  done

  success "Saved $((${#images[@]})) images and generated ${image_tsv}"
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

build_one() {
  normalize_arch "$1"
  echo -e "${BOLD}AI K8s Platform Offline Run Builder${NC}"
  echo "  version: ${VERSION}"
  echo "  arch: ${ARCH}"
  echo "  platform: ${PLATFORM}"
  echo "  console: ${CONSOLE_DIR}"
  echo "  backend base image: ${BACKEND_BASE_IMAGE}"
  echo "  console base image: ${CONSOLE_BASE_IMAGE}"

  prepare_directories
  build_backend_binaries
  build_console_assets
  build_component_images
  pull_support_images
  save_images
  package_payload
  build_installer
}

main() {
  trap cleanup EXIT
  normalize_arch "${ARCH}"
  parse_args "$@"
  check_requirements

  if [[ "${BUILD_ALL}" == "true" ]]; then
    build_one amd64
    build_one arm64
  else
    build_one "${ARCH}"
  fi
}

main "$@"
