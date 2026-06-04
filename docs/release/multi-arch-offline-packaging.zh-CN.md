# AMD64 / ARM64 离线包构建说明

本项目的离线包必须按架构分别生成：

- `ai-k8s-platform-<version>-amd64.run`：仅包含 `linux/amd64` 镜像。
- `ai-k8s-platform-<version>-arm64.run`：仅包含 `linux/arm64` 镜像。

不要把多架构 manifest 直接 `docker save` 成离线包。离线包里每个镜像 tar 都必须是单架构镜像。

## 从源码和 Console 目录本地构建

```bash
# 构建两个架构包
hack/release/build-offline-run.sh \
  --version v0.1.0 \
  --arch all \
  --console-dir ../console

# 只构建 amd64
hack/release/build-offline-run.sh \
  --version v0.1.0 \
  --arch amd64 \
  --console-dir ../console

# 只构建 arm64
hack/release/build-offline-run.sh \
  --version v0.1.0 \
  --arch arm64 \
  --console-dir ../console
```

构建完成后验证：

```bash
hack/release/verify-offline-run-arch.sh dist/ai-k8s-platform-v0.1.0-amd64.run amd64
hack/release/verify-offline-run-arch.sh dist/ai-k8s-platform-v0.1.0-arm64.run arm64
```

## 从已经发布的镜像生成离线包

这个模式适合 GitHub Actions 或已有镜像仓库的情况：

```bash
hack/release/package-offline-run-from-images.sh \
  --version v0.1.0 \
  --arch arm64 \
  --apiserver-image ghcr.io/archinfra/kubesphere/ks-apiserver:v0.1.0 \
  --controller-image ghcr.io/archinfra/kubesphere/ks-controller-manager:v0.1.0 \
  --console-image ghcr.io/archinfra/kubesphere/ks-console:v0.1.0 \
  --kubectl-image kubesphere/kubectl:v1.33.1 \
  --redis-image redis:7.2.7-alpine
```

脚本会使用 `docker pull --platform linux/<arch>` 拉取镜像，并在保存前用 `docker image inspect` 校验镜像平台。

## 关键约束

1. ARM 包必须使用 `linux/arm64` 二进制路径：`_output/local/bin/linux/arm64/...`。
2. AMD 包必须使用 `linux/amd64` 二进制路径：`_output/local/bin/linux/amd64/...`。
3. 不允许从 `_output/bin/...` 复制后端二进制，因为该路径通常指向宿主机架构，容易把 amd64 混入 arm64 包。
4. 不允许复用本地已有的 `kubectl`、`redis` 等镜像，必须按目标平台重新 `docker pull --platform`。
5. `NODE_HOME` 只作为宿主机构建 Console 的工具链，不再自动复制到 Console 运行镜像。ARM 镜像如果复制 x64 Node.js，会生成错误包。
