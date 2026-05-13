#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:8787}"
AUDIO_FILE="${2:-}"
DEVICE_ID="smoke-$(date +%s)"

echo "Health: ${BASE_URL}/v1/health"
curl -fsS "${BASE_URL}/v1/health"
echo

echo "Chat non-streaming"
curl -fsS -X POST "${BASE_URL}/v1/ai/chat/completions" \
  -H 'content-type: application/json' \
  -H "x-holo-device-id: ${DEVICE_ID}" \
  -d '{"purpose":"chat","stream":false,"messages":[{"role":"user","content":"请只回复 Holo smoke OK"}]}'
echo

echo "Chat streaming"
curl -fsS -N -X POST "${BASE_URL}/v1/ai/chat/completions" \
  -H 'content-type: application/json' \
  -H "x-holo-device-id: ${DEVICE_ID}-stream" \
  -d '{"purpose":"chat","stream":true,"messages":[{"role":"user","content":"请只回复 stream smoke OK"}]}' \
  | sed -n '1,8p'
echo

if [[ -n "${AUDIO_FILE}" ]]; then
  echo "ASR transcription"
  curl -fsS -X POST "${BASE_URL}/v1/asr/transcriptions" \
    -H "x-holo-device-id: ${DEVICE_ID}-asr" \
    -F "audio=@${AUDIO_FILE}" \
    -F 'locale=zh-CN'
  echo
else
  echo "ASR skipped: pass a wav file path as the second argument."
fi
