#!/usr/bin/env bash
#
# run-cross-domain-fusion-standalone.sh
# R04 记忆锚点折叠回归 standalone 入口（swiftc 直编，不挂 pbxproj）。
# 依赖清单与体检探针 reproduce-probes.py 的 fusion_deps 保持一致。
#
#   bash scripts/run-cross-domain-fusion-standalone.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Holo/Holo APP/Holo/Holo"
OUT="/tmp/HoloCrossDomainFusionStandalone"
mkdir -p "$OUT"

BIN="$OUT/HoloCrossDomainCandidateBuilderSafetyStandaloneTests"

swiftc -module-cache-path "$OUT/module-cache" -D HOLO_MEMORY_STANDALONE -o "$BIN" \
  "$ROOT/Holo/Holo APP/Holo/HoloTests/Services/AI/HoloCrossDomainCandidateBuilderSafetyStandaloneTests.swift" \
  "$APP/Models/AI/HoloMemoryRecord.swift" \
  "$APP/Models/AI/HoloMemoryEvidence.swift" \
  "$APP/Models/AI/HoloPersonalContextModels.swift" \
  "$APP/Models/AI/HoloLongTermMemoryModels.swift" \
  "$APP/Models/AI/HoloShortTermMemoryModels.swift" \
  "$APP/Services/AI/MemoryCore/HoloMemoryIdentity.swift" \
  "$APP/Services/AI/MemoryCore/HoloMemoryDecisionPolicy.swift" \
  "$APP/Services/AI/MemoryCore/HoloMemoryActivationPolicy.swift" \
  "$APP/Services/AI/MemoryCore/HoloMemoryAttentionPolicy.swift" \
  "$APP/Services/AI/MemoryCore/HoloMemoryScorer.swift" \
  "$APP/Services/AI/MemoryFusion/HoloEvidenceLineageResolver.swift" \
  "$APP/Services/AI/MemoryFusion/HoloCrossDomainCandidateBuilder.swift" \
  2>&1

"$BIN"
