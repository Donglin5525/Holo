#!/bin/bash
set -euo pipefail
chart_repo="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
chart_output="$(mktemp -d /tmp/holo-chart-tests.XXXXXX)"
trap 'rm -rf "$chart_output"' EXIT
swiftc -module-cache-path "$chart_output/cache" \
  "$chart_repo/Holo/Holo APP/Holo/Holo/Components/Charts/HoloChartGeometry.swift" \
  "$chart_repo/Holo/Holo APP/Holo/HoloTests/Components/HoloChartGeometryStandaloneTests.swift" \
  -o "$chart_output/chart-tests"
"$chart_output/chart-tests"
