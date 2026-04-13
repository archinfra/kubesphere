# GitHub Actions 交付流程

这套流程把前后端镜像构建和离线 `.run` 交付拆成三个可观察的 Action。默认镜像仓库是 `ghcr.io/<GitHub org>`，也可以通过 GitHub org/repo variables 改到 Harbor、Docker Hub 或其他 OCI registry。

## GitHub 变量和密钥

推荐在 GitHub organization 或 repository 里配置:

- `vars.IMAGE_REGISTRY`: 镜像仓库地址，默认 `ghcr.io`。
- `vars.IMAGE_NAMESPACE`: 镜像 namespace，默认 `${{ github.repository_owner }}`。
- `vars.CONSOLE_IMAGE_NAME`: console 镜像名，默认 `ks-console`。
- `vars.APISERVER_IMAGE_NAME`: apiserver 镜像名，默认 `ks-apiserver`。
- `vars.CONTROLLER_IMAGE_NAME`: controller-manager 镜像名，默认 `ks-controller-manager`。
- `secrets.REGISTRY_USERNAME`: 可选。默认使用 `${{ github.actor }}`。
- `secrets.REGISTRY_PASSWORD`: 可选。默认使用 `${{ github.token }}`，适合推送 GHCR。

如果使用 GHCR，并且 package 属于同一个 org，通常只需要确保 workflow permissions 包含 `packages: write` 或 `packages: read`。

## Console 仓库

仓库: `archinfra/kubesphere-console`

Workflow: `Build Console Container Image`

触发方式:

- 推送 `master`、`release-*` 或 `v*` tag。
- 手动 workflow dispatch，输入 `version` 和 `platforms`。

默认产物:

```text
ghcr.io/<org>/ks-console:<version>
```

`v*` tag 构建时额外推送:

```text
ghcr.io/<org>/ks-console:latest
```

## Backend 仓库

仓库: `archinfra/kubesphere`

Workflow: `Build Backend Container Images`

默认产物:

```text
ghcr.io/<org>/ks-apiserver:<version>
ghcr.io/<org>/ks-controller-manager:<version>
```

Workflow: `Build Offline Run Installer`

这个 workflow 不再重新编译前端，而是从镜像仓库拉取以下镜像并打包进 `.run`:

```text
ghcr.io/<org>/ks-apiserver:<version>
ghcr.io/<org>/ks-controller-manager:<version>
ghcr.io/<org>/ks-console:<version>
bitnami/kubectl:1.33.1
redis:7.2.7-alpine
```

最终产物:

```text
dist/ai-k8s-platform-<version>-amd64.run
dist/ai-k8s-platform-<version>-amd64.run.sha256
dist/ai-k8s-platform-<version>-arm64.run
dist/ai-k8s-platform-<version>-arm64.run.sha256
```

## 推荐发布顺序

1. 在 `kubesphere-console` 上推送或手动触发 `Build Console Container Image`，确认 `ks-console:<version>` 已发布。
2. 在 `kubesphere` 上推送或手动触发 `Build Backend Container Images`，确认两个后端镜像已发布。
3. 在 `kubesphere` 上触发 `Build Offline Run Installer`，生成离线 `.run`。
4. 如果用 tag 发布，两个仓库 tag 名保持一致，例如都使用 `v0.1.1`。

## 离线安装

下载 `.run` 和 `.sha256` 后:

```bash
sha256sum -c ai-k8s-platform-v0.1.1-amd64.run.sha256
chmod +x ai-k8s-platform-v0.1.1-amd64.run
./ai-k8s-platform-v0.1.1-amd64.run install -y \
  --registry-repo harbor.local/ai-k8s-platform
```

如果目标仓库需要认证:

```bash
./ai-k8s-platform-v0.1.1-amd64.run install -y \
  --registry-repo harbor.local/ai-k8s-platform \
  --registry-username '<user>' \
  --registry-password '<password>'
```

查看状态:

```bash
./ai-k8s-platform-v0.1.1-amd64.run status
```
