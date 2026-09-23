#!/bin/bash
#
# run-personal-context-standalone.sh
# 通用个人情境（PersonalContext）standalone 测试统一入口。
#
# 规则（对应实施方案 15.4）：
#   - 每个套件显式列出「测试文件 + 依赖源文件」，禁止通配编译多个 @main。
#   - swiftc -D HOLO_MEMORY_STANDALONE -module-cache-path /tmp/HoloContextModuleCache
#     编译到 /tmp/HoloContextStandalone 后逐个执行。
#   - 退出码非 0 即失败；不得把「编译成功」当作「测试通过」。
#
# 用法：
#   bash scripts/run-personal-context-standalone.sh              # 跑全部套件
#   bash scripts/run-personal-context-standalone.sh Controls     # 只跑名称含 Controls 的套件
#

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Holo/Holo APP/Holo/Holo"
TESTS="$ROOT/Holo/Holo APP/Holo/HoloTests"
CACHE="/tmp/HoloContextModuleCache"
OUT="/tmp/HoloContextStandalone"
mkdir -p "$CACHE" "$OUT"

# ---------------------------------------------------------------------------
# 套件注册表：名称|测试文件|依赖源文件（逗号分隔）|expectedRed（可选）
# 路径含空格，因此用 | 做字段分隔、逗号做依赖分隔；新增套件在此登记。
# expectedRed：R0 冻结的已知缺陷红测（断言失败=预期红，不挡其他套件全绿；
# 修复转绿时须移除该标记并人工确认，再挂 XCTest 桥接）。
# ---------------------------------------------------------------------------
PC_MODELS="$APP/Models/AI/HoloPersonalContextModels.swift"
PC_RECORD_DEPS="$APP/Models/AI/HoloMemoryRecord.swift,$APP/Models/AI/HoloLongTermMemoryModels.swift,$APP/Models/AI/HoloShortTermMemoryModels.swift,$APP/Models/AI/HoloMemoryEvidence.swift,$APP/Services/AI/MemoryCore/HoloMemoryIdentity.swift,$APP/Services/AI/MemoryCore/HoloMemoryDecisionPolicy.swift"

PC_EXTRACT_DEPS="$APP/Services/AI/PersonalContext/HoloContextSourceReader.swift,$APP/Services/AI/PersonalContext/HoloPersonalContextValidator.swift,$APP/Services/AI/PersonalContext/HoloContextReconciler.swift,$APP/Services/AI/PersonalContext/HoloPersonalContextExtractor.swift"
PC_RETRIEVAL_DEPS="$APP/Models/AI/HoloContextPlanningModels.swift,$APP/Services/AI/PersonalContext/HoloContextTemporalResolver.swift,$APP/Services/AI/PersonalContext/HoloContextEmbeddingStore.swift,$APP/Services/AI/PersonalContext/HoloContextRetrievalService.swift,$APP/Services/AI/PersonalContext/HoloContextSourceReader.swift"
PC_PLAN_DEPS="$APP/Services/AI/PersonalContext/HoloContextPlanValidator.swift,$APP/Services/AI/PersonalContext/HoloContextPlanningCoordinator.swift,$PC_EXTRACT_DEPS,$APP/Services/AI/MemoryRepository/HoloMemoryRepository.swift,$APP/Services/AI/MemoryCore/HoloSemanticTombstoneMatcher.swift,$APP/Services/AI/MemoryClarification/HoloMemoryClarificationModels.swift,$APP/Services/AI/MemoryClarification/HoloMemoryClarificationCoordinator.swift,$APP/Models/HoloMemoryManagedObjects.swift"

