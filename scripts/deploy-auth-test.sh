#!/bin/bash
# 在 121.91.175.132 测试机部署 auth 的完整流程（本地执行）
set -euo pipefail

SERVER="root@121.91.175.132"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/futures}"
REMOTE_DIR="/opt/futures_auth"
DUMP_LOCAL="${1:-server-backup/auth_dump.sql.gz}"

SSH=(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SERVER")
SCP=(scp -i "$SSH_KEY" -o StrictHostKeyChecking=no)

echo "📋 Step 1: 查看服务器现状"
"${SSH[@]}" 'bash -s' < "$(dirname "$0")/dokploy-server-inventory.sh"

echo ""
read -rsp "是否继续清理测试机? [y/N] " confirm
echo
[[ "${confirm:-}" =~ ^[Yy]$ ]] || { echo "跳过清理"; exit 0; }

echo ""
echo "🧹 Step 2: 清理测试机"
"${SSH[@]}" 'bash -s' < "$(dirname "$0")/dokploy-server-reset.sh"

if [ -f "$DUMP_LOCAL" ]; then
  echo ""
  echo "📦 Step 3: 上传数据库备份"
  "${SCP[@]}" "$DUMP_LOCAL" "$SERVER:/tmp/auth_dump.sql.gz"
  echo "   上传完成: /tmp/auth_dump.sql.gz"
  echo "   Deploy 完成后在服务器执行:"
  echo "   ENV=prod DB_PASSWORD='bitZoom@2025_auth' gunzip -c /tmp/auth_dump.sql.gz | docker exec -i futures_auth-mysql-prod mysql -uauth_user -p'bitZoom@2025_auth' auth"
else
  echo ""
  echo "⚠️  未找到 $DUMP_LOCAL，跳过备份上传"
fi

echo ""
echo "✅ 本地脚本执行完毕"
echo ""
echo "请在 Dokploy 控制台完成："
echo "  1. 新建 Compose 项目 futures_auth"
echo "  2. 仓库 bitzoom-futures/casdoor，分支 dokploy-deploy"
echo "  3. 服务器选 183.87.44.50"
echo "  4. 环境变量:"
echo "       ENV=prod"
echo "       DOMAIN=auth.riverwa.com"
echo "       ORIGIN=https://auth.riverwa.com"
echo "       DB_USER=auth_user"
echo "       DB_PASSWORD=bitZoom@2025_auth"
echo "       MYSQL_ROOT_PASSWORD=<新密码>"
echo "  5. Deploy → 恢复数据库 → docker restart futures_auth-prod"
echo "  6. DNS: auth.riverwa.com → 183.87.44.50"