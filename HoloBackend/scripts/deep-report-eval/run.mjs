// 深度报告评测集运行器（2026-11-20「懂我」方案 P0）
// 用生产同款执行器路径（createCloudAnalysisExecutor + deep_report 任务）跑合成人设，
// 模型通道与生产一致：深度分析专用通道 deepseek / deepseek-flash。
// 与生产的差别：钥匙取本地 HoloBackend/.env、内存库、不写 ai_call_logs、prompt 用 defaultPrompts.json。
// 用法：node scripts/deep-report-eval/run.mjs [轮数=1] [case 前缀…]
import { randomBytes } from "node:crypto";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "..", "..");

for (const line of readFileSync(join(REPO, ".env"), "utf8").split("\n")) {
  const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
  if (!m) continue;
  let v = m[2];
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
  if (process.env[m[1]] === undefined) process.env[m[1]] = v;
}
// 对齐生产：深度分析专用通道
process.env.HOLO_CLOUD_DEEP_ANALYSIS_PROVIDER = "deepseek";
process.env.HOLO_CLOUD_DEEP_ANALYSIS_MODEL = "deepseek-flash";

const { loadConfig } = await import(join(REPO, "src/config.js"));
const { createOpenAICompatibleProvider } = await import(join(REPO, "src/providers/openAICompatibleProvider.js"));
const { createDatabase } = await import(join(REPO, "src/db/database.js"));
const { createCloudAnalysisTaskStore } = await import(join(REPO, "src/agent/cloudAnalysisTaskStore.js"));
const { createCloudAnalysisExecutor } = await import(join(REPO, "src/agent/cloudAnalysisExecutor.js"));
const { computeFactSheet } = await import(join(REPO, "src/agent/deepReport/factComputator.js"));
const { CASES: BASE_CASES, buildSnapshot: buildPersonaSnapshot } = await import(join(HERE, "personas.mjs"));
// 目标复盘人设（报告改版 C2）：用例自带 build()，其余沿用人设快照
const { GOAL_CASES } = await import(join(HERE, "goalPersonas.mjs"));
const CASES = [...BASE_CASES, ...GOAL_CASES];
const buildSnapshot = (testCase) => (testCase.build ? testCase.build() : buildPersonaSnapshot(testCase));

// config 默认单价（元/百万 token），线上实际单价未核对
const PRICE = { input: 3, cached: 0.1, output: 9 };

const config = loadConfig();
const writer = config.routes.deep_report_writer;
const checker = config.routes.deep_report_checker;
if (writer.provider !== "deepseek") throw new Error(`writer 路由不是 deepseek：${writer.provider}`);
const provider = createOpenAICompatibleProvider(config.providers.deepseek);

const rounds = Number(process.argv[2] ?? 1);
const only = process.argv.slice(3);
const outDir = join(REPO, "eval-output", "deep-report", new Date().toISOString().replace(/[:.]/g, "-"));
mkdirSync(outDir, { recursive: true });

function renderReport(result) {
  if (!result) return "";
  const parts = [`# ${result.title}`];
  if (result.narrativeSummary) parts.push(result.narrativeSummary);
  const byId = new Map((result.claims ?? []).map((c) => [c.id, c.displayText]));
  const used = new Set();
  for (const s of result.reportStructure?.sections ?? []) {
    if (s.title && s.title !== "开篇") parts.push(`## ${s.title}`);
    for (const id of s.paragraphClaimIDs ?? []) if (byId.has(id)) { parts.push(byId.get(id)); used.add(id); }
  }
  for (const c of result.claims ?? []) if (!used.has(c.id)) parts.push(c.displayText);
  for (const item of result.reportStructure?.conclusionItems ?? []) parts.push(`（建议）${typeof item === "string" ? item : JSON.stringify(item)}`);
  if (result.reportStructure?.disclosureNotes?.length) parts.push(`数据说明：${result.reportStructure.disclosureNotes.join("；")}`);
  return parts.join("\n\n");
}

