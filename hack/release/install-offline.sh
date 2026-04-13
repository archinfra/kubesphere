#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="ai-k8s-platform"
ACTION="install"
INSTALLER_VERSION="v0.1.0"
WORKDIR="${WORKDIR:-/tmp/${APP_NAME}-installer}"
NAMESPACE="${NAMESPACE:-kubesphere-system}"
RELEASE_NAME="${RELEASE_NAME:-ks-core}"
REGISTRY_REPO="${REGISTRY_REPO:-sealos.hub:5000/ai-k8s-platform}"
REGISTRY_USERNAME="${REGISTRY_USERNAME:-}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-}"
IMAGE_PULL_POLICY="${IMAGE_PULL_POLICY:-IfNotPresent}"
NODE_PORT="${NODE_PORT:-30880}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
SKIP_IMAGE_PREPARE="false"
DELETE_CRDS="false"
AUTO_YES="false"

CHART_DIR="${WORKDIR}/charts/ks-core"
IMAGE_DIR="${WORKDIR}/images"
IMAGE_JSON="${IMAGE_DIR}/image.json"
VALUES_FILE="${WORKDIR}/ks-core-values.yaml"
REGISTRY_ADDR=""
REGISTRY_NAMESPACE=""
KUBECTL_TAG="v1.33.1"
REDIS_TAG="7.2.7-alpine"

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
AI K8s Platform offline installer

Usage:
  ./ai-k8s-platform-v0.1.0-amd64.run install [options]
  ./ai-k8s-platform-v0.1.0-amd64.run status [options]
  ./ai-k8s-platform-v0.1.0-amd64.run uninstall [options]

Options:
  --namespace NAME             Kubernetes namespace, default: kubesphere-system
  --release NAME               Helm release name, default: ks-core
  --registry-repo REPO         Image repository prefix, default: sealos.hub:5000/ai-k8s-platform
  --registry-username USER     Optional registry username
  --registry-password PASS     Optional registry password
  --skip-image-prepare         Skip docker load/tag/push and only run Helm
  --image-pull-policy POLICY   IfNotPresent, Always or Never, default: IfNotPresent
  --node-port PORT             ks-console NodePort, default: 30880
  --timeout DURATION           Helm wait timeout, default: 10m
  --admin-password VALUE       Optional admin password or bcrypt hash for first install
  --delete-crds                Also delete bundled KubeSphere CRDs during uninstall
  -y, --yes                    Do not ask for confirmation
  -h, --help                   Show this help

Examples:
  ./ai-k8s-platform-v0.1.0-amd64.run install -y
  ./ai-k8s-platform-v0.1.0-amd64.run install -y --registry-repo harbor.local/library/ai-k8s-platform
  ./ai-k8s-platform-v0.1.0-amd64.run status
  ./ai-k8s-platform-v0.1.0-amd64.run uninstall -y
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

yaml_quote() {
  local value
  value="$(printf '%s' "$1" | sed "s/'/''/g")"
  printf "'%s'" "${value}"
}

parse_args() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      install|status|uninstall|help)
        ACTION="$1"
        shift
        ;;
    esac
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        NAMESPACE="$2"
        shift 2
        ;;
      --release|--release-name)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        RELEASE_NAME="$2"
        shift 2
        ;;
      --registry|--registry-repo)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        REGISTRY_REPO="$2"
        shift 2
        ;;
      --registry-username|--registry-user)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        REGISTRY_USERNAME="$2"
        shift 2
        ;;
      --registry-password|--registry-pass)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        REGISTRY_PASSWORD="$2"
        shift 2
        ;;
      --skip-image-prepare)
        SKIP_IMAGE_PREPARE="true"
        shift
        ;;
      --image-pull-policy)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        IMAGE_PULL_POLICY="$2"
        shift 2
        ;;
      --node-port)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        NODE_PORT="$2"
        shift 2
        ;;
      --timeout)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        WAIT_TIMEOUT="$2"
        shift 2
        ;;
      --admin-password)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        ADMIN_PASSWORD="$2"
        shift 2
        ;;
      --delete-crds)
        DELETE_CRDS="true"
        shift
        ;;
      -y|--yes)
        AUTO_YES="true"
        shift
        ;;
      -h|--help)
        ACTION="help"
        shift
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

