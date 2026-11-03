#!/usr/bin/env bash
# HoloBackend 统一发布脚本 —— 三宿主（ZCode / Codex / Claude Code）唯一真源
#
# 2026-10-20 由跨平台配置审计合并自三个并存版本：
#   - Codex 个人版（ECS git pull、无锁无备份、普通 commit 可能夹带已暂存文件）
#   - Claude/ZCode 共用版（ECS git fetch 依赖 GitHub、脏树逐文件诊断、同样的夹带风险）
#   - 父目录项目版（rsync + flock + cp 热拷贝备份 + verify:prod）
# 并修复审计发现：A01 提交范围夹带（改 pathspec 提交＋事后断言）、A02 WAL 库热拷贝备份（改在线备份 API）。
#
# 用法（东林明确要求发版之后）：
#   HOLO_DEPLOY_CONFIRM=yes bash docs/_common/agent-skills/holo-backend-deploy/scripts/deploy-backend.sh
# 可选环境变量：
#   HOLO_DEPLOY_SYNC=push|rsync       同步方式。默认 push：本地直推 ECS 仓库的 deploy-target 引用，不依赖 ECS 连 GitHub
#   HOLO_DEPLOY_AUTO_COMMIT=0         不自动提交后端改动（默认 1：只按 pathspec 提交 HoloBackend/）
#   HOLO_DEPLOY_COMMIT_MESSAGE=...    自动提交信息（默认 chore(backend): deploy HoloBackend updates）
#   HOLO_DEPLOY_SKIP_TESTS=1          跳过本地测试（仅限测试自身 flaky 且已人工确认）
#   HOLO_DEPLOY_FORCE_ALIGN=1         ECS 工作区存在真正分歧改动时仍强制对齐（需人工核对后才可用）
set -euo pipefail

HOLO_REPO="${HOLO_REPO:-/Users/tangyuxuan/Desktop/Claude/HOLO}"
REMOTE_HOST="${HOLO_REMOTE_HOST:-root@123.56.104.9}"
REMOTE_REPO="${HOLO_REMOTE_REPO:-/root/Holo}"
BACKEND_DIR="${HOLO_BACKEND_DIR:-HoloBackend}"
SERVICE_NAME="${HOLO_BACKEND_SERVICE:-holo-backend}"
PUBLIC_BASE_URL="${HOLO_PUBLIC_BASE_URL:-https://api.holoapp.cn}"
SYNC_MODE="${HOLO_DEPLOY_SYNC:-push}"
AUTO_COMMIT="${HOLO_DEPLOY_AUTO_COMMIT:-1}"
DEPLOY_REF="refs/heads/deploy-target"

log()  { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf '\n❌ %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"; }

# 0. 授权闸门：生产发版必须由东林明确要求
[ "${HOLO_DEPLOY_CONFIRM:-}" = "yes" ] || fail "未确认发布授权。生产发版必须由东林明确要求；确认后以 HOLO_DEPLOY_CONFIRM=yes 重跑。"

require_cmd git; require_cmd npm; require_cmd ssh; require_cmd curl
case "$SYNC_MODE" in
  push) ;;
  rsync) require_cmd rsync ;;
  *) fail "HOLO_DEPLOY_SYNC 只能是 push 或 rsync" ;;
esac

[ -d "$HOLO_REPO/.git" ] || fail "找不到 HOLO git 仓库：$HOLO_REPO"
[ -d "$HOLO_REPO/$BACKEND_DIR" ] || fail "找不到后端目录：$HOLO_REPO/$BACKEND_DIR"
cd "$HOLO_REPO"

BRANCH="$(git branch --show-current)"
[ -n "$BRANCH" ] || fail "当前不在普通分支上，无法自动部署"

log "准备部署 HoloBackend"
printf '本地仓库: %s\n当前分支: %s\n远端服务器: %s\n远端仓库: %s\n同步方式: %s\n' \
  "$HOLO_REPO" "$BRANCH" "$REMOTE_HOST" "$REMOTE_REPO" "$SYNC_MODE"

