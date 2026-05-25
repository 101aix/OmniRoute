# OmniRoute Deployment Guide

## 架构概览

```
101aix/OmniRoute (GitHub) → GitHub Actions → Harbor (镜像)
                                        ↓
                          ArgoCD ApplicationSet → Application → K8s (omniroute-01-prod)
                                        ↓
                          KubeBlocks (Redis 3副本+3哨兵) + SQLite (PVC)
```

OmniRoute 使用 SQLite 作为主数据库（单写入者），因此 deployment 为单副本 + Recreate 策略，不支持水平扩展。

## 前置条件

### GitHub Actions 环境

CI 使用 GitHub 托管 runner (`ubuntu-latest`)，不依赖集群内自托管 runner。

**必须配置的 GitHub 仓库变量和密钥：**

| 类型 | 名称 | 说明 | 设置路径 |
|------|------|------|----------|
| Variable | `HARBOR_USERNAME` | Harbor 推送用户名 | Settings → Secrets and variables → Actions → Variables |
| Secret | `HARBOR_PASSWORD` | Harbor 推送密码 | Settings → Secrets and variables → Actions → Secrets |

### 集群内 Secrets

在目标 namespace 创建 Harbor 拉取凭据：

```bash
kubectl create secret docker-registry harbor-prod-pull \
  -n omniroute-01-prod \
  --docker-server=harbor.lke591431.akamai-apl.net \
  --docker-username=<pull-username> \
  --docker-password=<pull-password>
```

## 资源清单

### 应用层 (omniroute-01-prod namespace)

| 资源 | 名称 | 说明 |
|------|------|------|
| Deployment | omniroute-01 | 单副本，Recreate 策略（SQLite 限制） |
| PVC | omniroute-01-data | 10Gi，linode-block-storage-retain |
| Ingress | omniroute-01 | Higress，域名 omniroute.101aix.net |
| Service | omniroute-01 | ClusterIP，端口 20128 |
| ConfigMap | omniroute-01-env | 环境变量 |
| Secret | omniroute-01 | JWT Secret、API Key Secret、初始密码 |

> 无 HPA/VPA/PDB — SQLite 不支持多写入者，单副本不可水平扩展。

### 数据库层 (KubeBlocks Cluster，不受 ArgoCD 管理)

| 资源 | 名称 | 规格 |
|------|------|------|
| Redis | omniroute-01-redis | 7.2.10, 3副本 + 3哨兵, 1Gi/副本 |

Redis 用于限流（rate limiting），不存储业务数据。业务数据存储在 PVC 挂载的 SQLite 中。

### 备份策略

| 组件 | 方式 | 频率 | 保留 |
|------|------|------|------|
| SQLite | PVC 持久化 + Linode Block Storage 底层快照 | 依赖存储层 | — |
| Redis | datafile | 每周日 18:00 | 7天 |

> SQLite 文件由 PVC linode-block-storage-retain 保护。PVC 删除时保留底层 Volume，需手动清理。

## Git 仓库结构

```
omniroute/
├── helm/                          # Helm Chart（应用层资源）
│   ├── Chart.yaml
│   ├── values.yaml                # 默认值
│   ├── templates/
│   │   ├── _helpers.tpl
│   │   ├── deployment.yaml
│   │   ├── pvc.yaml
│   │   ├── configmap.yaml
│   │   ├── secret.yaml
│   │   ├── service.yaml
│   │   └── ingress.yaml
│   └── ...
├── instances/
│   └── omniroute/
│       ├── instance.yaml          # ApplicationSet 元数据（必须）
│       └── values.yaml            # 生产环境配置覆盖
├── kubeblocks/
│   └── redis-cluster.yaml         # KubeBlocks Redis Cluster
├── Dockerfile                     # CI 构建用（root）
├── docker-compose.yml
└── .github/
    └── workflows/
        ├── harbor-image.yml       # Harbor 镜像构建推送
        └── ...
```

## ArgoCD 接入

### ApplicationSet

