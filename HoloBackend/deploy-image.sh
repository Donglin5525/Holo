#!/bin/bash
# HoloBackend 远程服务器部署脚本
# 根据指定时间戳从阿里云 ACR 拉取镜像并替换运行中的容器
# 用法: ./deploy-image.sh <时间戳>
# 示例: ./deploy-image.sh 20260527-120000

set -euo pipefail

# 配置
REGISTRY="crpi-80bfuvdry686vlon.cn-shenzhen.personal.cr.aliyuncs.com"
REPOSITORY="tang99/holo"
IMAGE_NAME="${REGISTRY}/${REPOSITORY}"
CONTAINER_NAME="holo-backend"
HEALTH_URL="http://127.0.0.1:8787/v1/health"
HEALTH_RETRIES=15
HEALTH_INTERVAL=2

# 参数检查
if [ -z "${1:-}" ]; then
    echo "用法: $0 <时间戳>"
    echo "示例: $0 20260527-120000"
    exit 1
fi

TIMESTAMP="$1"
TAG="${IMAGE_NAME}:${TIMESTAMP}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/deploy/docker-compose.yml"

echo "=========================================="
echo " HoloBackend 远程部署"
echo "=========================================="
echo " 版本: ${TIMESTAMP}"
echo " 镜像: ${TAG}"
echo "=========================================="

# 检查 Docker 是否可用
if ! command -v docker &>/dev/null; then
    echo "错误: docker 命令未找到"
    exit 1
fi

# 拉取新镜像
echo ""
echo "[1/5] 拉取镜像 ${TAG}..."
docker pull "${TAG}"
echo "拉取完成"

# 更新 docker-compose.yml 中的 image 字段
echo ""
echo "[2/5] 更新 docker-compose.yml..."
if [ -f "${COMPOSE_FILE}" ]; then
    # 使用 sed 更新或插入 image 字段
    if grep -q "image:" "${COMPOSE_FILE}"; then
        sed -i "s|image:.*|image: ${TAG}|" "${COMPOSE_FILE}"
    else
        # 在 build 部分之前插入 image
        sed -i "/build:/i\\    image: ${TAG}" "${COMPOSE_FILE}"
    fi
    echo "docker-compose.yml 已更新"
else
    echo "警告: 未找到 docker-compose.yml，使用 docker run 启动"
fi

# 停止旧容器
echo ""
echo "[3/5] 停止旧容器..."
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    OLD_IMAGE=$(docker inspect --format='{{.Config.Image}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")
    docker stop "${CONTAINER_NAME}" || true
    docker rm "${CONTAINER_NAME}" || true
    echo "旧容器已停止 (原镜像: ${OLD_IMAGE})"
else
    echo "未发现运行中的旧容器"
fi

# 启动新容器
echo ""
echo "[4/5] 启动新容器..."
if [ -f "${COMPOSE_FILE}" ]; then
    cd "${SCRIPT_DIR}/deploy"
    docker compose up -d --no-build
else
    # 回退到 docker run
    ENV_FILE="${SCRIPT_DIR}/.env.production"
    DATA_DIR="${SCRIPT_DIR}/data"
    mkdir -p "${DATA_DIR}"

    docker run -d \
        --name "${CONTAINER_NAME}" \
        --restart unless-stopped \
        --env-file "${ENV_FILE}" \
        -p 127.0.0.1:8787:8787 \
        -v "${DATA_DIR}:/data" \
        "${TAG}"
fi
echo "新容器已启动"

# 健康检查
echo ""
echo "[5/5] 健康检查..."
for i in $(seq 1 ${HEALTH_RETRIES}); do
    if curl -sf "${HEALTH_URL}" | grep -q '"ok"'; then
        echo "健康检查通过!"
        break
    fi
    if [ "$i" -eq "${HEALTH_RETRIES}" ]; then
        echo "警告: 健康检查超时，请手动确认服务状态"
        docker logs --tail 20 "${CONTAINER_NAME}"
        exit 1
    fi
    sleep "${HEALTH_INTERVAL}"
done

# 清理旧镜像
echo ""
echo "清理未使用的旧镜像..."
docker image prune -f --filter "dangling=true" 2>/dev/null || true

# 输出摘要
echo ""
echo "=========================================="
echo " 部署完成!"
echo "=========================================="
echo " 版本:  ${TIMESTAMP}"
echo " 镜像:  ${TAG}"
echo " 状态:  $(docker ps --filter "name=${CONTAINER_NAME}" --format '{{.Status}}')"
echo " 健康端点: ${HEALTH_URL}"
echo "=========================================="
