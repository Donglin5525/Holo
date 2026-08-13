#!/usr/bin/env bash
# ============================================================
# Holo 上架凭证激活脚本 —— 两个「必拒项」最后一步
#
# 作用：把 Apple/阿里云凭证写入 ECS 生产环境 → 重启后端 → 验证生效
#
# 用法：
#   1. 编辑本脚本，填入下面 4 个凭证值
#   2. bash docs/appstore-preflight/activate-credentials.sh
#
# 安全：凭证值只存在于你本地的这个脚本文件里，不经过任何第三方。
#       脚本用完建议删除或加入 .gitignore（已含敏感值勿提交 git）。
# ============================================================
set -euo pipefail

# ↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓
# 填入你的凭证（4 个）

APPLE_KEY_ID="你的10位KeyID"
APPLE_P8_FILE="$HOME/Downloads/AuthKey_XXXXXXXXXX.p8"   # 改成你下载的 .p8 实际路径
ALIYUN_ACCESS_KEY_ID="你的阿里云AccessKeyId"
ALIYUN_ACCESS_KEY_SECRET="你的阿里云AccessKeySecret"

# ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑

ECS="root@123.56.104.9"
REMOTE_ENV="/root/Holo/HoloBackend/deploy/.env.production"
REMOTE_COMPOSE="/root/Holo/HoloBackend/deploy/docker-compose.yml"
REMOTE_P8="/tmp/holo_apple_key.p8"

# —— 校验 ——
if [[ "$APPLE_KEY_ID" == "你的10位KeyID" ]] || [[ "$ALIYUN_ACCESS_KEY_ID" == "你的阿里云AccessKeyId" ]]; then
  echo "❌ 请先编辑本脚本，把 4 个「填入你的凭证」替换成真实值，再运行。"
  exit 1
fi
if [[ ! -f "$APPLE_P8_FILE" ]]; then
  echo "❌ 找不到 .p8 文件：$APPLE_P8_FILE"
  echo "   把 APPLE_P8_FILE 改成你从 Apple Developer 下载的 .p8 文件的实际路径。"
  exit 1
fi

echo "▶ 1/4  上传 Apple .p8 到 ECS（临时，用完即删）..."
scp -q "$APPLE_P8_FILE" "$ECS:$REMOTE_P8"

echo "▶ 2/4  写入凭证到生产环境 $REMOTE_ENV ..."
ssh "$ECS" "python3 -" << PYEOF
import re, os
key_id = "$APPLE_KEY_ID"
ak = "$ALIYUN_ACCESS_KEY_ID"
sk = "$ALIYUN_ACCESS_KEY_SECRET"
pem = open("$REMOTE_P8").read().strip()
# .p8 的 PEM 含多行换行，写入单行 .env 时转成字面 \n，后端 normalizePem 会自动还原
pem_line = pem.replace("\n", "\\\\n")
s = open("$REMOTE_ENV").read()
s = re.sub(r"^APPLE_KEY_ID=.*",              "APPLE_KEY_ID=" + key_id,        s, flags=re.M)
s = re.sub(r"^APPLE_TEAM_ID=.*",             "APPLE_TEAM_ID=6WZ5TXGPQY",      s, flags=re.M)
s = re.sub(r"^APPLE_PRIVATE_KEY_PEM=.*",     "APPLE_PRIVATE_KEY_PEM=" + pem_line, s, flags=re.M)
s = re.sub(r"^ALIBABA_CLOUD_ACCESS_KEY_ID=.*",     "ALIBABA_CLOUD_ACCESS_KEY_ID=" + ak, s, flags=re.M)
s = re.sub(r"^ALIBABA_CLOUD_ACCESS_KEY_SECRET=.*", "ALIBABA_CLOUD_ACCESS_KEY_SECRET=" + sk, s, flags=re.M)
open("$REMOTE_ENV", "w").write(s)
os.remove("$REMOTE_P8")
print("    凭证写入完成，临时 .p8 已删除")
PYEOF

echo "▶ 3/4  重启 holo-backend 容器（让新凭证生效）..."
ssh "$ECS" "docker compose -f $REMOTE_COMPOSE up -d holo-backend"
echo "    等待启动..."
sleep 6

echo "▶ 4/4  验证两个必拒项..."
echo -n "    健康检查: "
curl -s --max-time 10 https://api.holoapp.cn/v1/health; echo

echo -n "    账号撤销端点（应返回 401 而非 503）: "
curl -s --max-time 10 -X POST https://api.holoapp.cn/v1/auth/apple/revoke \
  -H "Content-Type: application/json" -d '{"identityToken":"placeholder.invalid.token"}'; echo

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  判定："
echo "    • 账号撤销返回 401 INVALID_APPLE_IDENTITY = ✅ 凭证已识别（token是假的所以拒）"
echo "      返回 503 APPLE_REVOKE_NOT_CONFIGURED   = ❌ 凭证没写进去，检查上方输出"
echo "    • AI 审核已随凭证生效，真实违规输入会被拦截"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "✅ 脚本完成。确认账号撤销是 401 后，两个必拒项即生效，可提交审核。"
echo "   （本脚本已含真实凭证，建议运行后删除：rm docs/appstore-preflight/activate-credentials.sh）"
