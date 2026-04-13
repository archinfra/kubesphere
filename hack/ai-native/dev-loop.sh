#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT=${SOURCE_ROOT:-/opt/ai-k8s-platform/source}
BUILD_ROOT=${BUILD_ROOT:-/opt/ai-k8s-platform/build}
KUBESPHERE_DIR=${KUBESPHERE_DIR:-${SOURCE_ROOT}/kubesphere}
CONSOLE_DIR=${CONSOLE_DIR:-${SOURCE_ROOT}/console}
NODE_HOME=${NODE_HOME:-/opt/node-v18.20.4-linux-x64}
GO_BIN_DIR=${GO_BIN_DIR:-/usr/local/go/bin}

IMAGE_REPO=${IMAGE_REPO:-local-ai}
IMAGE_TAG=${IMAGE_TAG:-dev}
BACKEND_BASE_IMAGE=${BACKEND_BASE_IMAGE:-sealos.hub:5000/kube4/busybox:v1}
CONSOLE_BASE_IMAGE=${CONSOLE_BASE_IMAGE:-sealos.hub:5000/kube4/os-shell:12-debian-12-r51}

KUBECTL_IMAGE_REGISTRY=${KUBECTL_IMAGE_REGISTRY:-registry.cn-beijing.aliyuncs.com}
KUBECTL_IMAGE_REPOSITORY=${KUBECTL_IMAGE_REPOSITORY:-kubesphereio/kubectl}
KUBECTL_IMAGE_TAG=${KUBECTL_IMAGE_TAG:-v1.33.1}
REDIS_IMAGE_REGISTRY=${REDIS_IMAGE_REGISTRY:-sealos.hub:5000}
REDIS_IMAGE_REPOSITORY=${REDIS_IMAGE_REPOSITORY:-kube4/dataprotection-redis}
REDIS_IMAGE_TAG=${REDIS_IMAGE_TAG:-7.2.7-alpine}

NAMESPACE=${NAMESPACE:-kubesphere-system}
RELEASE=${RELEASE:-ks-core}
VALUES_FILE=${VALUES_FILE:-${BUILD_ROOT}/ks-core-dev-values.yaml}
IMAGE_BUILD_ROOT=${IMAGE_BUILD_ROOT:-${BUILD_ROOT}/dev-images}

