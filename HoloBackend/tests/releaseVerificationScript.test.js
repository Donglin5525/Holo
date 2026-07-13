import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { test } from "node:test";

function runScript(env) {
  return new Promise((resolve) => {
    const child = spawn("bash", ["scripts/verify-production-release.sh"], {
      cwd: new URL("..", import.meta.url),
      env: {
        ...process.env,
        ...env,
      },
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("close", (code) => {
      resolve({ code, stdout, stderr });
    });
  });
}

test("release verification script uses admin auth and can skip intent calls", async () => {
  const reportDir = await mkdtemp(join(tmpdir(), "holo-release-test-"));
  const binDir = join(reportDir, "bin");
  const reportPath = join(reportDir, "report.md");
  const callsPath = join(reportDir, "curl-calls.log");
  await writeFile(join(reportDir, ".keep"), "");
  await import("node:fs/promises").then(({ mkdir }) => mkdir(binDir));
  const fakeCurlPath = join(binDir, "curl");
  await writeFile(fakeCurlPath, `#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "${callsPath}"
output=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    http*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

case "$url" in
  */v1/health)
    body='{"ok":true,"service":"holo-ai-gateway"}'
    ;;
  */v1/release/status)
    body='{"ok":true,"service":"holo-ai-gateway","release":{"commit":"abc"}}'
    ;;
  */v1/admin/release/status)
    body='{"ok":true,"service":"holo-ai-gateway","prompts":[{"type":"intent_recognition","version":21,"content":"transactionDate reminderDate query_analysis"}],"routes":{"intent":{"provider":"mock","model":"holo-mock","maxTokens":4096}},"database":{"configured":true}}'
    ;;
  */v1/ai/chat/completions)
    body='{"choices":[{"message":{"content":"{\\"items\\":[{\\"intent\\":\\"unexpected\\",\\"extractedData\\":{}}]}"}}]}'
    ;;
  *)
    echo "unexpected url: $url" >&2
    exit 22
    ;;
esac

if [[ -n "$output" ]]; then
  printf '%s' "$body" > "$output"
else
  printf '%s' "$body"
fi
`);
  await chmod(fakeCurlPath, 0o755);

  const result = await runScript({
    BASE_URL: "https://api.example.test",
    REPORT_PATH: reportPath,
    EXPECT_PROMPT_VERSION: "21",
    SKIP_INTENT_CASES: "1",
    HOLO_ADMIN_TOKEN: "test-admin-token",
    PATH: `${binDir}:${process.env.PATH}`,
  });

  assert.equal(result.code, 0, result.stderr);
  const calls = await readFile(callsPath, "utf8");
  assert.equal(
    calls.includes("-X POST"),
    false,
    "SKIP_INTENT_CASES=1 should avoid model/usage/log side effects",
  );

  const report = await readFile(reportPath, "utf8");
  assert.match(report, /Authenticated release evidence/);
  assert.match(report, /Intent cases skipped/);
  assert.doesNotMatch(report, /test-admin-token/);
});

test("release verification script fails closed without admin token", async () => {
  const reportDir = await mkdtemp(join(tmpdir(), "holo-release-no-token-"));
  const result = await runScript({
    BASE_URL: "https://api.example.test",
    REPORT_PATH: join(reportDir, "report.md"),
    HOLO_ADMIN_TOKEN: "",
  });
  assert.equal(result.code, 2);
  assert.match(result.stderr, /HOLO_ADMIN_TOKEN is required/);
});
