# Engineering Baseline

Date: 2026-04-13

Remote host: `36.138.61.152`

Remote workspace:

- Source root: `/opt/ai-k8s-platform/source`
- Build root: `/opt/ai-k8s-platform/build`
- Logs root: `/opt/ai-k8s-platform/logs`

## Verified Remote Environment

- OS: Ubuntu 24.04.2 LTS
- Kubernetes: v1.31.11, single control-plane node
- Docker: 28.3.3
- Helm: v3.19.2
- Go: `go1.26.2 linux/amd64`
- Node runtime used for console build: `/opt/node-v18.20.4-linux-x64`
- Yarn: `1.22.22`

## Backend Baseline

Selected tests:

```bash
export PATH=/usr/local/go/bin:$PATH
cd /opt/ai-k8s-platform/source/kubesphere
export GOCACHE=/opt/ai-k8s-platform/build/go-cache
export GOMODCACHE=/opt/ai-k8s-platform/build/go-mod
go test -mod=vendor ./pkg/apiserver/... ./pkg/kapis/resources/... ./pkg/kapis/terminal/... ./pkg/kapis/iam/...
```

Entrypoint compile check:

```bash
go test -mod=vendor -run '^$' ./cmd/ks-apiserver ./cmd/ks-controller-manager
```

Binary build:

```bash
make binary
```

Verified artifacts:

- `_output/bin/ks-apiserver`: about 94 MB
- `_output/bin/ks-controller-manager`: about 77 MB

Both binaries were verified as Linux amd64 statically linked executables.

## Console Baseline

Dependency install:

```bash
cd /opt/ai-k8s-platform/source/console
yarn config set registry https://registry.npmmirror.com
yarn install --frozen-lockfile --network-timeout 600000
```

Build:

```bash
export PATH=/opt/node-v18.20.4-linux-x64/bin:$PATH
export NODE_OPTIONS=--openssl-legacy-provider
cd /opt/ai-k8s-platform/source/console
yarn build:locales
yarn build:dll
yarn build:prod
yarn build:server
```

Verified artifacts:

- `dist`: about 53 MB
- `server`: present
- `locales`: about 9.1 MB
- `dist/server.js`: about 2.7 MB

Notes:

- Node 22 is not a safe default for this console codebase.
- Node 18 needs `NODE_OPTIONS=--openssl-legacy-provider` for the old webpack server build.
- A later cleanup should either standardize Node 16 or modernize the frontend build chain.

## Helm And Runtime Baseline

CRDs:

```bash
kubectl apply -f /opt/ai-k8s-platform/source/kubesphere/config/ks-core/charts/ks-crds/crds
```

Core install:

```bash
cd /opt/ai-k8s-platform/source/kubesphere
helm upgrade --install ks-core config/ks-core \
  --namespace kubesphere-system \
  --create-namespace \
  -f /opt/ai-k8s-platform/build/ks-core-dev-values.yaml \
  --timeout 10m
```

Runtime result:

- `ks-apiserver`: `1/1 Running`
- `ks-console`: `1/1 Running`
- `ks-controller-manager`: `1/1 Running`

Access checks:

- Console public URL: `http://36.138.61.152:30880/`
- Console returns HTTP 302 to `/login`.
- API server `/version` responds through the in-cluster service.

## Important Findings

- The chart image helper always renders `registry/repository:tag`; empty registries produce invalid image strings such as `/local-ai/...`.
- CRDs must be installed before Helm dry-run/install validation.
- Docker Hub pulls may time out from the remote server, so the dev loop uses already-available local base images.
- Telemetry is disabled in the dev values.
- Extension repository is disabled in the dev values.
- Appstore-related CRDs and role templates still exist and should be separated later through an explicit boundary plan.

## Reproducible Smoke Command

From Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\hack\ai-native\run-remote-dev-loop.ps1 -Stage smoke
```

Expected result:

- Deployment rollouts succeed.
- Pods and services are listed.
- API server `/version` responds.
- Console returns HTTP 302 to `/login`.
- No recent apiserver/controller errors are printed by the smoke stage.
