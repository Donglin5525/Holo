#!/usr/bin/env bash
#
# run-thought-semantic-store-standalone.sh
# V3 Phase 2 本机语义库 standalone 测试入口（swiftc 直编，不挂 pbxproj）。
#
#   bash scripts/run-thought-semantic-store-standalone.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Holo/Holo APP/Holo/Holo"
OUT="/tmp/HoloSemanticStoreStandalone"
mkdir -p "$OUT"

BIN="$OUT/ThoughtSemanticStoreStandaloneTests"

swiftc -o "$BIN" \
  "$ROOT/Holo/Holo APP/Holo/HoloTests/Services/AI/SemanticV3/ThoughtSemanticStoreStandaloneTests.swift" \
  "$APP/Services/AI/SemanticV3/LocalSemanticIndex.swift" \
  "$APP/Services/AI/SemanticV3/FlatSemanticIndex.swift" \
  "$APP/Services/AI/SemanticV3/ThoughtSemanticStore.swift" \
  "$APP/Services/AI/SemanticV3/ThoughtSemanticFeatureFlags.swift" \
  2>&1

"$BIN"