SUITES=(
  "PersonalContextControls|$TESTS/Services/AI/PersonalContext/HoloPersonalContextControlsStandaloneTests.swift|$APP/Models/AI/HoloPersonalContextControls.swift"
  "PersonalContextCodable|$TESTS/Services/AI/PersonalContext/PersonalContextCodableStandaloneTests.swift|$PC_MODELS,$PC_RECORD_DEPS,$APP/Services/AI/PersonalContext/HoloPersonalContextValidator.swift,$APP/Services/AI/PersonalContext/HoloContextSourceReader.swift"
  "PersonalContextIdentity|$TESTS/Services/AI/PersonalContext/PersonalContextIdentityStandaloneTests.swift|$PC_MODELS,$PC_RECORD_DEPS"
  "ContextAccess|$TESTS/Services/AI/PersonalContext/ContextAccessStandaloneTests.swift|$PC_MODELS,$PC_RECORD_DEPS,$APP/Models/AI/HoloPersonalContextControls.swift,$APP/Services/AI/PersonalContext/HoloContextAccessPolicy.swift,$APP/Services/AI/MemoryCore/HoloSemanticTombstoneMatcher.swift,$APP/Services/AI/MemoryRepository/HoloMemoryRepository.swift"
  "ContextExtraction|$TESTS/Services/AI/PersonalContext/ContextExtractionStandaloneTests.swift|$PC_MODELS,$PC_RECORD_DEPS,$PC_EXTRACT_DEPS,$APP/Services/AI/MemoryRepository/HoloMemoryRepository.swift,$APP/Services/AI/MemoryCore/HoloSemanticTombstoneMatcher.swift"
  "ExtractorOrchestrator|$TESTS/Services/AI/PersonalContext/ContextExtractorOrchestratorStandaloneTests.swift|$PC_MODELS,$PC_RECORD_DEPS,$PC_EXTRACT_DEPS,$APP/Services/AI/MemoryRepository/HoloMemoryRepository.swift,$APP/Services/AI/MemoryCore/HoloSemanticTombstoneMatcher.swift"
  "ContextRetrieval|$TESTS/Services/AI/PersonalContext/ContextRetrievalStandaloneTests.swift|$PC_MODELS,$PC_RECORD_DEPS,$PC_RETRIEVAL_DEPS,$APP/Services/AI/PersonalContext/HoloContextAccessPolicy.swift,$APP/Models/AI/HoloPersonalContextControls.swift,$APP/Services/AI/PersonalContext/HoloPersonalContextValidator.swift"
  "LifeUnderstandingRed|$TESTS/Services/AI/PersonalContext/HoloLifeUnderstandingRedTests.swift|$TESTS/Services/AI/PersonalContext/Fixtures/HoloLifeUnderstandingFixtures.swift,$PC_MODELS,$PC_RECORD_DEPS,$PC_RETRIEVAL_DEPS,$APP/Services/AI/PersonalContext/HoloContextAccessPolicy.swift,$APP/Models/AI/HoloPersonalContextControls.swift,$APP/Services/AI/PersonalContext/HoloPersonalContextValidator.swift"
  "LifeUnderstandingRelation|$TESTS/Services/AI/PersonalContext/HoloLifeUnderstandingRelationTests.swift|$PC_MODELS,$PC_RECORD_DEPS,$PC_EXTRACT_DEPS,$APP/Services/AI/MemoryRepository/HoloMemoryRepository.swift,$APP/Services/AI/MemoryCore/HoloSemanticTombstoneMatcher.swift,$APP/Services/AI/MemoryCore/HoloMemoryDecisionPolicy.swift"
  "LifeUnderstandingContinuation|$TESTS/Services/AI/PersonalContext/HoloLifeUnderstandingContinuationTests.swift|$APP/Services/AI/PersonalContext/HoloLifePlanRequirement.swift,$PC_MODELS,$PC_RECORD_DEPS"
  "ContextPlan|$TESTS/Services/AI/PersonalContext/ContextPlanStandaloneTests.swift|$PC_MODELS,$PC_RECORD_DEPS,$PC_RETRIEVAL_DEPS,$PC_PLAN_DEPS,$APP/Services/AI/PersonalContext/HoloContextAccessPolicy.swift,$APP/Models/AI/HoloPersonalContextControls.swift,$APP/Services/AI/PersonalContext/HoloContextPlanExecutionAdapter.swift"
  "ChatTaskGroup|$TESTS/Services/AI/PersonalContext/ChatTaskGroupStandaloneTests.swift|$APP/Services/AI/TaskGroupMergePlanner.swift,$APP/Services/AI/HoloMemoryAttributionReconciler.swift"
)

FILTER="${1:-}"
FAILED=()
RUN=0

for entry in "${SUITES[@]}"; do
  name="${entry%%|*}"
  rest="${entry#*|}"
  test_file="${rest%%|*}"
  deps_raw="${rest#*|}"

  # 可选第 4 字段 expectedRed（R0 冻结红测标记）。
  expected_red=0
  if [[ "$deps_raw" == *"|"* ]]; then
    flag="${deps_raw##*|}"
    deps_raw="${deps_raw%|*}"
    if [[ "$flag" == "expectedRed" ]]; then
      expected_red=1
    else
      echo "❌ $name：未知套件标记「$flag」（当前仅支持 expectedRed）"
      FAILED+=("$name")
      continue
    fi
  fi

  if [[ -n "$FILTER" && "$name" != *"$FILTER"* ]]; then
    continue
  fi

  if [[ ! -f "$test_file" ]]; then
    echo "❌ $name：测试文件不存在 $test_file"
    FAILED+=("$name")
    continue
  fi

  bin="$OUT/$name"
  deps=()
  skip_suite=0
  IFS=',' read -ra parts <<< "$deps_raw"
  for part in "${parts[@]}"; do
    dep="${part#"${part%%[![:space:]]*}"}"
    [[ -z "$dep" ]] && continue
    if [[ ! -f "$dep" ]]; then
      echo "❌ $name：依赖源文件不存在 $dep"
      FAILED+=("$name")
      skip_suite=1
      break
    fi
    deps+=("$dep")
  done
  (( skip_suite )) && continue

  # 套件依赖组合可能经变量嵌套重复同一文件（swiftc 对重复文件名报错），去重保序
  # （bash 3.2 兼容：不用 mapfile/关联数组）
  seen_list=","
  uniq_deps=()
  for d in "${deps[@]}"; do
    case "$seen_list" in
      *",$d,"*) ;;
      *) seen_list="$seen_list$d,"; uniq_deps+=("$d") ;;
    esac
  done
  deps=("${uniq_deps[@]}")

  echo "==> [$name] swiftc 编译（依赖 ${#deps[@]} 个源文件）"
  if ! swiftc -D HOLO_MEMORY_STANDALONE -module-cache-path "$CACHE" \
       -o "$bin" "$test_file" "${deps[@]}" 2> "$OUT/$name.build.log"; then
    echo "❌ [$name] 编译失败（日志 $OUT/$name.build.log）："
    tail -20 "$OUT/$name.build.log"
    FAILED+=("$name")
    continue
  fi

  RUN=$((RUN + 1))
  if "$bin"; then
    if (( expected_red )); then
      echo "⚠️ [$name] 红测转绿——确认对应修复已实施后，移除 expectedRed 标记并挂 XCTest 桥接"
    fi
    echo "✅ [$name] 通过"
  else
    if (( expected_red )); then
      echo "🔴 [$name] 预期红（R0 冻结缺陷；修复转绿后移除 expectedRed 标记）"
    else
      echo "❌ [$name] 断言失败"
      FAILED+=("$name")
    fi
  fi
done

echo "--------------------------------------------------"
if (( ${#FAILED[@]} )); then
  echo "失败套件（${#FAILED[@]}）：${FAILED[*]}"
  exit 1
fi
echo "standalone 全部通过（本轮执行 $RUN 个套件）"
