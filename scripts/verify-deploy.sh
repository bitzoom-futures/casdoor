#!/bin/bash
# 验证新环境 auth.riverwa.com 是否就绪
set -euo pipefail

DOMAIN="${DOMAIN:-auth.riverwa.com}"
ENV="${ENV:-prod}"

echo "🔍 检查 DNS: $DOMAIN"
RESOLVED_IP="$(dig +short "$DOMAIN" | tail -1)"
if [ -z "$RESOLVED_IP" ]; then
  echo "❌ DNS 未解析，请先将 $DOMAIN 指向新 Dokploy 服务器 IP"
  exit 1
fi
echo "   → $RESOLVED_IP"

echo "🔍 检查 HTTPS 健康接口"
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN}/api/health" || true)"
if [ "$HTTP_CODE" != "200" ]; then
  echo "❌ https://${DOMAIN}/api/health 返回 $HTTP_CODE"
  exit 1
fi
echo "   → 200 OK"

if docker ps --format '{{.Names}}' | grep -qx "futures_auth-${ENV}"; then
  echo "🔍 检查容器 futures_auth-${ENV}"
  docker exec "futures_auth-${ENV}" curl -sf http://localhost:8000/api/health >/dev/null
  echo "   → 容器健康"
fi

echo ""
echo "✅ 新服务就绪: https://${DOMAIN}"
echo "   确认无误后，可停止旧服务器上的 futures_auth 容器"