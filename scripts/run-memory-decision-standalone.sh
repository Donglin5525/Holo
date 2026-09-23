#!/bin/bash
#
# run-memory-decision-standalone.sh
# 记忆低确认成本方案（2026-09-16）决策契约与基线 standalone 测试入口。
#
# 规则（对应 run-personal-context-standalone.sh 范式）：
#   - 每个套件显式列出「测试文件 + 依赖源文件」，禁止通配编译多个 @main。
#   - swiftc -D HOLO_MEMORY_STANDALONE 编译到 /tmp/HoloMemoryDecisionStandalone 后逐个执行。
#   - 退出码非 0 即失败；不得把「编译成功」当作「测试通过」。
#
# 用法：
#   bash scripts/run-memory-decision-standalone.sh              # 跑全部套件
#   bash scripts/run-memory-decision-standalone.sh Contract     # 只跑名称含 Contract 的套件
#

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Holo/Holo APP/Holo/Holo"
TESTS="$ROOT/Holo/Holo APP/Holo/HoloTests"
CACHE="/tmp/HoloMemoryDecisionModuleCache"
OUT="/tmp/HoloMemoryDecisionStandalone"
mkdir -p "$CACHE" "$OUT"

# ---------------------------------------------------------------------------
# 套件注册表：名称|测试文件|依赖源文件（逗号分隔）
# 路径含空格，因此用 | 做字段分隔、逗号做依赖分隔；新增套件在此登记。
# ---------------------------------------------------------------------------
BASE_MODELS="$APP/Models/AI/HoloMemoryRecord.swift,$APP/Models/AI/HoloMemoryEvidence.swift,$APP/Models/AI/HoloPersonalContextModels.swift,$APP/Models/AI/HoloLongTermMemoryModels.swift,$APP/Models/AI/HoloShortTermMemoryModels.swift,$APP/Services/AI/MemoryCore/HoloMemoryIdentity.swift"
FIXTURES="$TESTS/Services/AI/HoloMemoryFiveWayFixtures.swift"

MEMORY_POLICY_DEPS="$APP/Services/AI/MemoryCore/HoloMemoryActivationPolicy.swift,$APP/Services/AI/MemoryCore/HoloMemoryAttentionPolicy.swift,$APP/Services/AI/MemoryCore/HoloMemoryScorer.swift,$APP/Services/AI/MemoryCore/HoloSemanticTombstoneMatcher.swift,$APP/Services/AI/MemoryCore/HoloMemoryDecisionPolicy.swift,$APP/Services/AI/MemoryRepository/HoloMemoryRepository.swift,$APP/Services/AI/HoloMemoryFeedbackService.swift,$APP/Services/AI/MemoryRepository/HoloMemoryForgettingService.swift,$APP/Services/AI/MemoryDiagnostics/HoloMemoryDecisionBaselineSnapshot.swift"

SUITES=(
  "MemoryLowConfirmationBaseline|$TESTS/Services/AI/HoloMemoryLowConfirmationBaselineTests.swift|$FIXTURES,$BASE_MODELS,$MEMORY_POLICY_DEPS"
  "MemoryDecisionContract|$TESTS/Services/AI/HoloMemoryDecisionContractStandaloneTests.swift|$FIXTURES,$BASE_MODELS,$APP/Services/AI/MemoryCore/HoloMemoryDecisionPolicy.swift"
  "MemoryDecisionPolicyV4|$TESTS/Services/AI/HoloMemoryDecisionPolicyStandaloneTests.swift|$FIXTURES,$BASE_MODELS,$MEMORY_POLICY_DEPS,$APP/Services/AI/MemoryRepository/HoloMemoryCompactionService.swift"
  "MemoryClarification|$TESTS/Services/AI/HoloMemoryClarificationStandaloneTests.swift|$FIXTURES,$BASE_MODELS,$MEMORY_POLICY_DEPS,$APP/Services/AI/MemoryClarification/HoloMemoryClarificationModels.swift,$APP/Services/AI/MemoryClarification/HoloMemoryClarificationCoordinator.swift"
)

FILTER="${1:-}"
FAILED=()
RUN=0

for entry in "${SUITES[@]}"; do
  name="${entry%%|*}"
  rest="${entry#*|}"
  test_file="${rest%%|*}"
  deps_raw="${rest#*|}"

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
    echo "✅ [$name] 通过"
  else
    echo "❌ [$name] 断言失败"
    FAILED+=("$name")
  fi
done

echo "--------------------------------------------------"
if (( ${#FAILED[@]} )); then
  echo "失败套件（${#FAILED[@]}）：${FAILED[*]}"
  exit 1
fi
echo "standalone 全部通过（本轮执行 $RUN 个套件）"
