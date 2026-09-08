#!/usr/bin/env node
// 截图识别记账 · vision_extraction 模型选型评测（M0）
// 用法（仓库根）: node scripts/eval-vision-extraction.mjs [--limit 6] [--models qwen,zhipu]
//   [--model-qwen qwen-vl-max-latest] [--model-zhipu glm-4v-plus]
// key/baseURL 从 HoloBackend/.env 读（QWEN_*/ZHIPU_*），不打印任何 key。
// 口径与期望结果: docs/holoai-audit/vision-eval/README.md + corpus/manifest.json

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const evalDir = path.join(repoRoot, 'docs/holoai-audit/vision-eval');
const corpusDir = path.join(evalDir, 'corpus');
const resultsDir = path.join(evalDir, 'results');

// ---------- 参数 ----------
const argv = process.argv.slice(2);
function arg(name, fallback) {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
}
const limit = parseInt(arg('--limit', '0'), 10) || Infinity;
const modelKeys = arg('--models', 'qwen,qwen-flash').split(',');

function loadEnv() {
  const out = {};
  for (const line of fs.readFileSync(path.join(repoRoot, 'HoloBackend', '.env'), 'utf8').split('\n')) {
    const m = line.match(/^([A-Za-z0-9_]+)=(.*)$/);
    if (m) out[m[1]] = m[2].replace(/^["']|["']$/g, '').trim();
  }
  return out;
}
const env = loadEnv();

const qwenKey = env.QWEN_API_KEY || env.DASHSCOPE_API_KEY; // 本地 .env 常只有 DASHSCOPE_API_KEY 有值
const qwenBase = env.QWEN_BASE_URL || 'https://dashscope.aliyuncs.com/compatible-mode/v1';

const MODELS = {
  qwen: {
    label: '通义千问 qwen-vl(旗舰)',
    baseURL: qwenBase,
    key: qwenKey,
    model: arg('--model-qwen', 'qwen3-vl-plus'),
  },
  'qwen-flash': {
    label: '通义千问 qwen-vl(普惠)',
    baseURL: qwenBase,
    key: qwenKey,
    model: arg('--model-flash', 'qwen3-vl-flash'),
  },
  zhipu: {
    label: '智谱 glm-4v',
    baseURL: env.ZHIPU_BASE_URL || 'https://open.bigmodel.cn/api/paas/v4',
    key: env.ZHIPU_API_KEY,
    model: arg('--model-zhipu', 'glm-4v-plus'),
  },
};

// ---------- 理解单抽取 prompt（与后端 vision_extraction 同源） ----------
const PROMPT = `你是记账应用的图片理解引擎。仔细看图，输出一张「图片理解单」。只输出一个 JSON 对象，禁止输出任何其他文字、解释或代码块标记。

imageType 取值（必选其一）：
- receipt：纸质小票/购物凭证/发票
- payment_screenshot：支付完成的订单详情/账单截图
- transfer_screenshot：个人转账、红包、信用卡还款等资金流转截图（这些不是消费，不能记账）
- wealth_screenshot：理财、余额、收益类页面
- list_note：待办清单/购物清单类文字
- foreign_currency：金额不是人民币的凭证
- pending_order：尚未支付的订单
- unrelated：其他无关图片

字段规则：
1. transactions 只收录「已完成支付」的消费交易；transfer_screenshot/wealth_screenshot/list_note/foreign_currency/pending_order/unrelated 一律空数组，并给出中文 rejectReason。
2. 【货币红线，最先判断】只要图中金额不是人民币（$、€、£、JP¥、USD 等任何外币符号或文字），imageType 必须是 foreign_currency，transactions 必须为空数组，禁止把外币换算后记进 transactions。
3. 正常消费 type=expense；退款/退货到账 type=income。
4. amount 是实付金额（数字，单位元）。一张图多笔交易时 transactions 有多笔。
5. amountOriginalText：逐字抄录图中「合计/实付金额」的原文，包括货币符号（如 "$14.47"、"¥98.60"、"PAID $14.47"），禁止换算或改写。
6. date 用 YYYY-MM-DD。merchant 保留图中商户原文。items 列出小票明细（没有则空数组）。
7. paymentChannel：微信支付/支付宝/现金/银行卡（给尾号后4位，如 "4321"）；图中看不出则 null。
8. 看不清或不确定时 confidence 低于 0.6，不要编造字段。
9. 图型补充判定：微信/QQ 等聊天对话记录截图 → unrelated（不是 list_note，清单专指购物清单/待办列表）；支付失败的收银台/订单截图 → unrelated，transactions 必须为空。
10. 图中出现「退款」「退货」字样的凭证，交易 type 必须是 income。

【货币判定示例】输入是一张外币小票（Total $14.47，VISA 支付）时，唯一正确输出是外币拒识——currency 和 amountOriginalText 必须保留美元原文，绝不能写成人民币：
{"imageType":"foreign_currency","confidence":0.95,"summary":"Whole Foods 美元消费小票","merchant":"Whole Foods Market","paidAt":null,"paymentChannel":"8821","currency":"USD","amountOriginalText":"$14.47","items":[{"name":"Organic Bananas","amount":3.99}],"transactions":[],"rejectReason":"外币消费暂不支持记账"}

输出结构：
{"imageType":"receipt","confidence":0.9,"summary":"一句话摘要","merchant":"商户或null","paidAt":"YYYY-MM-DD或null","paymentChannel":"微信支付或支付宝或现金或银行卡尾号4位或null","currency":"CNY","amountOriginalText":"¥98.60","items":[{"name":"条目","amount":0}],"transactions":[{"type":"expense","amount":0,"note":"商户或条目摘要","date":"YYYY-MM-DD"}],"rejectReason":null}`;

// ---------- 调用 ----------
async function callVision(cfg, b64) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 120_000);
  try {
    const res = await fetch(cfg.baseURL.replace(/\/$/, '') + '/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${cfg.key}` },
      body: JSON.stringify({
        model: cfg.model,
        temperature: 0,
        max_tokens: 1500,
        messages: [{
          role: 'user',
          content: [
            { type: 'text', text: PROMPT },
            { type: 'image_url', image_url: { url: `data:image/jpeg;base64,${b64}` } },
          ],
        }],
      }),
      signal: controller.signal,
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const data = await res.json();
    return { text: data.choices?.[0]?.message?.content, usage: data.usage || {} };
  } finally {
    clearTimeout(timer);
  }
}

function extractJSON(text) {
  if (!text) throw new Error('空回复');
  const t = text.trim().replace(/^```(?:json)?/i, '').replace(/```$/, '').trim();
  const s = t.indexOf('{'), e = t.lastIndexOf('}');
  if (s < 0 || e <= s) throw new Error('无JSON: ' + t.slice(0, 120));
  return JSON.parse(t.slice(s, e + 1));
}

// ---------- 打分 ----------
const near = (a, b) => Math.abs(a - b) < 0.005;
// 生产管线同款确定性护栏：模型口头承诺 CNY 不可信，以「逐字抄录的金额原文」为准
const FOREIGN_MONEY = /[$€£]|USD|EUR|GBP|JPY|HKD|NT\$/i;
function applyProductionGuard(p) {
  const txt = String(p.amountOriginalText || '');
  if ((p.transactions || []).length > 0 && FOREIGN_MONEY.test(txt)) {
    p.transactions = [];
    p.imageType = 'foreign_currency';
    p.rejectReason = p.rejectReason || '检测到外币金额，暂不支持外币记账';
    p.__guardApplied = true;
  }
  return p;
}
function amountsMatch(exp, act) {
  if (exp.length !== act.length) return false;
  const pool = [...act];
  for (const e of exp) {
    const i = pool.findIndex((a) => near(a, e));
    if (i < 0) return false;
    pool.splice(i, 1);
  }
  return true;
}
function scoreOne(exp, p) {
  const txs = Array.isArray(p.transactions) ? p.transactions : [];
  const amounts = txs.map((t) => Math.abs(Number(t.amount) || 0));
  const notes = txs.map((t) => String(t.note || ''));
  const merchantHay = [p.merchant, p.summary, ...notes].filter(Boolean).join(' | ');
  const channelHay = [p.paymentChannel, p.summary, ...notes].filter(Boolean).join(' | ');
  const it = String(p.imageType || '');
  const typeOK = exp.typeAnyOf ? exp.typeAnyOf.includes(it) : it === exp.type;
  const rejected = txs.length === 0;

  const checks = { type: typeOK, reject: true, amounts: true, types: true, date: true, merchant: true, channel: true };
  if (exp.reject) {
    checks.reject = rejected;
  } else if (rejected && exp.acceptRejectToo) {
    // 宽口径：模糊图抽出正确或诚实拒识都算过
    return { pass: true, lenient: true, checks };
  } else {
    checks.reject = !rejected;
    checks.amounts = amountsMatch(exp.amounts, amounts);
    const expPairs = exp.amounts.map((a, i) => [a, exp.types[i]]).sort((x, y) => x[0] - y[0]);
    const actPairs = amounts.map((a, i) => [a, txs[i]?.type]).sort((x, y) => x[0] - y[0]);
    checks.types = expPairs.every(([a, t], i) => near(a, actPairs[i]?.[0]) && actPairs[i]?.[1] === t);
    const dates = [p.paidAt, ...txs.map((t) => t.date)].filter(Boolean);
    checks.date = exp.date ? dates.includes(exp.date) : dates.length === 0;
    checks.merchant = exp.merchantIncludes.every((n) => merchantHay.includes(n));
    checks.channel = exp.channelIncludes.every((n) => channelHay.includes(n));
  }
  return { pass: Object.values(checks).every(Boolean), lenient: false, checks };
}

// ---------- 并发池 ----------
async function pool(items, n, fn) {
  const results = [];
  let i = 0;
  await Promise.all(Array.from({ length: n }, async () => {
    while (i < items.length) {
      const idx = i++;
      results[idx] = await fn(items[idx], idx);
    }
  }));
  return results;
}

// ---------- 主流程 ----------
const manifest = JSON.parse(fs.readFileSync(path.join(corpusDir, 'manifest.json'), 'utf8')).slice(0, limit);
fs.mkdirSync(resultsDir, { recursive: true });

for (const mk of modelKeys) {
  const cfg = MODELS[mk];
  if (!cfg?.key) {
    console.log(`\n=== [${mk}] 缺少 key，跳过 ===`);
    continue;
  }
  console.log(`\n=== ${cfg.label} · ${cfg.model} ===`);
  const rows = await pool(manifest, 3, async (item) => {
    const b64 = fs.readFileSync(path.join(corpusDir, item.file)).toString('base64');
    let parsed = null, raw = null, err = null, usage = {};
    for (let attempt = 0; attempt < 2 && !parsed; attempt++) {
      try {
        const r = await callVision(cfg, b64);
        raw = r.text; usage = r.usage;
        parsed = extractJSON(r.text);
      } catch (e) {
        err = e.message;
        if (attempt === 0) await new Promise((r) => setTimeout(r, 2000));
      }
    }
    const result = { file: item.file, usage, raw, parsed, error: err };
    if (parsed) {
      applyProductionGuard(parsed);
      const s = scoreOne(item.expect, parsed);
      result.checks = s.checks;
      result.pass = s.pass;
      result.lenient = s.lenient;
      console.log(`${s.pass ? '✅' : '❌'} ${item.file.padEnd(26)} ${String(parsed.imageType).padEnd(20)} tx=${(parsed.transactions || []).length}${s.lenient ? ' (宽口径拒识)' : ''}${err && !parsed ? ' err=' + err : ''}`);
    } else {
      result.pass = false;
      console.log(`💥 ${item.file.padEnd(26)} 调用/解析失败: ${err}`);
    }
    return result;
  });

  const scored = rows.filter((r) => r.parsed);
  const billable = manifest.filter((m) => !m.expect.reject);
  const billableRows = rows.filter((r) => manifest.find((m) => m.file === r.file)?.expect.reject === false);
  const falseRejects = billableRows.filter((r) => r.parsed && (r.parsed.transactions || []).length === 0 && !manifest.find((m) => m.file === r.file)?.expect.acceptRejectToo);
  const interceptItems = manifest.filter((m) => m.expect.intercept);
  const interceptHit = interceptItems.filter((m) => {
    const r = rows.find((x) => x.file === m.file);
    return r?.parsed && (r.parsed.transactions || []).length === 0;
  });
  const dim = (name) => scored.filter((r) => r.checks?.[name]).length;
  const tokens = rows.reduce((a, r) => a + (r.usage.prompt_tokens || 0) + (r.usage.completion_tokens || 0), 0);
  const promptTokens = rows.reduce((a, r) => a + (r.usage.prompt_tokens || 0), 0);

  console.log(`\n—— 汇总（${cfg.model}）——`);
  console.log(`整体通过: ${scored.filter((r) => r.pass).length}/${manifest.length}  (调参失败 ${rows.length - scored.length})`);
  console.log(`图型准确: ${dim('type')}/${scored.length}  拒识正确: ${dim('reject')}/${scored.length}`);
  console.log(`金额准确: ${billable.length ? billableRows.filter((r) => r.checks?.amounts && r.checks?.types).length + '/' + billable.length : '-'}  日期: ${billableRows.filter((r) => r.checks?.date).length}/${billable.length}`);
  console.log(`商户准确: ${billableRows.filter((r) => r.checks?.merchant).length}/${billable.length}  通道准确: ${billableRows.filter((r) => r.checks?.channel).length}/${billable.length}`);
  console.log(`【安全红线】资金流转拦截召回: ${interceptHit.length}/${interceptItems.length}  误拒(该记没记): ${falseRejects.length}/${billable.length}`);
  console.log(`tokens: prompt合计 ${promptTokens}, 单均 ${(promptTokens / Math.max(rows.length, 1)).toFixed(0)}, 总 ${tokens}`);

  fs.writeFileSync(path.join(resultsDir, `${cfg.model}.json`), JSON.stringify({ model: cfg.model, ranAt: new Date().toISOString(), summary: { pass: scored.filter((r) => r.pass).length, total: manifest.length }, rows }, null, 2));
  console.log(`结果已写 results/${cfg.model}.json`);
}
