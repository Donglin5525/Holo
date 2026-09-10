#!/usr/bin/env bash
#
# run-thought-topic-link-standalone.sh
# 想法-主题显式关系（V3 Phase 1）standalone 测试入口：swiftc 直编，
# 不依赖 HoloTests target / pbxproj（避开并行会话的工程文件在途改动）。
#
#   bash scripts/run-thought-topic-link-standalone.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Holo/Holo APP/Holo/Holo"
OUT="/tmp/HoloTopicLinkStandalone"
mkdir -p "$OUT"

BIN="$OUT/ThoughtTopicLinkProjectionStandaloneTests"

swiftc -o "$BIN" \
  "$ROOT/Holo/Holo APP/Holo/HoloTests/Services/Thoughts/ThoughtTopicLinkProjectionStandaloneTests.swift" \
  "$APP/Models/ThoughtTopicLink+CoreDataClass.swift" \
  "$APP/Services/Thoughts/ThoughtTopicLinkProjection.swift" \
  "$APP/Models/Thought+CoreDataClass.swift" \
  "$APP/Models/Topic+CoreDataClass.swift" \
  "$APP/Models/ThoughtAttachment+CoreDataClass.swift" \
  "$APP/Models/ThoughtAttachment+CoreDataProperties.swift" \
  "$APP/Models/ThoughtReference+CoreDataClass.swift" \
  "$APP/Models/ThoughtTag+CoreDataClass.swift" \
  "$APP/Models/ThoughtTagAssignment+CoreDataClass.swift" \
  2>&1

"$BIN"
