#!/bin/bash
# HoloBackend 构建并推送 Docker 镜像到阿里云 ACR
# 用法: ./build-and-push.sh [时间戳]
# 示例: ./build-and-push.sh              # 自动生成时间戳
#        ./build-and-push.sh 20260527-120000  # 使用指定时间戳

set -euo pipefail

# 配置
REGISTRY="crpi-80bfuvdry686vlon.cn-shenzhen.personal.cr.aliyuncs.com"
REPOSITORY="tang99/holo"
IMAGE_NAME="${REGISTRY}/${REPOSITORY}"

# 时间戳作为版本号
if [ -n "${1:-}" ]; then
    TIMESTAMP="$1"
else
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
fi

TAG="${IMAGE_NAME}:${TIMESTAMP}"
LATEST_TAG="${IMAGE_NAME}:latest"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=========================================="
echo " HoloBackend 镜像构建 & 推送"
echo "=========================================="
echo " 镜像: ${TAG}"
echo " 项目: ${PROJECT_DIR}"
echo "=========================================="

# 检查 Docker 是否可用
if ! command -v docker &>/dev/null; then
    echo "错误: docker 命令未找到，请先安装 Docker"
    exit 1
fi

# 检查 Colima 是否运行（macOS 本地开发）
if [[ "$(uname)" == "Darwin" ]]; then
    if ! docker info &>/dev/null; then
        echo "启动 Colima..."
        colima start
    fi
fi

# 检查是否已登录 ACR
echo ""
echo "[1/4] 检查 ACR 登录状态..."
if ! docker pull "${IMAGE_NAME}:latest" &>/dev/null 2>&1; then
    echo "需要登录阿里云 ACR"
    echo "登录命令: docker login ${REGISTRY}"
    docker login "${REGISTRY}"
fi
echo "ACR 登录正常"

# 构建镜像
echo ""
echo "[2/4] 构建 Docker 镜像..."
docker build \
    -t "${TAG}" \
    -t "${LATEST_TAG}" \
    -f "${PROJECT_DIR}/Dockerfile" \
    "${PROJECT_DIR}"

echo "构建完成"

# 推送镜像
echo ""
echo "[3/4] 推送镜像到 ACR..."
docker push "${TAG}"
docker push "${LATEST_TAG}"
echo "推送完成"

# 输出摘要
echo ""
echo "=========================================="
echo " 构建并推送成功!"
echo "=========================================="
echo " 版本标签: ${TIMESTAMP}"
echo " 镜像地址: ${TAG}"
echo " Latest:   ${LATEST_TAG}"
echo ""
echo " 远程部署命令:"
echo "   cd /root/Holo/HoloBackend/deploy"
echo "   ./deploy-image.sh ${TIMESTAMP}"
echo "=========================================="