# 1. 本地测试
if [ "${HOLO_DEPLOY_SKIP_TESTS:-0}" = "1" ]; then
  log "⚠️ 已按要求跳过本地测试（HOLO_DEPLOY_SKIP_TESTS=1）"
else
  log "运行后端测试"
  npm test --prefix "$BACKEND_DIR"
fi

# 2. 提交范围守卫（A01）：只按 pathspec 提交 HoloBackend/，暂存区里的其他文件原样留在暂存区
BACKEND_STATUS="$(git status --porcelain -- "$BACKEND_DIR")"
if [ -n "$BACKEND_STATUS" ]; then
  if [ "$AUTO_COMMIT" = "1" ]; then
    log "发现 HoloBackend 本地变更，按路径范围提交（不夹带其他文件）"
    printf '%s\n' "$BACKEND_STATUS"
    STAGED_OUTSIDE="$(git diff --cached --name-only | grep -v "^$BACKEND_DIR/" || true)"
    if [ -n "$STAGED_OUTSIDE" ]; then
      log "ℹ️ 暂存区已有后端之外的文件，本次提交不会带入它们（保持原样）："
      printf '%s\n' "$STAGED_OUTSIDE" | sed 's/^/   /'
    fi
    git add -- "$BACKEND_DIR"
    if git diff --cached --quiet -- "$BACKEND_DIR"; then
      log "后端变更已被忽略或无需提交"
    else
      COMMIT_SUBJECT="${HOLO_DEPLOY_COMMIT_MESSAGE:-chore(backend): deploy HoloBackend updates}"
      git commit -m "$COMMIT_SUBJECT" -- "$BACKEND_DIR"
      if git show --name-only --format= HEAD | grep -v "^$BACKEND_DIR/" | grep -q .; then
        fail "提交范围守卫失败：HEAD 含后端之外的文件，请人工检查 git show --stat HEAD"
      fi
      log "已提交后端范围：$(git rev-parse --short HEAD)"
    fi
  else
    fail "HoloBackend 有未提交变更且 HOLO_DEPLOY_AUTO_COMMIT=0；请先手动按范围提交后端"
  fi
else
  log "HoloBackend 没有本地未提交变更"
fi
HEAD_SHA="$(git rev-parse HEAD)"
log "发布基线 commit: $HEAD_SHA"

# 推 origin：GitHub 不通不阻断（ECS 同步不依赖它）
log "推送当前分支到 origin（失败不阻断）"
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  git push || log "⚠️ 推送 origin 失败（GitHub 不通？）——不阻断发版，稍后手动 git push"
else
  git push -u origin "$BRANCH" || log "⚠️ 推送 origin 失败——不阻断发版，稍后手动 git push -u origin $BRANCH"
fi

# 3. 代码同步到 ECS
if [ "$SYNC_MODE" = "push" ]; then
  log "直推 HEAD 到 ECS 仓库引用 ${DEPLOY_REF}（非检出分支，不受 ECS 工作区脏状态影响，不依赖 GitHub）"
  git push --force "ssh://${REMOTE_HOST}${REMOTE_REPO}" "HEAD:${DEPLOY_REF}"
else
  log "rsync 同步后端代码（先 dry-run 预览前 80 行）"
  RSYNC_ARGS=(-az --delete --exclude node_modules --exclude .env --exclude deploy/.env.production --exclude deploy/data --exclude 'deploy/*.bak*')
  rsync "${RSYNC_ARGS[@]}" --dry-run --itemize-changes "$HOLO_REPO/$BACKEND_DIR/" "$REMOTE_HOST:$REMOTE_REPO/$BACKEND_DIR/" | sed -n '1,80p'
  rsync "${RSYNC_ARGS[@]}" "$HOLO_REPO/$BACKEND_DIR/" "$REMOTE_HOST:$REMOTE_REPO/$BACKEND_DIR/"
fi

