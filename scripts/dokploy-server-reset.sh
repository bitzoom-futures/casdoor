#!/bin/bash
# 测试机全量清理（保留 Dokploy + Traefik 核心）
# 用法: ssh -i ~/.ssh/futures root@121.91.175.132 'bash -s' < scripts/dokploy-server-reset.sh
set -euo pipefail

KEEP_REGEX='dokploy|traefik'

echo "⚠️  测试机清理：删除除 Dokploy/Traefik 外的所有容器、卷、构建缓存"
echo "    保留匹配: $KEEP_REGEX"
read -rsp "确认继续? [y/N] " confirm
echo
[[ "${confirm:-}" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }

echo ""
echo "========== 清理前状态 =========="
docker ps -a --format 'table {{.Names}}\t{{.Status}}'
docker volume ls

echo ""
echo "🛑 停止非核心容器..."
mapfile -t TO_STOP < <(docker ps -q --filter "status=running")
for id in "${TO_STOP[@]}"; do
  name="$(docker inspect -f '{{.Name}}' "$id" | sed 's#^/##')"
  if echo "$name" | grep -qiE "$KEEP_REGEX"; then
    echo "  保留运行: $name"
    continue
  fi
  echo "  停止: $name"
  docker stop "$id" >/dev/null
done

echo ""
echo "🗑️  删除非核心容器..."
mapfile -t ALL < <(docker ps -aq)
for id in "${ALL[@]}"; do
  name="$(docker inspect -f '{{.Name}}' "$id" | sed 's/^.//')"
  if echo "$name" | grep -qiE "$KEEP_REGEX"; then
    echo "  保留: $name"
    continue
  fi
  echo "  删除: $name"
  docker rm -f "$id" >/dev/null 2>&1 || true
done

echo ""
echo "🗑️  删除 compose 项目卷（futures_auth / 其他业务卷）..."
mapfile -t VOLS < <(docker volume ls -q)
for vol in "${VOLS[@]}"; do
  if echo "$vol" | grep -qiE 'dokploy|traefik'; then
    echo "  保留卷: $vol"
    continue
  fi
  echo "  删除卷: $vol"
  docker volume rm "$vol" >/dev/null 2>&1 || true
done

echo ""
echo "🧹 清理悬空镜像与构建缓存..."
docker image prune -af >/dev/null
docker builder prune -af >/dev/null 2>&1 || true

echo ""
echo "========== 清理后状态 =========="
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker network ls
docker volume ls
docker system df

echo ""
echo "✅ 清理完成。下一步在 Dokploy 新建 futures_auth Compose 项目并 Deploy。"