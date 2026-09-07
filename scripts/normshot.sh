#!/bin/bash
# 用法: normshot.sh <png> [--ocr] [rot度数，默认270]
f="$1"; shift
rot=270; ocr=""
for a in "$@"; do
  if [ "$a" = "--ocr" ]; then ocr="--ocr"; else rot="$a"; fi
done
out="${f%.png}-land.png"
sips -r $rot "$f" --out "$out" >/dev/null 2>&1
/tmp/holo_ipad_audit/analyze_layout "$out" $ocr
