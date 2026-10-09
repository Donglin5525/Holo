#!/bin/bash
set -euo pipefail
task_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
task_output="$(mktemp -d /tmp/holo-daily-replay-tests.XXXXXX)"
trap 'rm -rf "$task_output"' EXIT
swiftc -parse-as-library -module-cache-path "$task_output/module-cache" \
  "$task_root/Holo/Holo APP/Holo/Holo/Models/Calendar/DailyReplayPresentation.swift" \
  "$task_root/Holo/Holo APP/Holo/HoloTests/Services/Calendar/DailyReplayPresentationStandaloneTests.swift" \
  -o "$task_output/daily-replay-tests"
"$task_output/daily-replay-tests"
