# GitHub Actions 交付流程

这个项目现在以 `archinfra` 下的代码为原始代码源，不再保留 KubeSphere upstream 的同步、npm 发布、nightly、release-drafter、issue webhook 等维护型 Actions。当前只保留我们自己的交付闭环:

- `archinfra/kubesphere-console`: 构建并推送 console 多架构镜像。
- `archinfra/kubesphere`: 构建并推送后端多架构镜像。
- `archinfra/kubesphere`: 从已发布镜像封装 amd64/arm64 离线 `.run`，并发布到 GitHub Release。

## GitHub 变量和密钥

推荐在 GitHub organization 或 repository 里配置:

- `vars.IMAGE_REGISTRY`: 镜像仓库地址，默认 `ghcr.io`。
- `vars.IMAGE_NAMESPACE`: 通用镜像 namespace，可选。GHCR 下更推荐使用下面两个 repo-scoped namespace。
- `vars.BACKEND_IMAGE_NAMESPACE`: 后端镜像 namespace，默认 `${{ github.repository }}`，例如 `archinfra/kubesphere`。
- `vars.CONSOLE_IMAGE_NAMESPACE`: console 仓库独立构建的镜像 namespace，默认 `${{ github.repository }}`，在 console 仓库里即 `archinfra/kubesphere-console`。
- `vars.CONSOLE_RELEASE_IMAGE_NAMESPACE`: 后端 release workflow 内部构建 console 镜像时使用的 namespace，默认和后端一致，例如 `archinfra/kubesphere`。
- `vars.CONSOLE_REPOSITORY`: 后端 release workflow checkout 的 console 仓库，默认 `<org>/kubesphere-console`。
- `vars.CONSOLE_IMAGE_NAME`: console 镜像名，默认 `ks-console`。
- `vars.APISERVER_IMAGE_NAME`: apiserver 镜像名，默认 `ks-apiserver`。
- `vars.CONTROLLER_IMAGE_NAME`: controller-manager 镜像名，默认 `ks-controller-manager`。
- `secrets.REGISTRY_USERNAME`: 可选。默认使用 `${{ github.actor }}`。
- `secrets.REGISTRY_PASSWORD`: 可选。默认使用 `${{ github.token }}`，适合推送 GHCR。

如果使用 GHCR 并跨仓库拉取 package，需要确认 `archinfra/kubesphere` 的 workflow token 对 `ks-console` package 有读取权限；如果 package 是私有的，可以改用带 `read:packages`/`write:packages` 权限的 PAT 配到 `REGISTRY_PASSWORD`。

## Console 仓库

仓库: `archinfra/kubesphere-console`

Workflow: `Build Console Container Image`

触发方式:

- 推送 `master` 或 `release-*` 分支。
- 推送 `v*` tag。
- 手动 workflow dispatch，输入 `version` 和 `platforms`。

默认多架构平台:

```text
linux/amd64,linux/arm64
```

默认产物:

```text
ghcr.io/<org>/kubesphere-console/ks-console:<version>
```

`v*` tag 构建时额外推送:

```text
ghcr.io/<org>/kubesphere-console/ks-console:latest
```

## Backend 仓库

仓库: `archinfra/kubesphere`

Workflow: `Build Backend Container Images`

这个 workflow 用于分支或手动构建后端镜像，不负责发布 GitHub Release。后端 Dockerfile 已改为在 runner 原生平台上交叉编译，避免 arm64 通过 QEMU 编译 Go 导致构建极慢。

默认产物:

```text
ghcr.io/<org>/kubesphere/ks-apiserver:<version>
ghcr.io/<org>/kubesphere/ks-controller-manager:<version>
```

Workflow: `Release Offline Run Installer`

这个 workflow 在推送 `v*` tag 时自动执行完整发布:

1. 构建并推送 `ks-apiserver` 的 `linux/amd64,linux/arm64` 多架构镜像。
2. 构建并推送 `ks-controller-manager` 的 `linux/amd64,linux/arm64` 多架构镜像。
3. checkout 同 tag 的 console 仓库源码，构建并推送 release 专用 `ks-console` 多架构镜像。
4. 拉取同版本 `ks-console`、后端镜像、`kubectl`、`redis`，分别封装 amd64 和 arm64 离线 `.run`。
5. 将 `.run` 和 `.sha256` 发布到当前 tag 的 GitHub Release。

默认拉取镜像:

```text
ghcr.io/<org>/kubesphere/ks-apiserver:<version>
ghcr.io/<org>/kubesphere/ks-controller-manager:<version>
ghcr.io/<org>/kubesphere/ks-console:<version>
bitnami/kubectl:1.33.1
redis:7.2.7-alpine
```

最终 Release 产物:

```text
ai-k8s-platform-<version>-amd64.run
ai-k8s-platform-<version>-amd64.run.sha256
ai-k8s-platform-<version>-arm64.run
ai-k8s-platform-<version>-arm64.run.sha256
```

## 推荐发布顺序

两个仓库使用同一个 tag，例如 `v0.2.6`:

```bash
# console repo
git tag -a v0.2.6 -m "AI K8s Platform v0.2.6 console"
git push origin v0.2.6

# backend repo
git tag -a v0.2.6 -m "AI K8s Platform v0.2.6"
git push origin v0.2.6
```

Console tag 会触发 console 仓库自己的镜像构建，方便单独验证前端镜像。Backend tag 会触发完整 release workflow，并在后端 workflow 内部 checkout 同 tag 的 console 源码重新构建 release 专用 console 镜像，因此最终 `.run` 不依赖 console 仓库 Action 是否先完成。

## 离线安装

下载目标架构的 `.run` 和 `.sha256` 后:

```bash
sha256sum -c ai-k8s-platform-v0.2.6-amd64.run.sha256
chmod +x ai-k8s-platform-v0.2.6-amd64.run
./ai-k8s-platform-v0.2.6-amd64.run install -y \
  --registry-repo harbor.local/ai-k8s-platform
```

如果目标仓库需要认证:

```bash
./ai-k8s-platform-v0.2.6-amd64.run install -y \
  --registry-repo harbor.local/ai-k8s-platform \
  --registry-username '<user>' \
  --registry-password '<password>'
```

查看状态:

```bash
./ai-k8s-platform-v0.2.6-amd64.run status
```
