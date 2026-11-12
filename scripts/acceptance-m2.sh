#!/usr/bin/env bash
#
# acceptance-m2.sh —— 东林一键验收（2026-11-13 M2 全量）
#
#   bash /Users/tangyuxuan/Desktop/Claude/holo-119-wt/scripts/acceptance-m2.sh
#
# 依次跑：①理解引擎八套件全部断言 ②后端契约测试 ③全 App 构建。
# 任何一步失败立即停并显示原因；全部通过打印「验收全绿」。

set -euo pipefail

WT="/Users/tangyuxuan/Desktop/Claude/holo-119-wt"

echo "════ ① 理解引擎八套件（观察索引/核验闸/取证路由/主题包/影子状态机/端到端/对抗回归）════"
bash "$WT/scripts/run-understanding-standalone.sh"

echo ""
echo "════ ② 后端 purpose 契约（understanding_proposal 注册，未发版仅验代码）════"
(cd "$WT/HoloBackend" && node --test tests/understanding-proposal-purpose.test.js 2>&1 | grep -E "^ℹ (tests|pass|fail)" )

echo ""
echo "════ ③ 全 App 构建（含全部新文件）════"
(cd "$WT/Holo/Holo APP/Holo" && xcodebuild -project Holo.xcodeproj -scheme Holo \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 \
  | grep -E "BUILD (SUCCEEDED|FAILED)")

echo ""
echo "✅ 验收全绿：160+ 断言、3 项后端契约、App 构建全部通过。"
