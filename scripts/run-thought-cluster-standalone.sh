#!/usr/bin/env bash
#
# run-thought-cluster-standalone.sh
# 新脉络候选簇引擎（V3 Phase 5）standalone 测试入口：swiftc 直编，
# 不依赖 HoloTests target / pbxproj（避开并行会话的工程文件在途改动）。
# 只测纯函数核心（聚类/内聚度/指纹）；discover 落库链路由模拟器端到端覆盖。
#
#   bash scripts/run-thought-cluster-standalone.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Holo/Holo APP/Holo/Holo"
OUT="/tmp/HoloTopicClusterStandalone"
mkdir -p "$OUT"

BIN="$OUT/ThoughtTopicClusterStandaloneTests"

swiftc -o "$BIN" \
  "$ROOT/Holo/Holo APP/Holo/HoloTests/Services/Thoughts/ThoughtTopicClusterStandaloneTests.swift" \
  "$APP/Services/AI/SemanticV3/ThoughtTopicClusterEngine.swift" \
  "$APP/Services/AI/SemanticV3/ThoughtSemanticCalibration.swift" \
  "$APP/Services/AI/SemanticV3/LocalSemanticIndex.swift" \
  "$APP/Services/AI/SemanticV3/FlatSemanticIndex.swift" \
  "$APP/Services/AI/SemanticV3/ThoughtSemanticStore.swift" \
  "$APP/Services/AI/SemanticV3/ThoughtSemanticFeatureFlags.swift" \
  "$APP/Services/Thoughts/ThoughtTopicLinkProjection.swift" \
  "$APP/Models/ThoughtTopicLink+CoreDataClass.swift" \
  "$APP/Models/Thought+CoreDataClass.swift" \
  "$APP/Models/Topic+CoreDataClass.swift" \
  "$APP/Models/ThoughtAttachment+CoreDataClass.swift" \
  "$APP/Models/ThoughtAttachment+CoreDataProperties.swift" \
  "$APP/Models/ThoughtReference+CoreDataClass.swift" \
  "$APP/Models/ThoughtTag+CoreDataClass.swift" \
  "$APP/Models/ThoughtTagAssignment+CoreDataClass.swift" \
  2>&1

"$BIN"