async function runCase(testCase, round) {
  const calls = [];
  const tracking = {
    ...provider,
    async complete(request) {
      const t0 = Date.now();
      try {
        const res = await provider.complete(request);
        const choice = res?.choices?.[0];
        calls.push({
          ms: Date.now() - t0, usage: res?.usage ?? null, ok: true,
          json: Boolean(request.responseFormat), maxTokens: request.maxTokens,
          finish: choice?.finish_reason ?? null, contentLen: (choice?.message?.content ?? "").length,
          head: String(request.messages?.[0]?.content ?? "").slice(0, 40),
        });
        return res;
      } catch (error) {
        calls.push({ ms: Date.now() - t0, ok: false, error: String(error?.message ?? error) });
        throw error;
      }
    },
  };
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: randomBytes(32).toString("base64") });
  const logs = [];
  const executor = createCloudAnalysisExecutor({
    taskStore: store,
    providers: new Map([["deepseek", tracking]]),
    route: config.routes.cloudDeepAnalysis ?? config.routes.agent_loop,
    deepReportRoutes: { writer, checker },
    providerRetries: 2,
    log: (m) => logs.push(String(m)),
    injectedQuestionTimeResolver: { resolveQuestionTime: async () => null },
  });
  const snapshot = buildSnapshot(testCase);
  const task = store.create({ deviceId: `eval-${testCase.id}`, question: testCase.question, taskType: "deep_report" });
  store.attachSnapshot({ id: task.id, snapshot: JSON.stringify(snapshot) });
  const t0 = Date.now();
  const status = await executor.run(task.id);
  const ms = Date.now() - t0;
  const row = store.getDecrypted(task.id, ["result", "failureReason"]);
  database.db.close();
  const result = row?.result ? JSON.parse(row.result) : null;
  const u = calls.reduce((a, c) => ({
    prompt: a.prompt + (c.usage?.prompt_tokens ?? 0),
    cached: a.cached + (c.usage?.prompt_cache_hit_tokens ?? c.usage?.prompt_tokens_details?.cached_tokens ?? 0),
    completion: a.completion + (c.usage?.completion_tokens ?? 0),
  }), { prompt: 0, cached: 0, completion: 0 });
  const costCNY = ((u.prompt - u.cached) * PRICE.input + u.cached * PRICE.cached + u.completion * PRICE.output) / 1e6;
  const record = {
    id: testCase.id, round, status, seconds: Math.round(ms / 1000), calls: calls.length,
    failedCalls: calls.filter((c) => !c.ok).length, callLog: calls, usage: u, costCNY: Math.round(costCNY * 10000) / 10000,
    failureReason: row?.failureReason ?? null, engineLog: logs.filter((l) => l.includes("深度报告完成")),
  };
  const name = `${testCase.id}__r${round}`;
  writeFileSync(join(outDir, `${name}.json`), JSON.stringify({ ...record, result }, null, 2));
  writeFileSync(join(outDir, `${name}.md`), [
    `<!-- ${testCase.id} 第${round}轮 · ${status} · ${record.seconds}s · ${record.calls} 次调用 · ¥${record.costCNY} -->`,
    `问题：${testCase.question}`,
    `档案：${snapshot.profileBrief ?? "（无）"}`,
    `确认理解：${snapshot.confirmedKnowledgeBrief ?? "（无）"}`,
    "",
    "---",
    "",
    result ? renderReport(result) : `（任务失败：${row?.failureReason ?? status}）`,
  ].join("\n"));
  return record;
}

const cases = CASES.filter((c) => !only.length || only.some((o) => c.id.startsWith(o)));
for (const c of cases) writeFileSync(join(outDir, `${c.id}__facts.txt`), computeFactSheet(buildSnapshot(c)).text);

const jobs = [];
for (let r = 1; r <= rounds; r += 1) for (const c of cases) jobs.push([c, r]);
const records = [];
let next = 0;
async function worker() {
  while (next < jobs.length) {
    const [c, r] = jobs[next++];
    try {
      const rec = await runCase(c, r);
      records.push(rec);
      console.log(`${c.id} r${r} → ${rec.status} ${rec.seconds}s calls=${rec.calls} ¥${rec.costCNY} ${rec.engineLog.join(" ")}`);
    } catch (error) {
      console.log(`${c.id} r${r} ERROR ${error?.stack ?? error}`);
    }
  }
}
await Promise.all(Array.from({ length: 3 }, worker));
writeFileSync(join(outDir, "summary.json"), JSON.stringify(records, null, 2));
console.log(`输出目录：${outDir}`);
