#!/bin/bash
# inject.sh — 自媒体模拟数据库的一键入口：生成 → 审查 → 灌进无头模拟器 → 停在干净的主页
#
# 用法：
#   ./inject.sh                 # 默认全套：重新生成 + 审查 + 注入，最后 App 停在主页可直接截图/录屏
#   ./inject.sh --no-gen        # 不重新生成，直接用现成的 story.json
#   ./inject.sh --story a.json  # 指定剧本文件名（须在脚本同目录）
#   ./inject.sh --build         # 先重新构建调试包（改了 HoloStorySeeder 等 App 代码后用）
#   ./inject.sh --verify        # 额外用 sqlite 只读核对各表行数
#
# 每次默认重新生成：剧本钉在真实日历上，「今天」的几笔记录按当前时刻决定写不写。
# 注入要启动一次 App；首启引导页在数据写完前就弹出来了，所以注入后自动再启动一次，
# 第二次启动直接是主页（注入口会标记引导与首页导览为已看过）。
set -euo pipefail

UDID="${UDID:-F9F5EDDE-EB22-4951-A876-532BC5C53687}"   # iPhone 17 (iOS 26.3)
BUNDLE="com.holo.Holo"
IDB=/opt/homebrew/bin/idb
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$HERE/../../../Holo/Holo APP/Holo"            # → Holo.xcodeproj 所在目录
APP="/tmp/holo_dd_wrap/Build/Products/Debug-iphonesimulator/Holo.app"
CLAIMS_MD="$HOME/Desktop/Claude/商业化/自媒体/Holo小红书/seed/口径锁定表.md"

STORY="story.json"; DO_GEN=1; DO_BUILD=0; VERIFY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-gen) DO_GEN=0; shift ;;
    --story)  STORY="$2"; shift 2 ;;
    --build)  DO_BUILD=1; shift ;;
    --verify) VERIFY=1; shift ;;
    --keep)   shift ;;                     # 兼容旧用法：现在默认就保持 App 运行
    *) echo "未知参数 $1"; exit 2 ;;
  esac
done

cd "$HERE"
if [[ $DO_GEN -eq 1 ]]; then
  echo "▶ 生成剧本（对账断言不过会直接退出）"
  python3 generate.py --claims-md "$CLAIMS_MD"
  echo "▶ 活人感审查"
  audit_out=$(python3 audit_taste.py "$STORY" || true)
  echo "$audit_out" | tail -1
  if [[ "$audit_out" != *"审查通过"* ]]; then
    echo "$audit_out" | grep "❌" || true
    echo "❌ 审查未通过，先修再注入"; exit 1
  fi
fi
[[ -f "$HERE/$STORY" ]] || { echo "找不到剧本 $STORY"; exit 1; }

if [[ $DO_BUILD -eq 1 || ! -d "$APP" ]]; then
  echo "▶ 构建 Debug 包"
  (cd "$REPO_ROOT" && python3 BuildScripts/holo_build.py build --dd /tmp/holo_dd_wrap)
fi

echo "▶ 开机（无头）→ 卸载旧包 → 安装 → 拷入剧本"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl uninstall "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
cp "$HERE/$STORY" "$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)/Documents/story.json"

echo "▶ 第一次启动：注入"
# SIMCTL_CHILD_ 变量必须用前缀形式设给 simctl 自己；放在命令末尾会被当成 App 的启动参数
SIMCTL_CHILD_HOLO_STORY_FILE=story.json \
  xcrun simctl launch "$UDID" "$BUNDLE" -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN >/dev/null
result=""; waited=0
while [[ $waited -lt 120 ]]; do
  result=$(xcrun simctl spawn "$UDID" log show --last 2m --predicate 'subsystem == "com.holo.app" AND category == "HoloStory"' \
           --style compact 2>/dev/null | grep -E '注入完成|注入失败' | tail -1 || true)
  [[ -n "$result" ]] && break
  sleep 2; waited=$((waited+2))
done
[[ -n "$result" ]] || { echo "❌ 120 秒内没等到注入日志，查：xcrun simctl spawn $UDID log show --last 3m --predicate 'category == \"HoloStory\"'"; exit 1; }
echo "${result#*HoloStory] }"
[[ "$result" == *注入完成* ]] || exit 1

# 状态栏设成真实的当前时间：今天的账是按此刻之前补齐的，时钟必须对得上
xcrun simctl status_bar "$UDID" override --time "$(date +%H:%M)" --batteryLevel 100 --batteryState charged \
  --wifiBars 3 --cellularBars 4 >/dev/null 2>&1 || true
echo "▶ 第二次启动：直达主页"
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
sleep 1
xcrun simctl launch "$UDID" "$BUNDLE" -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN >/dev/null
sleep 5
xcrun simctl status_bar "$UDID" override --time "$(date +%H:%M)" --batteryLevel 100 --batteryState charged --wifiBars 3 --cellularBars 4 >/dev/null 2>&1 || true
page=$($IDB ui describe-all --udid "$UDID" 2>/dev/null || true)
if [[ "$page" == *"小满"* && "$page" != *"跳过导览"* && "$page" != *"跳过引导"* ]]; then
  echo "✅ 已停在主页，无引导遮挡，可以直接截图/录屏"
else
  echo "⚠ 主页上还有引导或导览，需要手动点一下「跳过」"
fi

if [[ $VERIFY -eq 1 ]]; then
  echo "▶ sqlite 只读核对"
  # 必须是 mode=ro 而不是 immutable=1：CoreData 走 WAL，immutable 读不到还没并进主库的数据
  DB="$(find "$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/containers/shared/AppGroup" \
        -name HoloDataModel.sqlite 2>/dev/null | head -1)"
  [[ -n "$DB" ]] || { echo "  ⚠ 未找到 App Group 库"; exit 1; }
  for t in ZTRANSACTION ZTHOUGHT ZTODOTASK ZHABIT ZHABITRECORD ZGOAL ZACCOUNT ZFINANCEPROJECT; do
    printf '  %-16s %s\n' "$t" "$(sqlite3 "file:$DB?mode=ro" "SELECT COUNT(*) FROM $t;" 2>/dev/null || echo '?')"
  done
fi
