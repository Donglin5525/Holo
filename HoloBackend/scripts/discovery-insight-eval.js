#!/usr/bin/env node
// 「一个发现」v4 离线评测脚本（2026-11-20 方案 04-§2）。
//
// 用法：
//   node scripts/discovery-insight-eval.js --base http://localhost:8787 [--rounds 3] [--out ./eval-output]
// BASE 指向部署了 discovery_insight_v2 且已开 HOLO_DISCOVERY_INSIGHT_V2_ENABLED=true 的后端。
// 每组 fixture 跑 N 轮，输出：闸门通过率 / none 率 / 平均耗时；产出文案落盘供人工打分。
// fixtures 均为合成数据，无用户原文。

import { readFileSync, writeFileSync, mkdirSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const FIXTURE_DIR = join(HERE, "..", "test", "fixtures", "discovery-insight");

const args = process.argv.slice(2);
function argValue(flag, fallback) {
  const i = args.indexOf(flag);
  return i !== -1 && args[i + 1] ? args[i + 1] : fallback;
}
const base = argValue("--base", "http://localhost:8787").replace(/\/$/, "");
const rounds = Number(argValue("--rounds", 3));
const outDir = argValue("--out", join(HERE, "..", "eval-output", "discovery-insight"));
// 评测设备头：非 36 位 UUID 格式，与生产脚本甄别口径一致（ai_call_logs 不计真实用户）。
// 每组×每轮独立设备 id：route 限流 3 次/日/设备，8 组 × 3 轮共用一个 id 会撞 429。
const deviceIdPrefix = "eval-insight-v2";

function loadFixtures() {
  return readdirSync(FIXTURE_DIR)
    .filter((name) => name.endsWith(".json"))
    .sort()
    .map((name) => ({
      name: name.replace(/\.json$/, ""),
      packet: JSON.parse(readFileSync(join(FIXTURE_DIR, name), "utf8")),
    }));
}

async function callOnce(packet, deviceId) {
  const started = Date.now();
  const response = await fetch(`${base}/v1/ai/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": deviceId },
    body: JSON.stringify({
      purpose: "discovery_insight_v2",
      stream: false,
      messages: [{
        role: "user",
        content: JSON.stringify({
          ...packet,
          requestId: `eval-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
        }),
      }],
    }),
  });
  const json = await response.json().catch(() => null);
  const content = json?.choices?.[0]?.message?.content ?? "";
  let draft = null;
  try { draft = JSON.parse(content); } catch { draft = null; }
  return { status: response.status, ms: Date.now() - started, draft, raw: content };
}

async function main() {
  const fixtures = loadFixtures();
  mkdirSync(outDir, { recursive: true });
  const summary = [];
  const transcripts = [];

  for (const { name, packet } of fixtures) {
    let accepted = 0;
    let noneDecided = 0;
    let gateRejected = 0;
    let errors = 0;
    const durations = [];

    for (let round = 0; round < rounds; round += 1) {
      let result;
      try {
        result = await callOnce(packet, `${deviceIdPrefix}-${name}-${round}`);
      } catch (error) {
        errors += 1;
        transcripts.push({ fixture: name, round, error: String(error) });
        continue;
      }
      durations.push(result.ms);
      const reason = result.draft?.noneReason ?? null;
      if (result.draft?.selected) {
        accepted += 1;
        transcripts.push({
          fixture: name, round, ms: result.ms, status: result.status,
          headline: result.draft.selected.headline,
          insight: result.draft.selected.insight,
          evidence: result.draft.selected.evidence,
          criteria: result.draft.selected.criteria,
          sourceDomains: result.draft.selected.sourceDomains,
        });
      } else if (reason === "none_worthwhile" || reason === "insufficient_data") {
        noneDecided += 1;
        transcripts.push({ fixture: name, round, ms: result.ms, status: result.status, noneReason: reason });
      } else {
        gateRejected += 1;
        transcripts.push({ fixture: name, round, ms: result.ms, status: result.status, noneReason: reason, raw: result.raw.slice(0, 400) });
      }
    }

    const avgMs = durations.length ? Math.round(durations.reduce((a, b) => a + b, 0) / durations.length) : 0;
    summary.push({
      fixture: name,
      gatePass: `${accepted}/${rounds}`,
      noneRate: `${noneDecided}/${rounds}`,
      gateRejected,
      errors,
      avgMs,
    });
  }

  const report = { base, rounds, at: new Date().toISOString(), summary, transcripts };
  const outPath = join(outDir, `eval-${Date.now()}.json`);
  writeFileSync(outPath, JSON.stringify(report, null, 2));
  console.table(summary);
  console.log(`完整产出（含文案，供人工打分）: ${outPath}`);
}

main().catch((error) => {
  console.error("评测失败:", error);
  process.exit(1);
});
