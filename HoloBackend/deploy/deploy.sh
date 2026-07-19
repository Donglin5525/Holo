#!/usr/bin/env bash
# HoloBackend ECS 部署/更新脚本
# 用法：先用 rsync/bundle 同步代码，再 ssh 到 ECS 执行 bash deploy.sh
# 如确实要在服务器上 git pull：RUN_GIT_PULL=1 bash deploy.sh

set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$DEPLOY_DIR/../.." && pwd)"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-https://api.holoapp.cn}"

cd "$DEPLOY_DIR"

echo "=== HoloBackend 部署 ==="
echo ""

# 1. 创建数据目录
echo "[1/6] 创建数据目录..."
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

# 幂等缓存包含短期结构化模型响应，生产必须使用持久的 32 字节 Base64 密钥。
# 这里只校验存在与格式，不输出密钥。
AGENT_STEP_ENCRYPTION_KEY="$(sed -n 's/^HOLO_AGENT_STEP_IDEMPOTENCY_ENCRYPTION_KEY=//p' .env.production | tail -n 1)"
if [ -z "$AGENT_STEP_ENCRYPTION_KEY" ]; then
  echo "Agent step 响应加密配置缺失：HOLO_AGENT_STEP_IDEMPOTENCY_ENCRYPTION_KEY"
  exit 1
fi
if ! AGENT_STEP_ENCRYPTION_KEY_BYTES="$(
  printf '%s' "$AGENT_STEP_ENCRYPTION_KEY" | base64 --decode 2>/dev/null | wc -c | tr -d ' '
)"; then
  echo "Agent step 响应加密密钥格式无效：必须是 32 字节标准 Base64"
  exit 1
fi
if [ "$AGENT_STEP_ENCRYPTION_KEY_BYTES" != "32" ]; then
  echo "Agent step 响应加密密钥格式无效：必须是 32 字节标准 Base64"
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

# 生成可复核的发布身份。rsync 发布允许工作区存在未提交改动，因此仅记录 Git SHA 不足以
# 证明容器实际使用了哪份代码；source digest 覆盖本次 Docker context 中的全部源码，且排除
# 生产密钥、SQLite 与依赖目录。compose 的 environment 会覆盖 .env.production 中的陈旧值。
HOLO_RELEASE_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || printf 'unknown')"
HOLO_RELEASE_SOURCE_DIGEST="$({
  git -C "$REPO_DIR" ls-files --cached --others --exclude-standard -- HoloBackend 2>/dev/null || true
} | LC_ALL=C sort | while IFS= read -r relative_path; do
  case "$relative_path" in
    HoloBackend/node_modules/*|HoloBackend/deploy/.env.production*|HoloBackend/deploy/data/*) continue ;;
  esac
  [ -f "$REPO_DIR/$relative_path" ] || continue
  file_hash="$(sha256sum "$REPO_DIR/$relative_path" | awk '{print $1}')"
  printf '%s  %s\n' "$file_hash" "$relative_path"
done | sha256sum | awk '{print $1}')"
HOLO_RELEASE_BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export HOLO_RELEASE_COMMIT HOLO_RELEASE_SOURCE_DIGEST HOLO_RELEASE_BUILD_TIME
echo "    发布身份: ${HOLO_RELEASE_COMMIT:0:12} + source ${HOLO_RELEASE_SOURCE_DIGEST:0:12}"

# 4. 构建并启动
echo "[3/6] 构建 Docker 镜像（关闭 BuildKit，避免把本地镜像误当远端镜像拉取）..."
DOCKER_BUILDKIT=0 docker compose build holo-backend

echo "[4/6] 强制重建并启动容器..."
docker compose up -d --force-recreate holo-backend

# 5. 等待启动
echo "[5/6] 等待服务启动..."
sleep 3

# 6. 健康检查
echo "[6/6] 运行本机 + 公网 + 管理员发布状态验收..."

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

ADMIN_TOKEN=$(sed -n 's/^HOLO_ADMIN_TOKEN=//p' .env.production | tail -n 1)
if [ -z "$ADMIN_TOKEN" ]; then
  echo "管理员发布状态验收失败：HOLO_ADMIN_TOKEN 未配置"
  exit 1
fi

ADMIN_RELEASE_STATUS=$(curl -fsS -H "x-holo-admin-token: $ADMIN_TOKEN" "$PUBLIC_BASE_URL/v1/admin/release/status")
if ! echo "$ADMIN_RELEASE_STATUS" | grep -q '"intent_recognition"'; then
  echo "管理员发布状态验收失败"
  exit 1
fi

echo ""
echo "部署成功，且生产入口已完成基础验收。"
echo ""
echo "  生产健康检查:  $PUBLIC_BASE_URL/v1/health"
echo "  Release 状态:  $PUBLIC_BASE_URL/v1/release/status"
echo "  管理员状态:    $PUBLIC_BASE_URL/v1/admin/release/status"
echo "  管理后台:      ssh -L 8787:127.0.0.1:8787 root@<ECS公网IP>"
echo "                 然后浏览器打开 http://localhost:8787/admin/logs"
echo ""
echo "  查看日志:      docker compose -f $DEPLOY_DIR/docker-compose.yml logs -f holo-backend"