```yaml
位置: argocd namespace
名称: omniroute-instances
仓库: git@github.com:101aix/OmniRoute.git (main 分支)
生成器: git file → instances/omniroute*/instance.yaml
同步策略: automated, prune, selfHeal, CreateNamespace=true
```

### instance.yaml（ApplicationSet 生成器元数据）

```yaml
name: omniroute-01
namespace: omniroute-01-prod
releaseName: omniroute-01
valuesFile: instances/omniroute/values.yaml
```

ApplicationSet 自动扫描 `instances/omniroute*/instance.yaml`，每发现一个文件就生成一个 Application。

### 生成的 Application

```
名称: omniroute-01
Chart: helm/
Values: instances/omniroute/values.yaml
目标: omniroute-01-prod namespace
```

### ArgoCD 同步行为

- **selfHeal**: 集群内手动修改会被自动回滚
- **prune**: Git 中删除的资源会在集群中自动删除
- **自动同步**: Git push 后 ArgoCD 约 3 分钟内自动触发 sync

## 完整部署步骤

### 第一步：准备 Git 仓库

确保仓库结构完整：
```bash
git clone git@github.com:101aix/OmniRoute.git
cd OmniRoute

# 检查关键文件
ls helm/Chart.yaml
ls instances/omniroute/instance.yaml    # ApplicationSet 生成器需要此文件
ls instances/omniroute/values.yaml
ls kubeblocks/redis-cluster.yaml
ls Dockerfile
```

### 第二步：配置 GitHub Actions 凭据

在 GitHub 仓库页面 Settings → Secrets and variables → Actions：

1. 添加 **Repository Variable** `HARBOR_USERNAME`（Harbor 推送用户名）
2. 添加 **Repository Secret** `HARBOR_PASSWORD`（Harbor 推送密码）

推送代码到 main 分支触发 CI：
```bash
git push origin main
```

验证 CI 通过：GitHub → Actions → "Publish image to 101aix Harbor" → 构建成功。

### 第三步：创建 KubeBlocks Redis 集群

**注意：KubeBlocks Cluster 不在 Helm chart 内，需手动创建，且不受 ArgoCD 管理（terminationPolicy: DoNotTerminate）。**

```bash
# 创建 Redis 3副本+3哨兵集群
kubectl apply -f kubeblocks/redis-cluster.yaml

# 等待集群 Running
kubectl get cluster -n omniroute-01-prod -w
```

### 第四步：配置 ArgoCD ApplicationSet

在 ArgoCD namespace 创建 ApplicationSet（如集群中尚未存在）：

```bash
kubectl apply -f appsets/omniroute-instances.yaml
```

ArgoCD 检测到 `instance.yaml` 后自动生成 Application 并开始同步。由于 CI 会在 main 分支推送时自动更新 `instances/omniroute/values.yaml` 中的 image tag，首次部署需要先完成第二步（CI 构建镜像）。

### 第五步：验证部署

```bash
# 1. ArgoCD 同步状态
kubectl get application -n argocd omniroute-01

# 2. Pod 运行状态
kubectl get pods -n omniroute-01-prod

# 3. PVC 状态
kubectl get pvc -n omniroute-01-prod

# 4. KubeBlocks 集群状态
kubectl get cluster -n omniroute-01-prod

# 5. Ingress 和 TLS
kubectl get ingress,certificate -n omniroute-01-prod

# 6. 健康检查
kubectl exec -n omniroute-01-prod deployment/omniroute-01 -- \
  node -e "fetch('http://localhost:20128/api/monitoring/health').then(r=>r.json()).then(d=>console.log(JSON.stringify(d,null,2)))"
```

### 第六步：DNS 配置

在 DNS 控制台添加 A 记录：

| 域名 | 类型 | 指向 |
|------|------|------|
| omniroute.101aix.net | A | Higress Gateway 公网 IP (172.233.134.11) |

