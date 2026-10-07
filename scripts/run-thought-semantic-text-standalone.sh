#!/usr/bin/env bash
# 长正文、UTF-16 证据范围与用户开关回归。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Holo/Holo APP/Holo/Holo"
OUT="/tmp/HoloSemanticTextStandalone"
mkdir -p "$OUT"
swiftc -module-cache-path "$OUT/module-cache" -o "$OUT/tests" \
  "$APP/Services/AI/SemanticV3/ThoughtSemanticText.swift" \
  "$APP/Services/AI/SemanticV3/ThoughtSemanticFeatureFlags.swift" \
  "$ROOT/Holo/Holo APP/Holo/HoloTests/Services/AI/SemanticV3/ThoughtSemanticTextStandaloneTests.swift"
"$OUT/tests"
