# Dokploy 部署队列卡死：故障分析与处理手册

> **适用对象**：运维机器人 / on-call 工程师  
> **平台**：Dokploy v0.26.x（BullMQ 部署队列）  
> **首次记录**：2026-06-16  
> **关联事件**：`bitzoomauth-testauth-atgu3t`（casdoor auth）点击 Deploy 无反应、Deployments 为空

---

## 1. 问题现象（Symptoms）

满足以下 **2 条及以上**，优先怀疑本文档描述的「部署队列卡死」：

| 现象 | 说明 |
|------|------|
| 点击 **Deploy / Redeploy** 后 UI 无明显反馈 | 按钮可点，但长时间无日志、无状态变化 |
| **Deployments 列表为空** | 或只有很久以前的记录，本次操作未产生新记录 |
| 日志页显示 `Error: No such container: select-a-container` | Dokploy 占位符，表示**没有任何容器**可附着 |
| 目标服务器上 **无对应容器** | `docker ps` 查不到项目容器 |
| Redis 队列 `wait` 持续增长 | 有排队任务但长期不被消费 |
| `active` 队列有 1 个任务长期不变 | 典型「单任务卡死阻塞全队」 |

### 易混淆现象（需排除）

| 现象 | 更可能的原因 |
|------|-------------|
| 外网 `HTTP 522` | Cloudflare 源站 IP 错误或源站不可达，与队列卡死无关 |
| Traefik 返回 `404` | 容器未起来或 Traefik 路由未注册 |
| SSH 连远程服务器超时 | 远程服务器宕机/防火墙；会导致部署失败，但不一定队列卡死 |
| 构建日志有明确 OOM / git clone 失败 | 单次部署失败，Deployments 应有 `error` 记录 |

---

## 2. 架构背景

```
开发者 / Git Push
       ↓
Dokploy 面板 (119.12.165.87:3000)
       ↓  BullMQ 队列 (Redis: bull:deployments:*)
Deployment Worker（单 worker 串行消费）
       ↓  SSH + docker compose
远程目标机 (如 121.91.175.132)
       ↓
Traefik (dokploy-network) → 域名 (如 auth.riverwa.com)
```

**关键点**：Dokploy 部署 worker **串行处理** Redis 队列。若 `active` 中有一条**孤儿任务**永不结束，后续所有 Deploy 都会堆在 `wait` 里，表现为「怎么点都没用」。

---

## 3. 根因分析（2026-06-16 实例）

### 3.1 直接原因

Redis 队列 `bull:deployments:active` 中残留 job **#190**：

```json
{
  "applicationId": "hWieAJSwoqBsS4WT54KnP",
  "applicationType": "application",
  "type": "deploy",
  "server": true
}
```

- 类型为 **Application**（非 Compose）
- 对应 Application 记录在 PostgreSQL 中**已被删除**
- Worker 无法继续处理该任务，也永不释放 `active` 槽位
- 后续 11 个 Compose Deploy（`composeId: ghX7oNdRROWOnSz4Wj_fO`）全部积压在 `wait`

### 3.2 触发路径（推测）

1. 早期用 **Application** 类型创建过 casdoor 项目（或误选类型）
2. 部署指向已宕机的 `183.87.44.50`，SSH 握手超时
3. Application 被删除，但 Redis 队列未清理
4. 改用 **Compose** 项目 `bitzoomauth-testauth-atgu3t` 后，新任务无法被消费

### 3.3 次要配置问题（不阻塞队列，但影响上线）

- `composePath` 初值为 `docker-compose.yml`，成功项目多为 `./docker-compose.yml`（已在 DB 中修正）
- Cloudflare 源站未指向 `121.91.175.132`，外网访问 `auth.riverwa.com` 返回 522
- 用户误以为「部署成功」，实际容器从未创建

---

## 4. 诊断流程（运维机器人决策树）

