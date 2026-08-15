// 深度分析链路延迟基准：模拟 agent_loop 各轮次输入规模，打真实后端测端到端延迟。
// 用法：node scripts/latency-benchmark.js [baseUrl] [rounds]
import { readFileSync } from "node:fs";

const baseUrl = process.argv[2] ?? "https://api.holoapp.cn";
const roundsPerSize = Number(process.argv[3] ?? 3);
const deviceId = process.env.BENCH_DEVICE ?? "latency-bench-device";

// 模拟 agent loop 的真实消息形态：大 system 协议 + 累积的工具结果
function buildAgentMessages(charSize) {
  const systemCore = "你是 HoloAI 的本地 Agent Loop 推理器。你必须只输出 JSON。状态与工具协议（摘要）：status ∈ continue | final_claims；toolRequests 数组带 tool/args；evidenceID 必须逐字引用已有证据。";
  const fillerChunk = "工具结果 finance_query_transactions：近 7 天交易 12 笔，餐饮 340 元（麦当劳 2 笔 68 元、外卖 5 笔 198 元），交通 45 元，购物 210 元。任务完成 3 件逾期 1 件。习惯打卡：跑步 2/3 次，冥想 0/5 次。睡眠均值 6.2h（低于目标 7.5h）。想法记录 4 条，主题集中在项目排期与精力不足。\n";
  const repeat = Math.max(1, Math.floor((charSize - systemCore.length - 2000) / fillerChunk.length));
  return [
    { role: "system", content: systemCore },
    { role: "user", content: "请基于以下累积数据分析本周状态：\n" + fillerChunk.repeat(repeat) + "\n输出下一轮 JSON。" }
  ];
}

const scenarios = [
  { name: "S1-小(≈2K tokens)", chars: 8000 },
  { name: "S2-中(≈6K tokens)", chars: 24000 },
  { name: "S3-大(≈12K tokens)", chars: 48000 },
  { name: "S4-超大(≈24K tokens)", chars: 96000 },
];

async function callOnce(purpose, messages) {
  const started = Date.now();
  try {
    const response = await fetch(`${baseUrl}/v1/ai/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-holo-device-id": deviceId },
      body: JSON.stringify({ purpose, messages, stream: false }),
      signal: AbortSignal.timeout(150_000),
    });
    const elapsed = Date.now() - started;
    if (!response.ok) {
      const body = await response.text();
      return { ok: false, elapsed, status: response.status, error: body.slice(0, 120) };
    }
    const data = await response.json();
    const usage = data?.usage;
    return { ok: true, elapsed, promptTokens: usage?.prompt_tokens, completionTokens: usage?.completion_tokens };
  } catch (error) {
    return { ok: false, elapsed: Date.now() - started, error: String(error).slice(0, 120) };
  }
}

console.log(`基准目标: ${baseUrl}  每场景 ${roundsPerSize} 轮\n`);
const summary = [];
for (const scenario of scenarios) {
  for (const purpose of ["agent_loop"]) {
    const results = [];
    for (let i = 0; i < roundsPerSize; i++) {
      const result = await callOnce(purpose, buildAgentMessages(scenario.chars));
      results.push(result);
      console.log(`${scenario.name} [${purpose}] 第${i + 1}轮: ${result.ok ? "✓" : "✗"} ${result.elapsed}ms${result.error ? " " + result.error : ""}`);
    }
    const okResults = results.filter(r => r.ok);
    if (okResults.length) {
      const times = okResults.map(r => r.elapsed).sort((a, b) => a - b);
      summary.push({
        scenario: scenario.name, purpose,
        successRate: `${okResults.length}/${results.length}`,
        p50: times[Math.floor(times.length / 2)],
        max: times[times.length - 1],
      });
    } else {
      summary.push({ scenario: scenario.name, purpose, successRate: `0/${results.length}`, error: results[0]?.error });
    }
  }
}
console.log("\n=== 汇总 ===");
for (const row of summary) {
  console.log(`${row.scenario} ${row.purpose}: 成功 ${row.successRate}${row.p50 ? `  P50=${row.p50}ms  MAX=${row.max}ms` : "  " + (row.error ?? "")}`);
}