DNS 生效后 cert-manager 自动通过 HTTP-01 挑战签发 Let's Encrypt 证书。**DNS 未解析时 TLS 证书无法签发，这是最常见的阻塞点。**

## 新增实例

### 1. 创建实例目录

```bash
mkdir -p instances/omniroute-02
```

### 2. 创建 instance.yaml

```yaml
# instances/omniroute-02/instance.yaml
name: omniroute-02
namespace: omniroute-02-prod
releaseName: omniroute-02
valuesFile: instances/omniroute-02/values.yaml
```

### 3. 创建 values.yaml

参考 `instances/omniroute/values.yaml`，关键修改：
- `fullnameOverride: omniroute-02`
- `namespace.name: omniroute-02-prod`
- `namespace.labels.tenant: omniroute-02`
- `podLabels.tenant: omniroute-02`
- Ingress host 改为 `omniroute-02.101aix.net`
- TLS secretName 改为 `omniroute-02-tls`
- `app.redisUrl` 指向新的 Redis 服务
- 密码重新生成（`openssl rand -base64 48` 等）

### 4. 创建 KubeBlocks Redis 集群

```bash
cp kubeblocks/redis-cluster.yaml kubeblocks/redis-cluster-02.yaml
# 修改 metadata.name 和 metadata.namespace
# 编辑 Redis 密码

kubectl apply -f kubeblocks/redis-cluster-02.yaml
```

### 5. Git push → ArgoCD 自动创建

```bash
git add instances/omniroute-02/
git commit -m "add omniroute-02 instance"
git push origin main
```

ApplicationSet 自动检测到新的 `instance.yaml`，生成 Application，ArgoCD 创建 namespace 和全部应用资源。

## 日常运维

### 更新应用

```bash
# 1. 修改代码
# 2. 推送 → CI 构建新镜像 → Harbor → 自动更新 values.yaml 中的 image.tag
git push origin main

# 3. ArgoCD 检测到 values.yaml 变化 → 自动同步
```

更新策略：Recreate（先删除旧 Pod，再创建新 Pod），会有短暂停机。

### 查看日志

```bash
kubectl logs -n omniroute-01-prod deployment/omniroute-01 --tail=100 -f
```

### SQLite 数据备份

```bash
# 直接复制 PVC 中的 SQLite 文件
kubectl exec -n omniroute-01-prod deployment/omniroute-01 -- \
  cp /app/data/storage.sqlite /tmp/backup-$(date +%Y%m%d).sqlite
kubectl cp omniroute-01-prod/<pod-name>:tmp/backup-*.sqlite ./backup.sqlite
```

## 故障处理

### Pod CrashLoopBackOff

```bash
# 查看日志
kubectl logs -n omniroute-01-prod <pod-name> --previous

# 最常见原因：
# 1. SQLite 文件损坏 → 检查 PVC 挂载状态
# 2. Redis 连接失败 → 检查 Redis URL 和密码
# 3. 端口冲突 → 检查 containerPort 和服务端口一致性
```

### Redis 连接失败

OmniRoute 依赖 Redis 做限流，Redis 不可用时限流功能失效但不影响核心路由。

```bash
# 检查 Redis 集群状态
kubectl get cluster -n omniroute-01-prod omniroute-01-redis

# 测试 Redis 连接
kubectl exec -n omniroute-01-prod omniroute-01-redis-redis-0 -- \
  redis-cli -a <password> ping
```

### Redis 哨兵状态

```bash
kubectl exec -n omniroute-01-prod omniroute-01-redis-redis-sentinel-0 -- \
  redis-cli -p 26379 sentinel masters
```

### Harbor CI 构建失败

```bash
# 检查 GitHub Actions 日志
gh run list --repo 101aix/OmniRoute --workflow harbor-image.yml --limit 5
gh run view <run-id> --repo 101aix/OmniRoute

# 常见原因：
# 1. HARBOR_USERNAME / HARBOR_PASSWORD 未配置 → Settings → Secrets and variables → Actions
# 2. .dockerignore 排除了构建需要的文件（如 docs screenshots、diagrams SVG）
# 3. Harbor 不可达 → 检查网络
```

