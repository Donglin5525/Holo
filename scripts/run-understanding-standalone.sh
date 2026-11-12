#!/usr/bin/env bash
#
# run-understanding-standalone.sh
# 理解引擎 M2 standalone 测试入口（swiftc 直编，不挂 pbxproj）。
#
#   bash scripts/run-understanding-standalone.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Holo/Holo APP/Holo/Holo"
OUT="/tmp/HoloUnderstandingStandalone"
mkdir -p "$OUT"

BIN="$OUT/UnderstandingM21StandaloneTests"

swiftc -module-cache-path "$OUT/module-cache" -o "$BIN" \
  "$ROOT/Holo/Holo APP/Holo/HoloTests/Services/AI/Understanding/UnderstandingStandaloneRunner.swift" \
  "$ROOT/Holo/Holo APP/Holo/HoloTests/Services/AI/Understanding/UnderstandingM21StandaloneTests.swift" \
  "$ROOT/Holo/Holo APP/Holo/HoloTests/Services/AI/Understanding/ProposalGateStandaloneTests.swift" \
  "$ROOT/Holo/Holo APP/Holo/HoloTests/Services/AI/Understanding/EvidenceRouterStandaloneTests.swift" \
  "$APP/Services/AI/Understanding/EvidenceRouter.swift" \
  "$APP/Services/AI/Understanding/ThemeIndex.swift" \
  "$APP/Services/AI/Understanding/ShadowRuntime.swift" \
  "$ROOT/Holo/Holo APP/Holo/HoloTests/Services/AI/Understanding/ShadowRuntimeStandaloneTests.swift" \
  "$APP/Services/AI/Understanding/ShadowReviewExporter.swift" \
  "$ROOT/Holo/Holo APP/Holo/HoloTests/Services/AI/Understanding/EndToEndStandaloneTests.swift" \
  "$ROOT/Holo/Holo APP/Holo/HoloTests/Services/AI/Understanding/AdversarialRegressionTests.swift" \
  "$ROOT/Holo/Holo APP/Holo/HoloTests/Services/AI/Understanding/ThemeIndexStandaloneTests.swift" \
  "$APP/Services/AI/Understanding/ProposalGate.swift" \
  "$APP/Services/AI/Understanding/LifeObservation.swift" \
  "$APP/Services/AI/Understanding/DomainCapability.swift" \
  "$APP/Services/AI/Understanding/ObservationProjectors.swift" \
  "$APP/Services/AI/Understanding/ObservationIndex.swift" \
  2>&1

"$BIN"