validate_args() {
  case "${ACTION}" in
    install|status|uninstall|help) ;;
    *) die "Unsupported action: ${ACTION}" ;;
  esac

  [[ "${NODE_PORT}" =~ ^[0-9]+$ ]] || die "--node-port must be a number"
  [[ "${REGISTRY_REPO}" == */* ]] || die "--registry-repo must include registry and namespace, for example sealos.hub:5000/ai-k8s-platform"
  REGISTRY_REPO="${REGISTRY_REPO%/}"
  REGISTRY_ADDR="${REGISTRY_REPO%%/*}"
  REGISTRY_NAMESPACE="${REGISTRY_REPO#*/}"
}

check_requirements() {
  case "${ACTION}" in
    help)
      return
      ;;
    status)
      require_cmd kubectl
      command -v helm >/dev/null 2>&1 || warn "helm is not available; release status will be skipped"
      ;;
    uninstall)
      require_cmd kubectl
      require_cmd helm
      ;;
    install)
      require_cmd kubectl
      require_cmd helm
      require_cmd jq
      require_cmd tar
      if [[ "${SKIP_IMAGE_PREPARE}" != "true" ]]; then
        require_cmd docker
      fi
      ;;
  esac
}

confirm() {
  [[ "${AUTO_YES}" == "true" ]] && return
  echo
  echo "Action: ${ACTION}"
  echo "Namespace: ${NAMESPACE}"
  echo "Release: ${RELEASE_NAME}"
  echo "Registry repo: ${REGISTRY_REPO}"
  read -r -p "Continue? [y/N] " answer
  case "${answer}" in
    y|Y|yes|YES) ;;
    *) die "Cancelled" ;;
  esac
}

extract_payload() {
  log "Extract payload to ${WORKDIR}"
  rm -rf "${WORKDIR}"
  mkdir -p "${WORKDIR}"

  local marker_line
  marker_line="$(awk '/^__PAYLOAD_BELOW__$/ { print NR + 1; exit 0; }' "$0")"
  [[ -n "${marker_line}" ]] || die "Payload marker not found"

  tail -n +"${marker_line}" "$0" | tar -xz -C "${WORKDIR}" || die "Payload extraction failed"
  [[ -d "${CHART_DIR}" ]] || die "Chart is missing in payload: ${CHART_DIR}"
  [[ -f "${IMAGE_JSON}" ]] || die "Image manifest is missing in payload: ${IMAGE_JSON}"

  INSTALLER_VERSION="$(cat "${WORKDIR}/VERSION")"
  KUBECTL_TAG="$(jq -r '.[] | select(.component == "kubectl") | .targetTag' "${IMAGE_JSON}" | head -1)"
  REDIS_TAG="$(jq -r '.[] | select(.component == "redis") | .targetTag' "${IMAGE_JSON}" | head -1)"
  [[ -n "${KUBECTL_TAG}" && "${KUBECTL_TAG}" != "null" ]] || KUBECTL_TAG="v1.33.1"
  [[ -n "${REDIS_TAG}" && "${REDIS_TAG}" != "null" ]] || REDIS_TAG="7.2.7-alpine"
}

target_image() {
  local repository="$1"
  local tag="$2"
  printf '%s/%s:%s' "${REGISTRY_REPO}" "${repository}" "${tag}"
}

repository_value() {
  local repository="$1"
  printf '%s/%s' "${REGISTRY_NAMESPACE}" "${repository}"
}