### ArgoCD OutOfSync

```bash
# 查看差异
kubectl get application -n argocd omniroute-01 -o yaml

# 查看 Git 中的版本
kubectl get application -n argocd omniroute-01 -o jsonpath='{.status.sync.revision}'
```

### PVC 数据恢复

```bash
# PVC 使用 retain 策略，删除 PVC 不会删除底层 Volume
# 恢复步骤：
# 1. 找到旧的 PV
kubectl get pv | grep omniroute-01
# 2. 创建指向旧 PV 的新 PVC
# 3. 重新部署 Pod
```

## 关键设计决策

| 决策 | 原因 |
|------|------|
| 单副本 + Recreate | SQLite 不支持多写入者，多副本会导致数据损坏 |
| 无 HPA/VPA | 单副本无法水平扩展 |
| 无 PDB | 单副本下没有最小可用数概念 |
| topologySpread soft (ScheduleAnyway) | 优先分散 Pod，但不阻塞调度 |
| KubeBlocks + DoNotTerminate | 数据库生命周期独立于应用，避免 ArgoCD 误删 |
| Redis 3副本 + 3哨兵 | 哨兵 quorum 投票防脑裂 |
| PVC retain 策略 | 防止误删导致 SQLite 数据丢失 |
| CI 用 ubuntu-latest 不用自托管 runner | 避免 ARC runner 仓库白名单限制 |
| Harbor 凭据用 repo-level vars/secrets | 明确归属，不依赖 org-level（需 org admin） |
| CI 自动更新 values.yaml | 每次构建后自动更新 image tag，ArgoCD 自动同步 |
| SQLite 而非 PostgreSQL | OmniRoute 上游设计选择，保持与本机运行模式一致 |
| Redis 仅用于限流 | 不存储业务数据，Redis 故障不丢数据 |
| strategy: Recreate | SQLite 仅允许单写入者，RollingUpdate 会导致双 Pod 同时运行 |

## 系统登录信息

### 管理后台

