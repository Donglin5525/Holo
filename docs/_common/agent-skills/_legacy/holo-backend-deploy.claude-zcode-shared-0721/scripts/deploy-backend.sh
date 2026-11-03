#!/usr/bin/env bash
set -euo pipefail

HOLO_REPO="${HOLO_REPO:-/Users/tangyuxuan/Desktop/Claude/HOLO}"
REMOTE_HOST="${HOLO_REMOTE_HOST:-root@123.56.104.9}"
REMOTE_REPO="${HOLO_REMOTE_REPO:-/root/Holo}"
BACKEND_DIR="${HOLO_BACKEND_DIR:-HoloBackend}"
SERVICE_NAME="${HOLO_BACKEND_SERVICE:-holo-backend}"
PUBLIC_BASE_URL="${HOLO_PUBLIC_BASE_URL:-https://api.holoapp.cn}"

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
  printf '\n❌ %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"
}

require_cmd git
require_cmd npm
require_cmd ssh
require_cmd curl

[ -d "$HOLO_REPO/.git" ] || fail "找不到 HOLO git 仓库：$HOLO_REPO"
[ -d "$HOLO_REPO/$BACKEND_DIR" ] || fail "找不到后端目录：$HOLO_REPO/$BACKEND_DIR"

cd "$HOLO_REPO"

BRANCH="$(git branch --show-current)"
[ -n "$BRANCH" ] || fail "当前不在普通分支上，无法自动部署"

log "准备部署 HoloBackend"
printf '本地仓库: %s\n' "$HOLO_REPO"
printf '当前分支: %s\n' "$BRANCH"
printf '远端服务器: %s\n' "$REMOTE_HOST"
printf '远端仓库: %s\n' "$REMOTE_REPO"

log "刷新远端分支信息"
git fetch origin

log "运行后端测试"
npm test --prefix "$BACKEND_DIR"

BACKEND_STATUS="$(git status --porcelain -- "$BACKEND_DIR")"
if [ -n "$BACKEND_STATUS" ]; then
  log "发现 HoloBackend 本地变更，自动提交后端范围内文件"
  printf '%s\n' "$BACKEND_STATUS"
  git add "$BACKEND_DIR"
  if git diff --cached --quiet -- "$BACKEND_DIR"; then
    log "后端变更已被忽略或无需提交"
  else
    COMMIT_SUBJECT="${HOLO_DEPLOY_COMMIT_MESSAGE:-chore(backend): deploy HoloBackend updates}"
    git commit -m "$COMMIT_SUBJECT"
  fi
else
  log "HoloBackend 没有本地未提交变更"
fi

log "推送当前分支到 origin"
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  git push
else
  git push -u origin "$BRANCH"
fi

log "连接 ECS 并部署 Docker Compose 服务"
ssh "$REMOTE_HOST" \
  "HOLO_BRANCH='$BRANCH' REMOTE_REPO='$REMOTE_REPO' SERVICE_NAME='$SERVICE_NAME' bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail

log() {
  printf '\n[%s][ECS] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
  printf '\n❌ [ECS] %s\n' "$*" >&2
  exit 1
}

cd "$REMOTE_REPO" || fail "找不到远端仓库：$REMOTE_REPO"

log "拉取远端分支信息"
git fetch origin

log "检查服务器已跟踪源码状态"
TRACKED_DIRTY="$(git status --porcelain --untracked-files=no)"
if [ -n "$TRACKED_DIRTY" ]; then
  log "发现已跟踪文件改动，诊断是否与 origin/$HOLO_BRANCH 一致"
  # 逐一比对：服务器 working tree 改动是否其实就是 origin/branch 的内容
  # 这种情况常见于历史部署用 rsync/cp 同步文件但未 commit，HEAD 落后于实际文件
  diverges=0
  while IFS= read -r line; do
    file="$(printf '%s' "$line" | awk '{print $2}')"
    [ -n "$file" ] || continue
    if [ -f "$file" ]; then
      # 注意：git diff "origin/branch:$file" "$file" 会把第二个参数当有歧义的 rev 而 fatal(128)，
      # 在 set -o pipefail 下直接中止远端脚本。必须用 "-- <path>" 的 pathspec 形式。
      diff_lines="$(git diff "origin/$HOLO_BRANCH" -- "$file" --no-color 2>/dev/null | wc -l | tr -d ' ')"
      if [ "$diff_lines" != "0" ]; then
        printf '⚠️  与 origin/%s 不同（%s 行 diff）：%s\n' "$HOLO_BRANCH" "$diff_lines" "$file"
        diverges=1
      fi
    fi
  done <<< "$TRACKED_DIRTY"

  if [ "$diverges" = "0" ]; then
    log "所有改动内容均 == origin/$HOLO_BRANCH（历史同步未提交 HEAD 所致），安全对齐"
  else
    fail "服务器存在与 origin/$HOLO_BRANCH 真正分歧的改动。请人工核对后处理，避免覆盖服务器本地修改。"
  fi
fi

log "对齐 HEAD 到 origin/$HOLO_BRANCH（reset --hard，由上方诊断保证安全）"
git checkout "$HOLO_BRANCH" 2>/dev/null || git checkout -B "$HOLO_BRANCH" "origin/$HOLO_BRANCH"
git reset --hard "origin/$HOLO_BRANCH"

cd "$REMOTE_REPO/HoloBackend/deploy" || fail "找不到部署目录"

if [ ! -f .env.production ]; then
  fail "缺少 HoloBackend/deploy/.env.production"
fi

log "调用项目自带 deploy.sh 构建并启动（已规避 BuildKit 远程拉取问题）"
RUN_GIT_PULL=0 bash deploy.sh

log "部署完成"
REMOTE_SCRIPT

log "验证公网健康检查"
PUBLIC_HEALTH="$(curl -fsS "$PUBLIC_BASE_URL/v1/health")"
printf '%s\n' "$PUBLIC_HEALTH"
printf '%s\n' "$PUBLIC_HEALTH" | grep -q '"ok":true' || fail "公网健康检查未返回 ok=true"

log "部署成功"
printf '✅ HoloBackend 已部署到 %s，分支 %s\n' "$PUBLIC_BASE_URL" "$BRANCH"
