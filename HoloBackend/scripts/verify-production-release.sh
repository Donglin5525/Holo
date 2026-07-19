#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-${1:-https://api.holoapp.cn}}"
PROMPT_TYPE="${PROMPT_TYPE:-intent_recognition}"
EXPECT_PROMPT_VERSION="${EXPECT_PROMPT_VERSION:-}"
EXPECT_PROMPT_CONTAINS="${EXPECT_PROMPT_CONTAINS:-transactionDate,reminderDate,query_analysis}"
SKIP_INTENT_CASES="${SKIP_INTENT_CASES:-0}"
ADMIN_TOKEN="${HOLO_ADMIN_TOKEN:-}"
REPORT_PATH="${REPORT_PATH:-${TMPDIR:-/tmp}/holo-release-verification-$(date +%Y%m%d-%H%M%S).md}"
DEVICE_PREFIX="release-verify-$(date +%s)"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 127
  fi
}

append_report() {
  printf '%s\n' "$*" >> "$REPORT_PATH"
}

run_step() {
  local title="$1"
  shift

  echo "==> $title"
  append_report ""
  append_report "## $title"
  append_report ""

  if "$@" > "$TMP_DIR/step.out" 2> "$TMP_DIR/step.err"; then
    append_report "Status: PASS"
    if [[ -s "$TMP_DIR/step.out" ]]; then
      append_report ""
      append_report '```'
      sed -n '1,80p' "$TMP_DIR/step.out" >> "$REPORT_PATH"
      append_report '```'
    fi
  else
    append_report "Status: FAIL"
    append_report ""
    append_report '```'
    sed -n '1,120p' "$TMP_DIR/step.err" >> "$REPORT_PATH"
    append_report '```'
    echo "Step failed: $title" >&2
    sed -n '1,120p' "$TMP_DIR/step.err" >&2
    exit 1
  fi
}

curl_json() {
  local url="$1"
  local output="$2"
  curl -fsS "$url" -o "$output"
  node -e 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));' "$output"
}

check_health() {
  local output="$TMP_DIR/health.json"
  curl_json "$BASE_URL/v1/health" "$output"
  node - "$output" <<'NODE'
const fs = require("node:fs");
const health = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (health.ok !== true || health.service !== "holo-ai-gateway") {
  throw new Error(`unexpected health payload: ${JSON.stringify(health)}`);
}
console.log(JSON.stringify(health, null, 2));
NODE
}

check_release_status() {
  local output="$TMP_DIR/release-status.json"
  curl_json "$BASE_URL/v1/release/status" "$output"
  node - "$output" "$PROMPT_TYPE" <<'NODE'
const fs = require("node:fs");
const [, , path] = process.argv;
const status = JSON.parse(fs.readFileSync(path, "utf8"));
if (status.ok !== true || status.service !== "holo-ai-gateway") {
  throw new Error(`unexpected release status payload: ${JSON.stringify(status).slice(0, 500)}`);
}
for (const field of ["commit", "sourceDigest", "buildTime"]) {
  const value = status.release?.[field];
  if (!value || value === "unknown") throw new Error(`release identity missing ${field}`);
}
for (const field of ["prompts", "routes", "database"]) {
  if (Object.prototype.hasOwnProperty.call(status, field)) throw new Error(`public release status exposes ${field}`);
}
console.log(JSON.stringify(status, null, 2));
NODE
}

check_admin_release_status() {
  local output="$TMP_DIR/admin-release-status.json"
  curl -fsS -H "x-holo-admin-token: $ADMIN_TOKEN" "$BASE_URL/v1/admin/release/status" -o "$output"
  node -e 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));' "$output"
  node - "$output" "$PROMPT_TYPE" "$EXPECT_PROMPT_VERSION" "$EXPECT_PROMPT_CONTAINS" <<'NODE'
const fs = require("node:fs");
const [, , path, promptType, expectedVersion, expectedList] = process.argv;
const status = JSON.parse(fs.readFileSync(path, "utf8"));
if (status.security?.agentStepIdempotencyResponseEncryption !== "aes-256-gcm-v1") {
  throw new Error(`agent step response encryption is not active: ${JSON.stringify(status.security)}`);
}
const prompt = (status.prompts || []).find((item) => item.type === promptType);
if (!prompt) throw new Error(`admin release status missing prompt: ${promptType}`);
if (expectedVersion && String(prompt.version) !== String(expectedVersion)) {
  throw new Error(`expected ${promptType} v${expectedVersion}, got v${prompt.version}`);
}
if (!prompt.content || typeof prompt.content !== "string") {
  throw new Error("prompt content is missing");
}
const missing = expectedList.split(",").map((item) => item.trim()).filter(Boolean).filter((item) => !prompt.content.includes(item));
if (missing.length > 0) {
  throw new Error(`prompt is missing expected text: ${missing.join(", ")}`);
}
console.log(JSON.stringify({
  type: prompt.type,
  version: prompt.version,
  source: prompt.source,
  updatedAt: prompt.updatedAt,
  contentLength: prompt.content.length,
  expectedText: expectedList,
  intentRoute: status.routes?.intent,
  database: status.database,
  security: status.security,
}, null, 2));
NODE
}