```
开始：用户反馈 Deploy 无反应
  │
  ├─[1] SSH 到 Dokploy 面板机 (119.12.165.87)
  │
  ├─[2] 查 compose/application 是否存在
  │     psql: SELECT "composeId","appName","serverId","composeStatus" FROM compose WHERE "appName" LIKE '%关键词%';
  │     → 不存在：UI 未保存成功或项目名错误，跳转到「新建项目检查」
  │
  ├─[3] 查 deployment 表是否有新记录
  │     psql: SELECT "deploymentId",status,"createdAt" FROM deployment WHERE "composeId"='<id>' ORDER BY "createdAt" DESC LIMIT 5;
  │     → 有 running/done：队列正常，查构建日志
  │     → 完全为空：继续 [4]
  │
  ├─[4] 查 Redis 队列（核心）
  │     LLEN bull:deployments:wait
  │     LLEN bull:deployments:active
  │     LINDEX bull:deployments:active 0   → 记下 active job id
  │     HGET bull:deployments:<id> data
  │     → wait>0 且 active 长期=1 且 data 中 composeId 与当前项目不符
  │        或 applicationId 在 DB 中已不存在 → 判定「队列卡死」
  │
  ├─[5] 验证卡死任务是否为孤儿
  │     若 data 含 applicationId → SELECT * FROM application WHERE "applicationId"='<id>';
  │     → 0 rows = 孤儿 Application 任务
  │
  └─[6] 执行修复流程（第 5 节）
```

---

## 5. 修复步骤

### 5.1 前置

```bash
# Dokploy 面板机
ssh -i ~/.ssh/futures root@119.12.165.87
```

### 5.2 确认卡死任务

```bash
REDIS=$(docker ps -q -f name=dokploy-redis)

echo "wait:  $(docker exec $REDIS redis-cli LLEN bull:deployments:wait)"
echo "active: $(docker exec $REDIS redis-cli LLEN bull:deployments:active)"

ACTIVE_ID=$(docker exec $REDIS redis-cli LINDEX bull:deployments:active 0)
echo "active job: $ACTIVE_ID"

docker exec $REDIS redis-cli HGET "bull:deployments:${ACTIVE_ID}" data
```

### 5.3 清理孤儿 active 任务

> **注意**：仅移除确认 orphaned / 长期卡死的 `active` 任务，勿清空整个队列。

```bash
REDIS=$(docker ps -q -f name=dokploy-redis)
ACTIVE_ID=$(docker exec $REDIS redis-cli LINDEX bull:deployments:active 0)

# 移除 active 槽位中的卡死任务
docker exec $REDIS redis-cli LREM bull:deployments:active 1 "$ACTIVE_ID"
docker exec $REDIS redis-cli DEL "bull:deployments:${ACTIVE_ID}" "bull:deployments:${ACTIVE_ID}:lock"
```

### 5.4 重启 Deployment Worker

```bash
# Swarm 环境（119 面板机）
docker service update --force dokploy

# 或单容器环境
docker restart $(docker ps -q -f name=dokploy.1)
```

### 5.5 验证恢复

等待 15–30 秒后：

```bash
# 队列应开始消费：wait 减少，出现 deployment 记录
PG=$(docker ps -q -f name=dokploy-postgres)
PGPASS=$(docker exec $PG cat /run/secrets/postgres_password)
docker exec -e PGPASSWORD=$PGPASS $PG psql -U dokploy -d dokploy -c \
  "SELECT \"deploymentId\",status,\"createdAt\" FROM deployment ORDER BY \"createdAt\" DESC LIMIT 5;"
```

目标服务器（如 121）应出现：

```bash
ssh -i ~/.ssh/futures root@121.91.175.132
ls /etc/dokploy/compose/<appName>/
tail -f /etc/dokploy/logs/<appName>/<最新日志>.log
docker ps | grep -i auth
```

### 5.6 可选：修正 composePath

若与其他成功项目不一致：

```sql
UPDATE compose
SET "composePath" = './docker-compose.yml'
WHERE "composeId" = '<composeId>';
```

---

## 6. 新建 / 配置 Compose 项目检查清单

避免重复踩坑：

