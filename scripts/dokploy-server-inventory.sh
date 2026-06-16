#!/bin/bash
# 查看 Dokploy 远程主机当前状态
set -euo pipefail

echo "========== 主机信息 =========="
hostname
uptime
df -h / | tail -1

echo ""
echo "========== 运行中容器 =========="
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

echo ""
echo "========== 所有容器 =========="
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

echo ""
echo "========== 网络 =========="
docker network ls

echo ""
echo "========== 数据卷 =========="
docker volume ls

echo ""
echo "========== 镜像（按大小） =========="
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}' | head -30

echo ""
echo "========== 磁盘占用 =========="
docker system df