# 4. ECS 端：互斥锁 → 数据保护快照 → 对齐代码 → 一致性备份 → deploy.sh → 数据保护断言 → 本机健康轮询
log "连接 ECS 执行部署（flock 互斥）"
ssh "$REMOTE_HOST" \
  "HOLO_BRANCH='$BRANCH' REMOTE_REPO='$REMOTE_REPO' SERVICE_NAME='$SERVICE_NAME' SYNC_MODE='$SYNC_MODE' DEPLOY_REF='$DEPLOY_REF' EXPECT_SHA='$HEAD_SHA' HOLO_DEPLOY_FORCE_ALIGN='${HOLO_DEPLOY_FORCE_ALIGN:-0}' flock -n /tmp/holo-backend-deploy.lock bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail
log()  { printf '\n[%s][ECS] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf '\n❌ [ECS] %s\n' "$*" >&2; exit 1; }

cd "$REMOTE_REPO" || fail "找不到远端仓库：$REMOTE_REPO"
DEPLOY_DIR="$REMOTE_REPO/HoloBackend/deploy"
DATA_DIR="$DEPLOY_DIR/data"
DB="$DATA_DIR/holo-backend.db"
[ -d "$DEPLOY_DIR" ] || fail "compose 目录不存在：$DEPLOY_DIR（这是唯一合法目录；禁止使用 /opt 等其他副本）"

HAD_DB=0; [ -f "$DB" ] && HAD_DB=1
log "部署前 HEAD: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)；生产库文件存在: $HAD_DB"

if [ "$SYNC_MODE" = "push" ]; then
  git rev-parse --verify --quiet "$DEPLOY_REF" >/dev/null || fail "ECS 未收到 $DEPLOY_REF"
  TARGET_SHA="$(git rev-parse "$DEPLOY_REF")"
  [ "$TARGET_SHA" = "$EXPECT_SHA" ] || fail "ECS 收到的 deploy-target ($TARGET_SHA) 与本地 HEAD ($EXPECT_SHA) 不一致"

  log "诊断服务器已跟踪文件改动是否与目标版本一致（历史 rsync 残留属常态，不是事故）"
  TRACKED_DIRTY="$(git status --porcelain --untracked-files=no)"
  if [ -n "$TRACKED_DIRTY" ]; then
    diverges=0
    while IFS= read -r line; do
      file="$(printf '%s' "$line" | awk '{print $2}')"
      [ -n "$file" ] || continue
      if [ -f "$file" ]; then
        # 必须用 pathspec 形式；"ref:path path" 写法在 pipefail 下 fatal 128 静默中止（记忆档 backend-deploy-pitfalls 坑1）
        diff_lines="$(git diff "$DEPLOY_REF" -- "$file" --no-color 2>/dev/null | wc -l | tr -d ' ')"
        if [ "$diff_lines" != "0" ]; then
          printf '⚠️  与目标版本不同（%s 行 diff）：%s\n' "$diff_lines" "$file"
          diverges=1
        fi
      fi
    done <<< "$TRACKED_DIRTY"
    if [ "$diverges" != "0" ] && [ "$HOLO_DEPLOY_FORCE_ALIGN" != "1" ]; then
      fail "服务器存在与目标版本真正分歧的改动，拒绝覆盖。请人工核对；确认可丢弃后以 HOLO_DEPLOY_FORCE_ALIGN=1 重跑"
    fi
  fi
  log "对齐工作区到 $DEPLOY_REF（reset --hard 不触碰未跟踪的 deploy/data；本脚本永不执行 git clean）"
  git reset --hard "$DEPLOY_REF"
  git checkout -B "$HOLO_BRANCH" "$DEPLOY_REF" >/dev/null 2>&1 || true
  log "部署后 HEAD: $(git rev-parse --short HEAD)"
else
  log "rsync 模式：不触碰 ECS git 状态（工作区将与 HEAD 不一致，属已知常态）"
fi

cd "$DEPLOY_DIR"
[ -f .env.production ] || fail "缺少 $DEPLOY_DIR/.env.production"

# A02：一致性备份（在线备份 API 会带走 WAL 中已提交事务）；失败即阻止发布，不退回 cp 热拷贝
if [ "$HAD_DB" = 1 ]; then
  mkdir -p "$DATA_DIR/backups"
  OUT="$DATA_DIR/backups/holo-backend-$(date +%Y%m%d-%H%M%S).db"
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$DB" ".backup '$OUT'" || fail "sqlite3 .backup 失败，拒绝发布"
    sqlite3 "$OUT" "PRAGMA integrity_check;" | grep -qx ok || fail "备份完整性校验失败：$OUT"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$DB" "$OUT" <<'PY' || fail "python3 sqlite backup 失败，拒绝发布"
import sqlite3, sys
src = sqlite3.connect(sys.argv[1]); dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
ok = dst.execute("PRAGMA integrity_check").fetchone()[0]
dst.close(); src.close()
sys.exit(0 if ok == "ok" else 1)
PY
  else
    fail "ECS 缺 sqlite3 与 python3，无法做一致性备份；拒绝发布"
  fi
  log "SQLite 一致性备份完成：$OUT（$(du -h "$OUT" | cut -f1)）"
  N="$(ls -1 "$DATA_DIR/backups"/*.db 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$N" -gt 20 ]; then log "ℹ️ 备份目录已有 $N 份，请人工清理旧备份（脚本不自动删除任何文件）"; fi
