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

test("release verification script can skip intent calls for no-token checks", async () => {
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
  */v1/prompts/meta)
    body='{"prompts":[{"type":"intent_recognition","version":21,"source":"default","updatedAt":null}]}'
    ;;
  */v1/release/status)
    body='{"ok":true,"service":"holo-ai-gateway","prompts":[{"type":"intent_recognition","version":21}],"routes":{"intent":{"provider":"mock","model":"holo-mock","maxTokens":4096}},"database":{"configured":true}}'
    ;;
  */v1/prompts/intent_recognition)
    body='{"type":"intent_recognition","version":21,"source":"default","updatedAt":null,"content":"transactionDate reminderDate query_analysis"}'
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
  assert.match(report, /Release status/);
  assert.match(report, /Intent cases skipped/);
  assert.match(report, /no-token metadata\/prompt check/);
});
