#!/bin/bash
set -euo pipefail
task_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
task_output="$(mktemp -d /tmp/holo-motion-tests.XXXXXX)"
trap 'rm -rf "$task_output"' EXIT
swiftc -parse-as-library -module-cache-path "$task_output/module-cache" \
  "$task_root/Holo/Holo APP/Holo/Holo/Models/Motion/HoloMotionEventLedger.swift" \
  "$task_root/Holo/Holo APP/Holo/HoloTests/Services/Motion/HoloMotionEventLedgerStandaloneTests.swift" \
  -o "$task_output/motion-tests"
"$task_output/motion-tests"
