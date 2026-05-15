#!/bin/bash
# HoloBackend ECS 部署/更新脚本
# 用法：ssh 到 ECS 后执行 bash deploy.sh

set -e

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
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

# 3. 拉取最新代码
echo "[2/5] 拉取最新代码..."
cd "$DEPLOY_DIR/../.."
git pull || echo "[!] git pull 失败，使用当前代码继续"
cd "$DEPLOY_DIR"

# 4. 构建并启动
echo "[3/5] 构建 Docker 镜像（首次可能需要几分钟）..."
docker compose up -d --build

# 5. 等待启动
echo "[4/5] 等待服务启动..."
sleep 3

# 6. 健康检查
echo "[5/5] 健康检查..."
HEALTH=$(curl -s http://127.0.0.1:8787/v1/health 2>/dev/null || echo '{"ok":false}')

if echo "$HEALTH" | grep -q '"ok":true'; then
  echo ""
  echo "✅ 部署成功！"
  echo ""
  echo "  API 端点:  http://<ECS公网IP>/v1/health"
  echo "  管理后台:  ssh -L 8787:127.0.0.1:8787 root@<ECS公网IP>"
  echo "             然后浏览器打开 http://localhost:8787/admin/logs"
  echo ""
  echo "  查看日志:  docker compose -f $DEPLOY_DIR/docker-compose.yml logs -f"
else
  echo ""
  echo "❌ 健康检查失败，请查看日志："
  echo "  docker compose -f $DEPLOY_DIR/docker-compose.yml logs holo-backend"
  exit 1
fi