make_intent_payload() {
  local user_input="$1"
  local payload_file="$TMP_DIR/payload.json"

  node - "$user_input" "$payload_file" <<'NODE'
const fs = require("node:fs");
const [, , userInput, payloadPath] = process.argv;
const payload = {
  purpose: "intent",
  stream: false,
  response_format: { type: "json_object" },
  messages: [{ role: "user", content: userInput }],
};
fs.writeFileSync(payloadPath, JSON.stringify(payload));
NODE

  printf '%s' "$payload_file"
}

check_intent_case() {
  local name="$1"
  local user_input="$2"
  local expected_intent="$3"
  local expected_field="$4"
  local response_file="$TMP_DIR/intent-$name.json"
  local payload_file
  payload_file="$(make_intent_payload "$user_input")"

  curl -fsS -X POST "$BASE_URL/v1/ai/chat/completions" \
    -H 'content-type: application/json' \
    -H "x-holo-device-id: $DEVICE_PREFIX-$name" \
    --data-binary "@$payload_file" \
    -o "$response_file"

  node - "$response_file" "$expected_intent" "$expected_field" <<'NODE'
const fs = require("node:fs");
const [, , path, expectedIntent, expectedField] = process.argv;
const response = JSON.parse(fs.readFileSync(path, "utf8"));
const content = response?.choices?.[0]?.message?.content;
if (!content) throw new Error(`missing choices[0].message.content: ${JSON.stringify(response).slice(0, 500)}`);
let parsed;
try {
  parsed = JSON.parse(content);
} catch (error) {
  throw new Error(`intent content is not JSON: ${content.slice(0, 500)}`);
}
const first = parsed.items?.[0];
if (!first) throw new Error(`missing first intent item: ${JSON.stringify(parsed)}`);
if (first.intent !== expectedIntent) {
  throw new Error(`expected intent ${expectedIntent}, got ${first.intent}: ${JSON.stringify(parsed)}`);
}
if (expectedField && !Object.prototype.hasOwnProperty.call(first.extractedData || {}, expectedField)) {
  throw new Error(`expected extractedData.${expectedField}: ${JSON.stringify(parsed)}`);
}
console.log(JSON.stringify({
  mode: parsed.mode,
  intent: first.intent,
  extractedData: first.extractedData,
}, null, 2));
NODE
}

require_command curl
require_command node

if [[ -z "$ADMIN_TOKEN" ]]; then
  echo "HOLO_ADMIN_TOKEN is required for authenticated release verification" >&2
  exit 2
fi

mkdir -p "$(dirname "$REPORT_PATH")"
cat > "$REPORT_PATH" <<EOF
# HoloBackend Release Verification

- Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Base URL: $BASE_URL
- Prompt Type: $PROMPT_TYPE
- Expected Prompt Version: ${EXPECT_PROMPT_VERSION:-not set}
- Expected Prompt Text: $EXPECT_PROMPT_CONTAINS
- Intent Cases: $([[ "$SKIP_INTENT_CASES" == "1" ]] && printf 'skipped; no-token metadata/prompt check' || printf 'enabled; sends real intent requests and may create usage/log entries')

EOF

run_step "Public health" check_health
run_step "Public release status" check_release_status
run_step "Authenticated release evidence" check_admin_release_status

if [[ "$SKIP_INTENT_CASES" == "1" ]]; then
  append_report ""
  append_report "## Intent cases skipped"
  append_report ""
  append_report "Status: SKIPPED"
  append_report ""
  append_report "Reason: SKIP_INTENT_CASES=1 requested metadata-only authenticated verification."
else
  run_step "Intent case: expense date contract" check_intent_case "expense" "昨天午饭花了35" "record_expense" "transactionDate"
  run_step "Intent case: task reminder contract" check_intent_case "task-reminder" "明天早上提醒我买水" "create_task" "reminderDate"
  run_step "Intent case: health analysis routing" check_intent_case "health-sleep" "最近状态不好，看看睡眠咋样" "query_analysis" "analysisDomain"
fi

echo ""
echo "Release verification passed."
echo "Report: $REPORT_PATH"