log() {
  printf '\n== %s ==\n' "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

prepare_env() {
  export PATH="${GO_BIN_DIR}:${NODE_HOME}/bin:${PATH}"
  export GOCACHE="${GOCACHE:-${BUILD_ROOT}/go-cache}"
  export GOMODCACHE="${GOMODCACHE:-${BUILD_ROOT}/go-mod}"
  export NODE_OPTIONS="${NODE_OPTIONS:---openssl-legacy-provider}"
  mkdir -p "${BUILD_ROOT}" "${GOCACHE}" "${GOMODCACHE}"

  require_cmd go
  require_cmd node
  require_cmd yarn
  require_cmd docker
  require_cmd helm
  require_cmd kubectl
}

normalize_shell_scripts() {
  find "${KUBESPHERE_DIR}/hack" "${KUBESPHERE_DIR}/build" -type f -name '*.sh' -exec sed -i 's/\r$//' {} +
}

backend() {
  prepare_env
  normalize_shell_scripts
  log "backend tests"
  cd "${KUBESPHERE_DIR}"
  go test -mod=vendor ./pkg/apiserver/... ./pkg/kapis/resources/... ./pkg/kapis/terminal/... ./pkg/kapis/iam/...
  go test -mod=vendor -run '^$' ./cmd/ks-apiserver ./cmd/ks-controller-manager

  log "backend binaries"
  make binary
  ls -lh _output/bin/ks-apiserver _output/bin/ks-controller-manager
}

frontend() {
  prepare_env
  log "frontend dependencies"
  cd "${CONSOLE_DIR}"
  yarn config set registry https://registry.npmmirror.com
  yarn install --frozen-lockfile --network-timeout 600000

  log "frontend build"
  yarn build:locales
  yarn build:dll
  yarn build:prod
  yarn build:server
  ls -lh dist/server.js
}

assert_safe_build_root() {
  case "${IMAGE_BUILD_ROOT}" in
    "${BUILD_ROOT}"/*) ;;
    *)
      echo "refusing to clean IMAGE_BUILD_ROOT outside BUILD_ROOT: ${IMAGE_BUILD_ROOT}" >&2
      exit 1
      ;;
  esac
}

images() {
  prepare_env
  assert_safe_build_root
  log "prepare image contexts"
  rm -rf "${IMAGE_BUILD_ROOT}"
  mkdir -p "${IMAGE_BUILD_ROOT}/apiserver" "${IMAGE_BUILD_ROOT}/controller" "${IMAGE_BUILD_ROOT}/console/app/server" "${IMAGE_BUILD_ROOT}/console/node"

  cp "${KUBESPHERE_DIR}/_output/bin/ks-apiserver" "${IMAGE_BUILD_ROOT}/apiserver/"
  cp "${KUBESPHERE_DIR}/_output/bin/ks-controller-manager" "${IMAGE_BUILD_ROOT}/controller/"
  cp -a "${KUBESPHERE_DIR}/config/ks-core" "${IMAGE_BUILD_ROOT}/controller/ks-core"

  log "build backend images"
  cd "${IMAGE_BUILD_ROOT}/apiserver"
  docker build -t "docker.io/${IMAGE_REPO}/ks-apiserver:${IMAGE_TAG}" -f - . <<DOCKERFILE
FROM ${BACKEND_BASE_IMAGE}
COPY ks-apiserver /usr/local/bin/ks-apiserver
WORKDIR /app
EXPOSE 9090
CMD ["ks-apiserver", "--logtostderr=true"]
DOCKERFILE

  cd "${IMAGE_BUILD_ROOT}/controller"
  docker build -t "docker.io/${IMAGE_REPO}/ks-controller-manager:${IMAGE_TAG}" -f - . <<DOCKERFILE
FROM ${BACKEND_BASE_IMAGE}
COPY ks-controller-manager /usr/local/bin/ks-controller-manager
COPY ks-core /var/helm-charts/ks-core
WORKDIR /app
EXPOSE 8080 8443
CMD ["ks-controller-manager", "--logtostderr=true", "--leader-elect=true", "--controllers=*"]
DOCKERFILE

  log "prepare console image context"
  cp -a "${NODE_HOME}/." "${IMAGE_BUILD_ROOT}/console/node/"
  cp -a "${CONSOLE_DIR}/dist" "${IMAGE_BUILD_ROOT}/console/app/dist"
  cp -a \
    "${CONSOLE_DIR}/server/locales" \
    "${CONSOLE_DIR}/server/public" \
    "${CONSOLE_DIR}/server/views" \
    "${CONSOLE_DIR}/server/sample" \
    "${CONSOLE_DIR}/server/configs" \
    "${IMAGE_BUILD_ROOT}/console/app/server/"
  cp "${CONSOLE_DIR}/package.json" "${IMAGE_BUILD_ROOT}/console/app/package.json"

  log "build console image"
  cd "${IMAGE_BUILD_ROOT}/console"
  docker build -t "docker.io/${IMAGE_REPO}/ks-console:${IMAGE_TAG}" -f - . <<DOCKERFILE
FROM ${CONSOLE_BASE_IMAGE}
USER root
ENV PATH=/opt/node/bin:\$PATH
ENV NODE_ENV=production
WORKDIR /opt/kubesphere/console
COPY node /opt/node
COPY app/ /opt/kubesphere/console/
RUN mv dist/server.js server/server.js && chmod -R a+rX /opt/kubesphere/console /opt/node
EXPOSE 8080
CMD ["npm", "run", "serve"]
DOCKERFILE

  docker images --format '{{.Repository}}:{{.Tag}} {{.Size}} {{.CreatedSince}}' | grep "^docker.io/${IMAGE_REPO}/\\|^${IMAGE_REPO}/" || true
}

values() {
  prepare_env
  log "write helm values"
  cat >"${VALUES_FILE}" <<YAML
global:
  imageRegistry: docker.io
  tag: ${IMAGE_TAG}

apiserver:
  image:
    registry: docker.io
    repository: ${IMAGE_REPO}/ks-apiserver
    tag: ${IMAGE_TAG}
    pullPolicy: IfNotPresent

console:
  image:
    registry: docker.io
    repository: ${IMAGE_REPO}/ks-console
    tag: ${IMAGE_TAG}
    pullPolicy: IfNotPresent

controller:
  image:
    registry: docker.io
    repository: ${IMAGE_REPO}/ks-controller-manager
    tag: ${IMAGE_TAG}
    pullPolicy: IfNotPresent

telemetry:
  enabled: false

redis:
  image:
    registry: ${REDIS_IMAGE_REGISTRY}
    repository: ${REDIS_IMAGE_REPOSITORY}
    tag: ${REDIS_IMAGE_TAG}
    pullPolicy: IfNotPresent
  persistentVolume:
    enabled: false

kubectl:
  image:
    registry: ${KUBECTL_IMAGE_REGISTRY}
    repository: ${KUBECTL_IMAGE_REPOSITORY}
    tag: ${KUBECTL_IMAGE_TAG}
    pullPolicy: IfNotPresent

helmExecutor:
  image:
    registry: ${KUBECTL_IMAGE_REGISTRY}
    repository: ${KUBECTL_IMAGE_REPOSITORY}
    tag: ${KUBECTL_IMAGE_TAG}
    pullPolicy: IfNotPresent

nodeShell:
  image:
    registry: ${KUBECTL_IMAGE_REGISTRY}
    repository: ${KUBECTL_IMAGE_REPOSITORY}
    tag: ${KUBECTL_IMAGE_TAG}
    pullPolicy: IfNotPresent

ksCRDs:
  kubectl:
    image:
      registry: ${KUBECTL_IMAGE_REGISTRY}
      repository: ${KUBECTL_IMAGE_REPOSITORY}
      tag: ${KUBECTL_IMAGE_TAG}
      pullPolicy: IfNotPresent

ksExtensionRepository:
  enabled: false
YAML
  cat "${VALUES_FILE}"
}

crds() {
  prepare_env
  log "apply CRDs"
  kubectl apply -f "${KUBESPHERE_DIR}/config/ks-core/charts/ks-crds/crds"
  for crd in users.iam.kubesphere.io globalroles.iam.kubesphere.io workspaces.tenant.kubesphere.io serviceaccounts.kubesphere.io categories.kubesphere.io; do
    kubectl wait --for=condition=Established --timeout=90s "crd/${crd}"
  done
}

deploy() {
  prepare_env
  values
  log "helm dry-run"
  cd "${KUBESPHERE_DIR}"
  helm upgrade --install "${RELEASE}" config/ks-core \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    -f "${VALUES_FILE}" \
    --dry-run >/tmp/ks-core-dry-run.txt
  tail -40 /tmp/ks-core-dry-run.txt

  log "helm deploy"
  helm upgrade --install "${RELEASE}" config/ks-core \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    -f "${VALUES_FILE}" \
    --timeout 10m
}

smoke() {
  prepare_env
  log "rollout"
  kubectl rollout status deploy/ks-apiserver -n "${NAMESPACE}" --timeout=180s
  kubectl rollout status deploy/ks-controller-manager -n "${NAMESPACE}" --timeout=180s
  kubectl rollout status deploy/ks-console -n "${NAMESPACE}" --timeout=180s

  log "pods and services"
  kubectl get pods -n "${NAMESPACE}" -o wide
  kubectl get svc -n "${NAMESPACE}" -o wide

  log "api version"
  local api_ip
  api_ip=$(kubectl get svc ks-apiserver -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}')
  curl -sS -m 10 "http://${api_ip}/version"

  log "console"
  local node_ip node_port
  node_ip=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  node_port=$(kubectl get svc ks-console -n "${NAMESPACE}" -o jsonpath='{.spec.ports[0].nodePort}')
  curl -sS -I -m 10 "http://${node_ip}:${node_port}/" | head -10

  log "recent errors"
  kubectl logs -n "${NAMESPACE}" deploy/ks-apiserver --since=20s | grep -E '^E|error|failed' || true
  kubectl logs -n "${NAMESPACE}" deploy/ks-controller-manager --since=20s | grep -E '^E|error|failed' || true
}

usage() {
  cat <<EOF
Usage: $0 [backend|frontend|images|values|crds|deploy|smoke|all]

Default: smoke
EOF
}

main() {
  local stage=${1:-smoke}
  case "${stage}" in
    backend) backend ;;
    frontend) frontend ;;
    images) images ;;
    values) values ;;
    crds) crds ;;
    deploy) deploy ;;
    smoke) smoke ;;
    all)
      backend
      frontend
      images
      crds
      deploy
      smoke
      ;;
    -h|--help|help) usage ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