docker_login() {
  [[ -n "${REGISTRY_USERNAME}" && -n "${REGISTRY_PASSWORD}" ]] || return
  log "Login registry ${REGISTRY_ADDR}"
  if ! printf '%s' "${REGISTRY_PASSWORD}" | docker login "${REGISTRY_ADDR}" -u "${REGISTRY_USERNAME}" --password-stdin >/dev/null 2>&1; then
    warn "docker login failed for ${REGISTRY_ADDR}; continuing in case the registry allows anonymous push"
  fi
}

prepare_images() {
  if [[ "${SKIP_IMAGE_PREPARE}" == "true" ]]; then
    warn "Skip image load/tag/push by request"
    return
  fi

  docker_login
  log "Load and push bundled images"

  local count
  count="$(jq 'length' "${IMAGE_JSON}")"
  [[ "${count}" -gt 0 ]] || die "No images found in ${IMAGE_JSON}"

  jq -c '.[]' "${IMAGE_JSON}" | while IFS= read -r item; do
    local source_image target_repository target_tag tar_name target
    source_image="$(jq -r '.tag' <<<"${item}")"
    target_repository="$(jq -r '.targetRepository' <<<"${item}")"
    target_tag="$(jq -r '.targetTag' <<<"${item}")"
    tar_name="$(jq -r '.tar' <<<"${item}")"
    target="$(target_image "${target_repository}" "${target_tag}")"

    [[ -f "${IMAGE_DIR}/${tar_name}" ]] || die "Image tar not found: ${IMAGE_DIR}/${tar_name}"
    log "docker load ${tar_name}"
    docker load -i "${IMAGE_DIR}/${tar_name}" >/dev/null
    docker tag "${source_image}" "${target}"
    docker push "${target}"
  done
}

write_values() {
  log "Write Helm values ${VALUES_FILE}"
  cat >"${VALUES_FILE}" <<YAML
global:
  imageRegistry: $(yaml_quote "${REGISTRY_ADDR}")
  tag: $(yaml_quote "${INSTALLER_VERSION}")

apiserver:
  image:
    registry: $(yaml_quote "${REGISTRY_ADDR}")
    repository: $(yaml_quote "$(repository_value ks-apiserver)")
    tag: $(yaml_quote "${INSTALLER_VERSION}")
    pullPolicy: $(yaml_quote "${IMAGE_PULL_POLICY}")

console:
  image:
    registry: $(yaml_quote "${REGISTRY_ADDR}")
    repository: $(yaml_quote "$(repository_value ks-console)")
    tag: $(yaml_quote "${INSTALLER_VERSION}")
    pullPolicy: $(yaml_quote "${IMAGE_PULL_POLICY}")
  nodePort: ${NODE_PORT}

portal:
  http:
    port: ${NODE_PORT}

controller:
  image:
    registry: $(yaml_quote "${REGISTRY_ADDR}")
    repository: $(yaml_quote "$(repository_value ks-controller-manager)")
    tag: $(yaml_quote "${INSTALLER_VERSION}")
    pullPolicy: $(yaml_quote "${IMAGE_PULL_POLICY}")

telemetry:
  enabled: false

redis:
  image:
    registry: $(yaml_quote "${REGISTRY_ADDR}")
    repository: $(yaml_quote "$(repository_value redis)")
    tag: $(yaml_quote "${REDIS_TAG}")
    pullPolicy: $(yaml_quote "${IMAGE_PULL_POLICY}")
  persistentVolume:
    enabled: false

kubectl:
  image:
    registry: $(yaml_quote "${REGISTRY_ADDR}")
    repository: $(yaml_quote "$(repository_value kubectl)")
    tag: $(yaml_quote "${KUBECTL_TAG}")
    pullPolicy: $(yaml_quote "${IMAGE_PULL_POLICY}")

helmExecutor:
  image:
    registry: $(yaml_quote "${REGISTRY_ADDR}")
    repository: $(yaml_quote "$(repository_value kubectl)")
    tag: $(yaml_quote "${KUBECTL_TAG}")
    pullPolicy: $(yaml_quote "${IMAGE_PULL_POLICY}")

nodeShell:
  image:
    registry: $(yaml_quote "${REGISTRY_ADDR}")
    repository: $(yaml_quote "$(repository_value kubectl)")
    tag: $(yaml_quote "${KUBECTL_TAG}")
    pullPolicy: $(yaml_quote "${IMAGE_PULL_POLICY}")

ksCRDs:
  kubectl:
    image:
      registry: $(yaml_quote "${REGISTRY_ADDR}")
      repository: $(yaml_quote "$(repository_value kubectl)")
      tag: $(yaml_quote "${KUBECTL_TAG}")
      pullPolicy: $(yaml_quote "${IMAGE_PULL_POLICY}")

ksExtensionRepository:
  enabled: false
YAML

  if [[ -n "${ADMIN_PASSWORD}" ]]; then
    cat >>"${VALUES_FILE}" <<YAML

authentication:
  adminPassword: $(yaml_quote "${ADMIN_PASSWORD}")
YAML
  fi
}

