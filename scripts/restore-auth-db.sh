#!/bin/bash
# 一次性恢复 auth 数据库（从 server-backup/auth_dump.sql.gz）
# 用法: ./scripts/restore-auth-db.sh [sql.gz路径] [mysql容器名]
set -euo pipefail

DUMP_FILE="${1:-server-backup/auth_dump.sql.gz}"
ENV="${ENV:-prod}"
MYSQL_CONTAINER="${2:-futures_auth-mysql-${ENV}}"
DB_NAME="${DB_NAME:-auth}"
DB_USER="${DB_USER:-auth_user}"
DB_PASSWORD="${DB_PASSWORD:-}"

if [ ! -f "$DUMP_FILE" ]; then
  echo "❌ 备份文件不存在: $DUMP_FILE"
  echo "   请将 server-backup/auth_dump.sql.gz 放到项目根目录"
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$MYSQL_CONTAINER"; then
  echo "❌ MySQL 容器 $MYSQL_CONTAINER 未运行"
  echo "   请先部署 docker-compose.yml，或指定正确容器名"
  exit 1
fi

if [ -z "$DB_PASSWORD" ]; then
  read -rsp "请输入 $DB_USER 的 MySQL 密码: " DB_PASSWORD
  echo
fi

echo "📦 恢复数据库 $DB_NAME 到 $MYSQL_CONTAINER ..."
gunzip -c "$DUMP_FILE" | docker exec -i "$MYSQL_CONTAINER" \
  mysql -u"$DB_USER" -p"$DB_PASSWORD" "$DB_NAME"

echo "✅ 恢复完成"