#!/bin/bash
# 真机构建安装启动脚本（2026-10-25 设立）
# 背景：真机/模拟器 bundle id 分裂坑两次踩（见记忆 device-bundleid-split-trap）——
# launch 用模拟器 ID 报 -10814 浪费整轮。此脚本把关键参数固化，调用方不再依赖记忆。
#
# 用法：
#   scripts/device-install-launch.sh install <app路径>   # 构建产物安装到东林 iPhone
#   scripts/device-install-launch.sh launch              # 启动 App
#   scripts/device-install-launch.sh log <秒数>           # 抓设备 syslog 中 App 关键行
#
# 设备与 bundle ID 真源：东林 iPhone 17 Pro（CE79FF1A-…）装 com.tangyuxuan.holo-app；
# 模拟器才是 com.holo.Holo。改设备/改 ID 先更新此处并同步记忆档。

set -euo pipefail

DEVICE_UDID="CE79FF1A-CB1E-52BA-9FC2-C76A051B5D1F"
BUNDLE_ID="com.tangyuxuan.holo-app"

ACTION="${1:-}"
case "$ACTION" in
  install)
    APP="${2:?用法: $0 install <app路径>}"
    echo "▸ 核对产物 bundle id（防止装错包）："
    FOUND=$(plutil -extract CFBundleIdentifier raw "$APP/Info.plist")
    if [ "$FOUND" != "$BUNDLE_ID" ]; then
      echo "✗ 产物 bundle id=$FOUND 与预期 $BUNDLE_ID 不符，拒绝安装"; exit 1
    fi
    echo "✓ $FOUND"
    xcrun devicectl device install app --device "$DEVICE_UDID" "$APP"
    ;;
  launch)
    xcrun devicectl device process launch --terminate-existing \
      --device "$DEVICE_UDID" "$BUNDLE_ID"
    ;;
  log)
    SECS="${2:-60}"
    python3 -m pymobiledevice3 syslog live 2>/dev/null | \
      grep --line-buffered -iE "SchemaInit|CloudKit setup|Fatal|Holo\{" | head -100 &
    PID=$!
    xcrun devicectl device process launch --terminate-existing \
      --device "$DEVICE_UDID" "$BUNDLE_ID" >/dev/null
    sleep "$SECS"
    kill "$PID" 2>/dev/null || true
    ;;
  *)
    echo "用法: $0 install <app路径> | launch | log <秒数>"; exit 1
    ;;
esac