apply_crds() {
  log "Apply CRDs"
  kubectl apply -f "${CHART_DIR}/charts/ks-crds/crds"
  for crd in users.iam.kubesphere.io globalroles.iam.kubesphere.io workspaces.tenant.kubesphere.io serviceaccounts.kubesphere.io categories.kubesphere.io; do
    kubectl wait --for=condition=Established --timeout=90s "crd/${crd}" || true
  done
}

install_app() {
  confirm
  extract_payload
  prepare_images
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  apply_crds
  write_values

  log "Helm upgrade/install ${RELEASE_NAME}"
  helm upgrade --install "${RELEASE_NAME}" "${CHART_DIR}" \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    -f "${VALUES_FILE}" \
    --wait \
    --timeout "${WAIT_TIMEOUT}"

  log "Wait rollout"
  kubectl rollout status deploy/ks-apiserver -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
  kubectl rollout status deploy/ks-controller-manager -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
  kubectl rollout status deploy/ks-console -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
  success "Installed ${APP_NAME} ${INSTALLER_VERSION}"
  show_status
}

uninstall_app() {
  confirm
  log "Uninstall Helm release ${RELEASE_NAME}"
  helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" || warn "Helm release was not found or uninstall failed"

  if [[ "${DELETE_CRDS}" == "true" ]]; then
    extract_payload
    log "Delete bundled CRDs"
    kubectl delete -f "${CHART_DIR}/charts/ks-crds/crds" --ignore-not-found=true
  else
    warn "CRDs and user data are kept. Use --delete-crds only for a full lab cleanup."
  fi
}

show_status() {
  echo
  echo "== Release =="
  if command -v helm >/dev/null 2>&1; then
    helm list -n "${NAMESPACE}" --filter "^${RELEASE_NAME}$" || true
  fi

  echo
  echo "== Runtime =="
  kubectl get deploy,pods,svc -n "${NAMESPACE}" -o wide || true

  echo
  echo "== Admin user =="
  kubectl get user admin -o jsonpath='name={.metadata.name} state={.status.state} globalRole={.metadata.annotations.iam\.kubesphere\.io/globalrole} lastLogin={.status.lastLoginTime} lastPasswordChange={.metadata.annotations.iam\.kubesphere\.io/last-password-change-time} uninitialized={.metadata.annotations.iam\.kubesphere\.io/uninitialized}{"\n"}' 2>/dev/null || true

  echo
  echo "== Console =="
  local node_ip node_port
  node_ip="$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  node_port="$(kubectl get svc ks-console -n "${NAMESPACE}" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
  if [[ -n "${node_ip}" && -n "${node_port}" ]]; then
    echo "console URL: http://${node_ip}:${node_port}/"
  else
    echo "console service is not ready"
  fi
}

main() {
  parse_args "$@"
  validate_args
  check_requirements

  case "${ACTION}" in
    help)
      usage
      ;;
    status)
      show_status
      ;;
    install)
      install_app
      ;;
    uninstall)
      uninstall_app
      ;;
  esac
}

main "$@"
exit 0

__PAYLOAD_BELOW__