else
  log "ℹ️ 生产库文件不存在（首次部署？），跳过备份"
fi

log "调用项目自带 deploy.sh（nohup 后台跑并轮询，防 SSH 空闲掐断长构建）"
LOGF="/tmp/holo-deploy-$(date +%Y%m%d-%H%M%S).log"
RUN_GIT_PULL=0 nohup bash deploy.sh < /dev/null > "$LOGF" 2>&1 &
PID=$!
while kill -0 "$PID" 2>/dev/null; do printf '.'; sleep 5; done; echo
DEPLOY_RC=0; wait "$PID" || DEPLOY_RC=$?
tail -n 40 "$LOGF"

# 生产数据保护断言
if [ "$HAD_DB" = 1 ] && [ ! -f "$DB" ]; then
  fail "生产数据库文件消失！立即停止，按记忆档 backend-deploy-pitfalls 坑15（/proc/PID/fd 恢复）处理"
fi

log "本机健康轮询（deploy.sh 内置 curl 有竞态，以此为准）"
HEALTHY=0
for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8787/v1/health 2>/dev/null | grep -q '"ok":true'; then HEALTHY=1; break; fi
  sleep 2
done
if [ "$HEALTHY" = 1 ]; then
  if [ "$DEPLOY_RC" != 0 ]; then
    log "⚠️ deploy.sh 退出码 $DEPLOY_RC 但服务已健康——大概率是其内置验收 curl 竞态（已知坑），以本轮询为准；日志 $LOGF"
  fi
  log "服务健康"
else
  docker compose ps || true
  docker compose logs --tail=80 "$SERVICE_NAME" || true
  fail "容器未在 60s 内健康（deploy.sh 退出码 $DEPLOY_RC，日志 $LOGF）"
fi
log "ECS 部署完成"
REMOTE_SCRIPT

# 5. 公网验收
log "验证公网健康"
PUBLIC_HEALTH="$(curl -fsS "$PUBLIC_BASE_URL/v1/health")"
printf '%s\n' "$PUBLIC_HEALTH"
printf '%s\n' "$PUBLIC_HEALTH" | grep -q '"ok":true' || fail "公网健康检查未返回 ok=true"
curl -fsS "$PUBLIC_BASE_URL/v1/release/status" && echo || log "⚠️ release/status 读取失败，请手动核对"

log "部署成功"
printf '✅ HoloBackend 已部署到 %s，分支 %s，commit %s\n' "$PUBLIC_BASE_URL" "$BRANCH" "${HEAD_SHA:0:12}"
printf '下一步（分层验收）：SKIP_INTENT_CASES=1 npm run verify:prod --prefix %s\n' "$BACKEND_DIR"
