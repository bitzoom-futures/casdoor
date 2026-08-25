#!/bin/bash

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
docker rm -f $CONTAINER_NAME 2>/dev/null || true

echo "📂 创建必要的目录..."
mkdir -p conf logs

echo "📝 创建正确的配置文件..."
cat > conf/app.conf << 'EOF'
appname = futures_auth
httpport = 8000
runmode = dev
copyrequestbody = true
driverName = mysql
dataSourceName = auth_user:bitZoom@2025_auth@tcp(infra-mysql:3306)/auth?charset=utf8mb4&parseTime=True&loc=Local/
dbName = auth
tableNamePrefix =
showSql = false
redisEndpoint =
defaultStorageProvider =
isCloudIntranet = false
authState = "auth"
socks5Proxy = "127.0.0.1:10808"
verificationCodeTimeout = 10
initScore = 0
logPostOnly = true
isUsernameLowered = false
origin =
originFrontend =
# staticBaseUrl 默认不生效：静态资源前缀跟随页面请求的域名，与页面同源。
# 仅当 staticBaseUrlMode = config 时才回退到下面的值（如需切回外部 CDN）。
staticBaseUrl = "https://auth1.riverwa.com"
staticBaseUrlMode =
isDemoMode = false
batchSize = 100
enableErrorMask = false
enableGzip = true
inactiveTimeoutMinutes =
ldapServerPort = 389
ldapsCertId = ""
ldapsServerPort = 636
radiusServerPort = 1812
radiusDefaultOrganization = "built-in"
radiusSecret = "secret"
quota = {"organization": -1, "user": -1, "application": -1, "provider": -1}
logConfig = {"adapter":"file", "filename": "logs/casdoor.log", "maxdays":10, "perm":"0770"}
initDataNewOnly = false
initDataFile = "./init_data.json"
frontendBaseDir = "../cc_0"
EOF

echo "✅ 配置文件已创建:"
grep "dataSourceName" conf/app.conf

echo ""
echo "🚀 启动新容器..."
docker run -d \
  --name $CONTAINER_NAME \
  --network $NETWORK \
  -p 8000:8000 \
  -v $(pwd)/conf/app.conf:/conf/app.conf:ro \
  -v $(pwd)/logs:/logs \
  --restart unless-stopped \
  $IMAGE

echo "⏳ 等待服务启动..."
sleep 10

echo "📊 容器状态："
docker ps | grep $CONTAINER_NAME || docker ps -a | grep $CONTAINER_NAME

echo ""
echo "🔍 验证容器内配置:"
docker exec $CONTAINER_NAME cat /conf/app.conf | grep dataSourceName || echo "无法读取配置文件"

echo ""
echo "📝 查看日志："
docker logs --tail 100 $CONTAINER_NAME

echo ""
if docker ps | grep -q $CONTAINER_NAME; then
    echo "✅ 部署成功！"
    echo "🌐 访问: http://localhost:8000"
    echo "📊 实时日志: docker logs -f $CONTAINER_NAME"
else
    echo "❌ 容器启动失败，请检查日志"
    echo "📊 查看完整日志: docker logs $CONTAINER_NAME"
fi
                   