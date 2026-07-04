#!/usr/bin/env bash
# HoloBackend ECS 部署/更新脚本
# 用法：先用 rsync/bundle 同步代码，再 ssh 到 ECS 执行 bash deploy.sh
# 如确实要在服务器上 git pull：RUN_GIT_PULL=1 bash deploy.sh

set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-https://api.holoapp.cn}"

cd "$DEPLOY_DIR"

echo "=== HoloBackend 部署 ==="
echo ""

# 1. 创建数据目录
echo "[1/5] 创建数据目录..."
mkdir -p data

# 2. 检查 .env.production 是否存在
if [ ! -f .env.production ]; then
  echo "[!] .env.production 不存在，从模板创建..."
  cp env.production.example .env.production
  echo "    请编辑 .env.production 填入 API Key 和管理员凭证："
  echo "    nano $DEPLOY_DIR/.env.production"
  echo ""
  echo "    编辑完成后重新运行此脚本。"
  exit 1
fi

# 3. 确认代码来源
echo "[2/6] 确认代码来源..."
if [ "${RUN_GIT_PULL:-0}" = "1" ]; then
  echo "    RUN_GIT_PULL=1，尝试在 ECS 上拉取最新代码..."
  cd "$DEPLOY_DIR/../.."
  git pull
  cd "$DEPLOY_DIR"
else
  echo "    跳过 git pull；默认代码已由本地 rsync 或 bundle 同步到服务器。"
fi

# 4. 构建并启动
echo "[3/6] 构建 Docker 镜像（关闭 BuildKit，避免把本地镜像误当远端镜像拉取）..."
DOCKER_BUILDKIT=0 docker compose build holo-backend

echo "[4/6] 强制重建并启动容器..."
docker compose up -d --force-recreate holo-backend

# 5. 等待启动
echo "[5/6] 等待服务启动..."
sleep 3

# 6. 健康检查
echo "[6/6] 运行本机 + 公网 + Prompt 验收..."

LOCAL_HEALTH=$(curl -fsS http://127.0.0.1:8787/v1/health)
if ! echo "$LOCAL_HEALTH" | grep -q '"ok":true'; then
  echo "本机健康检查失败：$LOCAL_HEALTH"
  exit 1
fi

PUBLIC_HEALTH=$(curl -fsS "$PUBLIC_BASE_URL/v1/health")
if ! echo "$PUBLIC_HEALTH" | grep -q '"ok":true'; then
  echo "公网健康检查失败：$PUBLIC_HEALTH"
  exit 1
fi

RELEASE_STATUS=$(curl -fsS "$PUBLIC_BASE_URL/v1/release/status")
if ! echo "$RELEASE_STATUS" | grep -q '"holo-ai-gateway"'; then
  echo "公网 release status 验收失败：$RELEASE_STATUS"
  exit 1
fi

PROMPT_META=$(curl -fsS "$PUBLIC_BASE_URL/v1/prompts/meta")
if ! echo "$PROMPT_META" | grep -q '"intent_recognition"'; then
  echo "公网 Prompt meta 验收失败：$PROMPT_META"
  exit 1
fi

echo ""
echo "部署成功，且生产入口已完成基础验收。"
echo ""
echo "  生产健康检查:  $PUBLIC_BASE_URL/v1/health"
echo "  Release 状态:  $PUBLIC_BASE_URL/v1/release/status"
echo "  Prompt Meta:   $PUBLIC_BASE_URL/v1/prompts/meta"
echo "  管理后台:      ssh -L 8787:127.0.0.1:8787 root@<ECS公网IP>"
echo "                 然后浏览器打开 http://localhost:8787/admin/logs"
echo ""
echo "  查看日志:      docker compose -f $DEPLOY_DIR/docker-compose.yml logs -f holo-backend"
