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

# C1 测试引入 ThoughtSemanticRetryPolicy；其引用的执行器错误类型所在的
# Executor/Verifier 文件依赖链过重，用最小 stub 满足类型解析（真类型定义
# 与 stub 无行为耦合，RetryPolicy 只做 `is` 判断）。
cat > "$OUT/RetryPolicyStubs.swift" <<'SWIFT'
import Foundation
enum ThoughtTopicVerifierError: Error { case stub }
enum ThoughtSemanticExecutorError: Error { case stub }
SWIFT

swiftc -module-cache-path "$OUT/module-cache" -o "$BIN" \
  "$ROOT/Holo/Holo APP/Holo/HoloTests/Services/AI/SemanticV3/ThoughtSemanticStoreStandaloneTests.swift" \
  "$APP/Services/AI/SemanticV3/LocalSemanticIndex.swift" \
  "$APP/Services/AI/SemanticV3/FlatSemanticIndex.swift" \
  "$APP/Services/AI/SemanticV3/ThoughtSemanticStore.swift" \
  "$APP/Services/AI/SemanticV3/ThoughtSemanticFeatureFlags.swift" \
  "$APP/Services/AI/SemanticV3/ThoughtSemanticRetryPolicy.swift" \
  "$APP/Services/Network/APIError.swift" \
  "$OUT/RetryPolicyStubs.swift" \
  2>&1

"$BIN"
