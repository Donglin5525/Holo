#!/bin/bash
# Holo 后端用户量统计（只读，不写任何数据）
# 用法：bash HoloBackend/scripts/backend-user-stats.sh
# 原理：把 backend-user-stats-query.js 通过 SSH 管道送进生产容器里的 Node 执行，
#       统计逻辑只存在于本机文件，服务器上不留任何东西，部署/重建容器都不影响。
set -euo pipefail
HOST="${HOLO_REMOTE_HOST:-root@123.56.104.9}"
DIR="$(cd "$(dirname "$0")" && pwd)"
exec ssh "$HOST" "docker exec -i holo-backend node -" < "$DIR/backend-user-stats-query.js"
