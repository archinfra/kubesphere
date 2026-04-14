# KubeSphere 离线 `.run` 发版说明

## 推荐 tag 流程

后端 `kubesphere` 的离线包依赖同版本 `kubesphere-console`，所以发布 tag 时必须保证前后端同 tag。

推荐使用仓库内脚本：

```bash
hack/release/tag-frontend-backend.sh --version v0.1.6 --console-dir ../kubesphere-console --push
```

脚本会做三件事：

- 检查 `kubesphere-console` 和 `kubesphere` 两个工作区是否干净
- 在两个仓库创建同名 tag
- 使用 `--push` 时先推 console tag，再推 backend tag

之所以先推 console，是因为 backend 的 `build-offline-installer.yml` 会 checkout 同名 console tag，并基于这个版本构建 `ks-console` 镜像。

## 安装现场依赖

`.run` 安装现场不要求有 `jq`。

构建阶段仍然可以使用 `jq` 生成镜像清单；安装阶段只读取 payload 里的 `images/image-index.tsv`，避免客户环境因为缺少 `jq` 而中断。

安装现场仍需要：

- `kubectl`
- `helm`
- `tar`
- `docker`，除非显式传 `--skip-image-prepare`

## 镜像索引格式

`images/image-index.tsv` 每行 4 列，使用 tab 分隔：

```text
tar_name    load_ref    target_ref    platform
```

安装脚本会逐行执行：

- `docker load -i images/<tar_name>`
- `docker tag <load_ref> <registry-repo>/<image-name>:<tag>`
- `docker push <registry-repo>/<image-name>:<tag>`

如果某一行缺少 `load_ref` 或 `target_ref`，安装脚本会明确报错，而不是静默退出。

## 默认随包镜像

离线包默认包含 5 类镜像：

- `ks-apiserver`：后端 API 服务
- `ks-controller-manager`：控制器服务，同时携带 `ks-core` chart
- `ks-console`：由同版本 `kubesphere-console` tag 构建出的前端服务
- `kubectl`：用于 `helmExecutor`、`nodeShell`、`ksCRDs` 等 chart hook/job 场景
- `redis`：用于 HA 模式下的内置缓存；如果配置了外部 `ha.cache`，则不会部署内置 Redis

GitHub Action tag 构建默认使用：

```text
kubectl: kubesphere/kubectl:v1.33.1
redis: redis:7.2.7-alpine
```

手动触发 Action 时可以通过 `kubectl_image` 和 `redis_image` 覆盖来源镜像；本地构建可通过脚本参数或环境变量覆盖。