| 项目 | 值 |
|------|-----|
| 地址 | [https://omniroute.101aix.net](https://omniroute.101aix.net) |
| 初始密码 | `7o8MVrolA0gIhAaU` |

> 首次登录后在 Dashboard Settings 中修改密码并创建 API Key。

### 数据库凭据

| 项目 | 值 |
|------|-----|
| SQLite 文件 | `/app/data/storage.sqlite`（PVC 持久化） |
| Redis 密码 | `omnirouteRedisProd2024SecureKey!` |
| Redis 服务地址 | `omniroute-01-redis-redis-redis:6379` |
| JWT Secret | `ipAn3DatSZSpAFG1TvRyy2+HE/QvTIt562b3SUHFNx2R8kvMLJImvcceVH1HtbHv` |
| API Key Secret | `69c1134369a98622b3153ffee2cf31688ebac4082da30e692d2b8ab1ee61c1da` |

### 集群 API 访问

```bash
# 健康检查（无需认证）
curl -s https://omniroute.101aix.net/api/monitoring/health

# API 调用（需要 API Key）
# 在 Dashboard → Settings 中创建 API Key 后使用
curl -s https://omniroute.101aix.net/v1/chat/completions \
  -H "Authorization: Bearer <api-key>" \
  -H "Content-Type: application/json" \
  -d '{"model":"openai/gpt-4o","messages":[{"role":"user","content":"hello"}]}'
```

## 注意事项

1. **密码在 Git 中**: instances/values.yaml 包含明文密码，仓库必须保持私有
2. **单副本限制**: SQLite 不支持多写入者，不可水平扩展
3. **Recreate 更新**: 更新应用时有短暂停机（通常 <30s）
4. **KubeBlocks 独立管理**: Cluster 资源不受 ArgoCD 管理，手动创建后不会自动同步更新
5. **terminationPolicy: DoNotTerminate**: 删除 Cluster YAML 不会删除实际资源，防止误操作
6. **DNS 是最大故障点**: 域名未解析时 TLS 证书无法签发，新实例上线前必须确认 DNS 已配置
7. **Harbor 拉取凭据**: 每个新 namespace 需要手动创建 `harbor-prod-pull` Secret
8. **ApplicationSet 依赖 instance.yaml**: 没有此文件 ApplicationSet 不会生成 Application
9. **PVC retain 策略**: 删除 PVC 不会删除数据，但需手动处理旧 PV
10. **SQLite 备份**: 没有自动备份策略，需定期手动备份或依赖 Linode Volume 快照

## 维护参考信息

### 管理控制台

| 控制台 | 地址 | 说明 |
|--------|------|------|
| Linode | [https://cloud.linode.com/linodes](https://cloud.linode.com/linodes) | ⚠️ **高危** — 可销毁/重建节点，非必要勿操作 |
| K8s (Akamai) | [https://console.lke591431.akamai-apl.net/](https://console.lke591431.akamai-apl.net/) | 集群管理控制台，下载 kubeconfig |
| ArgoCD | [https://argocd.lke591431.akamai-apl.net/applications](https://argocd.lke591431.akamai-apl.net/applications) | 应用同步状态查看、手动 sync/rollback |
| Harbor | [https://harbor.lke591431.akamai-apl.net/harbor/projects](https://harbor.lke591431.akamai-apl.net/harbor/projects) | 镜像仓库，查看镜像 tag 和扫描结果 |

### 统一账号

| 项目 | 值 |
|------|-----|
| 用户名 | `quan@101aix.com` |
| 密码 | `sRAsfkjQMR3x.` |

以上账号用于 Linode、K8s 控制台、ArgoCD、Harbor 登录。

### ⚠️ Linode 高危操作警告

Linode 管理台可执行以下不可逆操作，**务必确认后再点击**：
- **Delete Linode** — 删除节点，上面的所有数据丢失
- **Rebuild Linode** — 重装系统，数据全部清空
- **Delete Volume** — 删除持久化存储卷
- **Delete NodeBalancer** — 删除负载均衡器，所有域名解析失效

日常运维通过 kubectl + ArgoCD 完成即可，不要直接在 Linode 控制台操作节点。

### 相关 Git 仓库

| 仓库 | 地址 | 说明 |
|------|------|------|
| OmniRoute | [https://github.com/101aix/OmniRoute](https://github.com/101aix/OmniRoute) | 本项目 — Helm chart + 实例配置 + KubeBlocks YAML |
| sub2api | [https://github.com/101aix/sub2api](https://github.com/101aix/sub2api) | 参考实现 — 同模式部署的 API 管理平台 |
| gitops | [https://github.com/101aix/gitops](https://github.com/101aix/gitops) | 中心化 GitOps 仓库（newapi、api、kwai 等实例） |
| new-api-101 | [https://github.com/101aix/new-api-101](https://github.com/101aix/new-api-101) | new-api 二开项目，HPA/VPA/KubeBlocks 参考实现 |

OmniRoute 和 sub2api 都使用自包含 GitOps 模式（Helm chart + instances + KubeBlocks 在同一仓库）。gitops 仓库是旧的集中式模式，目前仅维护存量实例。

### 集群连接

```bash
# 从 Akamai 控制台下载 kubeconfig 后
export KUBECONFIG=~/path/to/kubeconfig.yaml

# 验证连接
kubectl cluster-info
kubectl get nodes
```

### 重要 IP

| 资源 | IP | 说明 |
|------|-----|------|
| Higress Gateway (NodeBalancer) | 172.233.134.11 | 所有 Ingress 流量的入口，DNS A 记录指向此 IP |
| 另一个 NodeBalancer | 172.233.134.23 | 其他服务入口 |

> Linode NodeBalancer IP 是静态的，Worker 节点 IP 是动态的（172.x.x.x 范围），**DNS 必须指向 NodeBalancer IP 而非节点 IP**。
