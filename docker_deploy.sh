#!/bin/bash
# filepath: deploy.sh

set -e

IMAGE="vincent2025/futures_auth:v0.1.0"
CONTAINER_NAME="futures_auth"
NETWORK="infra-network"
MYSQL_CONTAINER="infra-mysql"

echo "🔍 检查 MySQL 容器..."
if ! docker ps | grep -q $MYSQL_CONTAINER; then
    echo "❌ MySQL 容器 $MYSQL_CONTAINER 未运行"
    exit 1
fi

echo "🔍 检查网络..."
if ! docker network ls | grep -q $NETWORK; then
    echo "❌ 网络 $NETWORK 不存在"
    exit 1
fi

echo "🛑 停止并删除旧容器..."
docker stop $CONTAINER_NAME 2>/dev/null || true
docker rm $CONTAINER_NAME 2>/dev/null || true

echo "📂 创建必要的目录..."
mkdir -p conf logs

echo "🚀 启动新容器..."
docker run -d \
  --name $CONTAINER_NAME \
  --network $NETWORK \
  -p 8000:8000 \
  -v $(pwd)/logs:/logs \
  --restart unless-stopped \
  $IMAGE

echo "⏳ 等待服务启动..."
sleep 5

echo "📊 容器状态："
docker ps | grep $CONTAINER_NAME

echo ""
echo "🔗 网络连接测试："
docker exec $CONTAINER_NAME sh -c "ping -c 2 $MYSQL_CONTAINER" || echo "Ping 不可用，但不影响 TCP 连接"

echo ""
echo "📝 查看日志："
docker logs --tail 50 $CONTAINER_NAME

echo ""
echo "✅ 部署完成！"
echo "🌐 访问: http://localhost:8000"
echo "📊 查看日志: docker logs -f $CONTAINER_NAME"