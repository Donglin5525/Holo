#!/bin/bash
# inject.sh — 把剧本 JSON 一键灌进无头模拟器（自媒体模拟数据库标准入口）
# 用法：
#   ./inject.sh                     # 默认：小满剧本（story.json），iPhone 17
#   ./inject.sh --story other.json  # 指定剧本文件
#   ./inject.sh --build             # 强制重新构建 Debug 包
#   ./inject.sh --keep              # 注入后不 terminate（接着拍摄/走查）
#   ./inject.sh --verify            # 注入后 sqlite 只读核对行数
set -euo pipefail

UDID="${UDID:-F9F5EDDE-EB22-4951-A876-532BC5C53687}"   # iPhone 17 (iOS 26.3)
BUNDLE="com.holo.Holo"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$HERE/../../.."                              # → Holo APP/
APP="/tmp/holo_dd_wrap/Build/Products/Debug-iphonesimulator/Holo.app"

STORY="story.json"; DO_BUILD=0; KEEP=0; VERIFY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --story)  STORY="$2"; shift 2 ;;
    --build)  DO_BUILD=1; shift ;;
    --keep)   KEEP=1; shift ;;
    --verify) VERIFY=1; shift ;;
    *) echo "未知参数 $1"; exit 2 ;;
  esac
done

STORY_PATH="$HERE/$STORY"
[[ -f "$STORY_PATH" ]] || { echo "▶ 生成 $STORY（不存在）"; python3 "$HERE/generate.py"; }

if [[ $DO_BUILD -eq 1 || ! -d "$APP" ]]; then
  echo "▶ 构建 Debug 包（holo_build.py）"
  (cd "$REPO_ROOT" && python3 BuildScripts/holo_build.py build)
fi

echo "▶ 开机（无头）"
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

echo "▶ 卸载旧包（保证幂等干净）→ 安装"
xcrun simctl uninstall "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

echo "▶ 拷入剧本 $STORY"
DOC="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)/Documents"
cp "$STORY_PATH" "$DOC/story.json"

echo "▶ 启动注入（zh-Hans，日志轮询注入完成标记）"
# SIMCTL_CHILD_ 变量必须用前缀形式设给 simctl 自己；放末尾会被当成 App 启动参数
SIMCTL_CHILD_HOLO_STORY_FILE=story.json \
xcrun simctl launch "$UDID" "$BUNDLE" -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN

# 轮询日志：注入完成 或 失败（最多 60s）
LOG_PRED='subsystem == "com.holo.app" AND category == "HoloStory"'
timeout_s=60; waited=0; result=""
while [[ $waited -lt $timeout_s ]]; do
  line=$(xcrun simctl spawn "$UDID" log show --last 30s --predicate "$LOG_PRED" --style compact 2>/dev/null \
         | grep -E '注入完成|注入失败' | tail -1 || true)
  if [[ -n "$line" ]]; then result="$line"; break; fi
  sleep 2; waited=$((waited+2))
done
if [[ -z "$result" ]]; then
  echo "❌ ${timeout_s}s 内未见注入完成/失败日志（App 可能启动失败，手动查日志）"; exit 1
fi
echo "$result"
[[ "$result" == *注入失败* ]] && exit 1

if [[ $VERIFY -eq 1 ]]; then
  echo "▶ sqlite 只读核对"
  DB="$(find "$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/containers/shared/AppGroup" \
        -name HoloDataModel.sqlite 2>/dev/null | head -1)"
  [[ -n "$DB" ]] || { echo "  ⚠ 未找到 App Group 库"; exit 1; }
  for t in ZTRANSACTION ZTHOUGHT ZTODOTASK ZHABIT ZHABITRECORD ZGOAL ZACCOUNT; do
    # 注意必须 mode=ro 而非 immutable=1：CoreData 走 WAL，immutable 读不到未 checkpoint 的数据
    n=$(sqlite3 "file:$DB?mode=ro" "SELECT COUNT(*) FROM $t;" 2>/dev/null || echo "?")
    printf '  %-14s %s\n' "$t" "$n"
  done
fi

if [[ $KEEP -ne 1 ]]; then
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  echo "✅ 注入完成（已退到后台，模拟器保持开机；拍摄用 --keep 保持前台）"
else
  echo "✅ 注入完成（App 保持运行，可直接截图/走查）"
fi
