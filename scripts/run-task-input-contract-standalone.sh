#!/usr/bin/env bash
#
# run-task-input-contract-standalone.sh
# R05/R06 任务输入验证契约 standalone 入口（swiftc 直编，不挂 pbxproj）。
#
#   bash scripts/run-task-input-contract-standalone.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Holo/Holo APP/Holo/Holo"
OUT="/tmp/HoloTaskInputContractStandalone"
mkdir -p "$OUT"

BIN="$OUT/TaskInputContractStandaloneTests"

swiftc -module-cache-path "$OUT/module-cache" -o "$BIN" \
  "$ROOT/Holo/Holo APP/Holo/HoloTests/Models/TaskInputContractStandaloneTests.swift" \
  "$APP/Models/TaskInputContract.swift" \
  "$APP/Models/Weekday.swift" \
  2>&1

"$BIN"