| 检查项 | 正确值（auth 示例） |
|--------|---------------------|
| 项目类型 | **Compose**（不要用 Application 部署带 Dockerfile+compose 的栈） |
| Dokploy 面板 | `119.12.165.87:3000` |
| 目标服务器 | `121.91.175.132`（非面板本机，除非刻意本地部署） |
| 仓库 | `bitzoom-futures/casdoor` |
| 分支 | `dokploy-deploy` |
| composePath | `./docker-compose.yml` |
| 环境变量 | 见仓库 `dokploy.env.example` |
| Auto Deploy | 按需开启 |
| DNS | Cloudflare 源站指向**实际 Traefik 所在机器** |

### 环境变量（auth 必填）

```
ENV=prod
DOMAIN=auth.riverwa.com
ORIGIN=https://auth.riverwa.com
STATIC_BASE_URL=https://www.riverwa.com
DB_NAME=auth
DB_USER=auth_user
DB_PASSWORD=bitZoom@2025_auth
MYSQL_ROOT_PASSWORD=<自定义>
DATA_SOURCE_NAME=auth_user:bitZoom%402025_auth@tcp(mysql:3306)/
```

---

## 7. 运维机器人关键词索引

用于 RAG / 规则匹配：

```
dokploy deploy 没反应
deployments 为空
select-a-container
部署队列卡住
bull:deployments:active
bull:deployments:wait
Application 改 Compose
orphan deployment job
```

**一键判断公式**：

```
IF deployments_empty AND wait_queue > 0 AND active_queue == 1 AND active_job_age > 10min
THEN suspect dokploy_queue_stuck
```

---

## 8. 预防建议

1. **删除 Application 前先 Cancel Deployment**，或手动清理 Redis 队列
2. **统一使用 Compose** 管理多容器栈（mysql + app）
3. 定期巡检（可脚本化）：

```bash
# 加入 cron / 运维巡检
REDIS=$(docker ps -q -f name=dokploy-redis)
WAIT=$(docker exec $REDIS redis-cli LLEN bull:deployments:wait)
ACTIVE=$(docker exec $REDIS redis-cli LLEN bull:deployments:active)
if [ "$WAIT" -gt 5 ] && [ "$ACTIVE" -eq 1 ]; then
  echo "ALERT: Dokploy deploy queue may be stuck (wait=$WAIT active=$ACTIVE)"
fi
```

4. 远程服务器删除前，在 Dokploy **Servers** 页面先标记 inactive
5. 勿在卡死期间反复点击 Deploy，以免 `wait` 堆积

---

## 9. 相关文件

| 文件 | 用途 |
|------|------|
| `docker-compose.yml` | Dokploy Compose 部署定义 |
| `dokploy.env.example` | 环境变量模板 |
| `scripts/dokploy-server-inventory.sh` | 目标机状态巡检 |
| `scripts/dokploy-server-reset.sh` | 测试机清理（保留 Dokploy 核心） |
| `scripts/verify-deploy.sh` | 部署后健康检查 |

---

## 10. 时间线（本次事件）

| 时间 | 事件 |
|------|------|
| 2026-06-16 | 创建 Compose 项目 `bitzoomauth-testauth-atgu3t`，多次 Deploy 无记录 |
| 排查 | 发现 Redis active 卡死 job #190（已删 Application） |
| 处理 | 清理 active 任务 + 重启 dokploy worker |
| 结果 | 队列恢复，`7viCX0aGwKEPfG3HHZhrr` 状态 `running`，121 上开始构建 |
| 后续 | 需等待构建完成 + DNS 指向 121 + 恢复数据库 |

---

## 11. 参考命令速查

```bash
# Dokploy 面板机
ssh -i ~/.ssh/futures root@119.12.165.87

# 列出所有 compose 项目
docker exec -e PGPASSWORD=$(docker exec $(docker ps -q -f name=dokploy-postgres) cat /run/secrets/postgres_password) \
  $(docker ps -q -f name=dokploy-postgres) psql -U dokploy -d dokploy \
  -c "SELECT \"appName\",\"serverId\",\"composeStatus\",\"composePath\" FROM compose;"

# 队列长度
docker exec $(docker ps -q -f name=dokploy-redis) redis-cli LLEN bull:deployments:wait
docker exec $(docker ps -q -f name=dokploy-redis) redis-cli LLEN bull:deployments:active

# 目标机容器
ssh -i ~/.ssh/futures root@121.91.175.132 "docker ps | grep -i auth"
```