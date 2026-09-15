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
  deepseek: {
    label: 'DeepSeek v4 视觉',
    baseURL: env.DEEPSEEK_VISION_BASE_URL || env.DEEPSEEK_BASE_URL || 'https://api.deepseek.com',
    // 2026-09-09 生产换 deepseek-v4-flash-vision-exp 走独立钥匙通道（与主聊天隔离），
    // 评测同口径优先读 DEEPSEEK_VISION_API_KEY
    key: process.env.DEEPSEEK_API_KEY_EVAL || env.DEEPSEEK_VISION_API_KEY || env.DEEPSEEK_API_KEY,
    model: arg('--model-deepseek', 'deepseek-v4-flash-vision-exp'),
    reasoningEffort: arg('--reasoning-effort'),
  },
};

// ---------- 理解单抽取 prompt ----------
// 单一真源是 HoloBackend/src/prompts/defaultPrompts.json 的 vision_extraction（生产热更体系），
// 本脚本优先读它；嵌入常量只作仓库不齐时的兜底。改 prompt 先跑本评测。
// v2（2026-09-14 图片快捷指令自动记账方案 §26）与生产 prompt 同步。
const EMBEDDED_PROMPT = `你是记账应用的图片理解引擎。仔细看图，输出一张「图片理解单」。只输出一个 JSON 对象，禁止输出任何其他文字、解释或代码块标记。输出对象的第一个字段必须是 "schemaVersion": 2。

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
5. amountOriginalText：逐字抄录图中「合计/实付金额」的原文，包括货币符号（如 "$14.47"、"¥98.60"、"PAID $14.47"），禁止换算或改写。transactions 里每笔交易也要带各自的 amountOriginalText（逐字抄录该笔金额原文）。
6. date 用 YYYY-MM-DD。merchant 保留图中商户原文。items 列出小票明细（没有则空数组）。
7. paymentChannel：微信支付/支付宝/现金/银行卡（给尾号后4位，如 "4321"）；图中看不出则 null。
8. 看不清或不确定时顶层 confidence 低于 0.6，不要编造字段。
9. 图型补充判定：微信/QQ 等聊天对话记录截图 → unrelated（不是 list_note，清单专指购物清单/待办列表）；支付失败的收银台/订单截图 → unrelated，transactions 必须为空。
10. 图中出现「退款」「退货」字样的凭证，交易 type 必须是 income，顶层 paymentStatus 必须是 refunded。
11. paymentStatus（顶层支付状态）：completed（已完成支付）/ refunded（退款/退货到账）/ pending（待支付）/ failed（支付失败）/ cancelled（订单已取消）/ unknown（看不出）。paymentStatusOriginalText 逐字抄录图中状态原文（如「支付成功」「待付款」「退款成功」），看不出则 null。注意「待收货/配送中/已发货」说明订单已支付，按 completed；只有「待付款」才是 pending。
12. transactions 每笔必须带 confidence 对象：{"amount":0~1,"direction":0~1,"paymentStatus":0~1,"date":0~1,"merchant":0~1,"paymentChannel":0~1}，表示你对每个字段判断的把握。看不准的字段如实给低分，禁止为凑齐输出编造高分。
13. 分类只给语义候选，禁止猜测用户账本里的分类名或编号：categoryCandidate=图中商户/商品原文；normalizedCategoryCandidate=归一化品类词（如「咖啡」「打车」「超市」）；semanticCategoryHint=语义大类，从 餐饮/交通/购物/娱乐/居住/医疗/教育/通讯/其他 中选。看不出则 null。

【完整输出示例】一张瑞幸咖啡微信支付成功小票（¥19.90，2026-09-14）的唯一正确输出：
{"schemaVersion":2,"imageType":"receipt","confidence":0.95,"paymentStatus":"completed","paymentStatusOriginalText":"支付成功","summary":"瑞幸咖啡微信支付小票","merchant":"瑞幸咖啡","paidAt":"2026-09-14","paymentChannel":"微信支付","currency":"CNY","amountOriginalText":"¥19.90","items":[{"name":"生椰拿铁","amount":19.9}],"transactions":[{"type":"expense","amount":19.9,"note":"瑞幸咖啡","date":"2026-09-14","amountOriginalText":"¥19.90","confidence":{"amount":0.99,"direction":0.99,"paymentStatus":0.98,"date":0.94,"merchant":0.96,"paymentChannel":0.97},"categoryCandidate":"瑞幸咖啡","normalizedCategoryCandidate":"咖啡","semanticCategoryHint":"餐饮"}],"rejectReason":null}

【货币判定示例】输入是一张外币小票（Total $14.47，VISA 支付）时，唯一正确输出是外币拒识——currency 和 amountOriginalText 必须保留美元原文，绝不能写成人民币：
{"schemaVersion":2,"imageType":"foreign_currency","confidence":0.95,"paymentStatus":"completed","paymentStatusOriginalText":null,"summary":"Whole Foods 美元消费小票","merchant":"Whole Foods Market","paidAt":null,"paymentChannel":"8821","currency":"USD","amountOriginalText":"$14.47","items":[{"name":"Organic Bananas","amount":3.99}],"transactions":[],"rejectReason":"外币消费暂不支持记账"}`;

function loadProductionPrompt() {
  try {
    const json = JSON.parse(
      fs.readFileSync(path.join(repoRoot, 'HoloBackend/src/prompts/defaultPrompts.json'), 'utf8'),
    );
    const content = typeof json.vision_extraction === 'string' ? json.vision_extraction : json.vision_extraction?.content;
    if (typeof content === 'string' && content.length > 0) {
      return content.replaceAll('{{todayISODate}}', new Date().toISOString().slice(0, 10));
    }
  } catch {
    // 仓库不齐时走嵌入兜底
  }
  return EMBEDDED_PROMPT;
}
const PROMPT = loadProductionPrompt();

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
        // 与生产 config.routes.vision_extraction.maxTokens=4000 对齐：
        // v2 理解单带字段级 confidence，1500 会截断 JSON（qwen 6 张断尾实锤）
        max_tokens: 4000,
        ...(cfg.reasoningEffort ? { reasoning_effort: cfg.reasoningEffort } : {}),
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
// 生产 understandingContract.js 同款 v2 支付状态护栏（pending/failed/cancelled 强制清空）
const AUTO_INELIGIBLE_STATUS = new Set(['pending', 'failed', 'cancelled']);
const STATUS_IMAGE_TYPE = { pending: 'pending_order', failed: 'unrelated', cancelled: 'unrelated' };
function applyProductionGuard(p) {
  const txt = String(p.amountOriginalText || '');
  if ((p.transactions || []).length > 0 && FOREIGN_MONEY.test(txt)) {
    p.transactions = [];
    p.imageType = 'foreign_currency';
    p.rejectReason = p.rejectReason || '检测到外币金额，暂不支持外币记账';
    p.__guardApplied = true;
    return p;
  }
  const status = typeof p.paymentStatus === 'string' ? p.paymentStatus.trim().toLowerCase() : '';
  if ((p.transactions || []).length > 0 && AUTO_INELIGIBLE_STATUS.has(status)) {
    p.transactions = [];
    p.imageType = STATUS_IMAGE_TYPE[status];
    p.rejectReason = p.rejectReason || `支付状态为 ${status}，不记账`;
    p.__statusGuardApplied = true;
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

  const checks = { type: typeOK, reject: true, amounts: true, types: true, date: true, merchant: true, channel: true, paymentStatus: true };
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
    if (exp.paymentStatus) {
      checks.paymentStatus = String(p.paymentStatus || 'unknown') === exp.paymentStatus;
    }
  }
  return { pass: Object.values(checks).every(Boolean), lenient: false, checks };
}

// ---------- v2 自动落账门禁仿真（2026-09-14 完整方案 §8/§28-M0）----------
// 以生产 ReceiptBookingPolicy 的首版规则仿真：单笔 + completed/refunded + 字段级置信度 ≥ 阈值
// → autoCommit（§26.3：退款需 refunded，方向证据由 type=income 表达）。
// auto-WRONG（金额或方向错误的自动入账）是发布红线指标，必须为 0。
const GATE_THRESHOLDS = [0.6, 0.7, 0.8, 0.9, 0.95, 0.99];
function simulateGate(exp, p, threshold) {
  if (exp.reject) return 'intercepted';
  if (exp.acceptRejectToo && (p.transactions || []).length === 0) return 'rejected-lenient';
  const txs = Array.isArray(p.transactions) ? p.transactions : [];
  if (txs.length !== 1) return 'review'; // 多笔/零笔 → 复核或拒识
  if (p.__guardApplied || p.__statusGuardApplied) return 'review'; // 护栏改写 → 只能复核
  if (!['completed', 'refunded'].includes(String(p.paymentStatus || 'unknown'))) return 'review';
  const c = txs[0]?.confidence || {};
  const required = ['amount', 'direction', 'paymentStatus'];
  if (required.some((k) => typeof c[k] !== 'number' || c[k] < threshold)) return 'review';
  const amountOK = exp.amounts.length === 1 && near(exp.amounts[0], Math.abs(Number(txs[0].amount) || 0));
  const typeOK = txs[0]?.type === exp.types[0];
  return amountOK && typeOK ? 'auto-correct' : 'auto-WRONG';
}

function runGateSim(rows, manifest) {
  const table = {};
  for (const threshold of GATE_THRESHOLDS) {
    const outcomes = rows.map((r) => {
      const item = manifest.find((m) => m.file === r.file);
      if (!item || !r.parsed) return 'parse-failed';
      return simulateGate(item.expect, r.parsed, threshold);
    });
    const count = (k) => outcomes.filter((o) => o === k).length;
    const eligible = count('auto-correct') + count('auto-WRONG');
    table[threshold] = {
      autoCorrect: count('auto-correct'),
      autoWrong: count('auto-WRONG'),
      eligible,
      autoAccuracy: eligible ? (count('auto-correct') / eligible * 100).toFixed(1) + '%' : '-',
      review: count('review'),
      intercepted: count('intercepted'),
      rejectedLenient: count('rejected-lenient'),
      parseFailed: count('parse-failed'),
    };
  }
  return table;
}

function printGateSim(table) {
  console.log(`\n—— v2 自动落账门禁仿真（2026-09-14 方案 §8）——`);
  for (const [threshold, g] of Object.entries(table)) {
    console.log(`T=${Number(threshold).toFixed(2)}  自动落账 ${g.autoCorrect}/${g.eligible} (准确率 ${g.autoAccuracy})  【红线·错误自动入账 ${g.autoWrong}】  转复核 ${g.review}  拦截 ${g.intercepted}`);
  }
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

// --resim <results.json>：用已存的模型输出离线重算门禁阈值表，不调 API（调阈值时零成本复算）
const resimFile = arg('--resim', '');
if (resimFile) {
  const stored = JSON.parse(fs.readFileSync(resimFile, 'utf8'));
  printGateSim(runGateSim(stored.rows, JSON.parse(fs.readFileSync(path.join(corpusDir, 'manifest.json'), 'utf8'))));
  process.exit(0);
}

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
  console.log(`支付状态准确: ${billableRows.filter((r) => r.checks?.paymentStatus).length}/${billable.length}`);
  console.log(`【安全红线】资金流转拦截召回: ${interceptHit.length}/${interceptItems.length}  误拒(该记没记): ${falseRejects.length}/${billable.length}`);
  console.log(`tokens: prompt合计 ${promptTokens}, 单均 ${(promptTokens / Math.max(rows.length, 1)).toFixed(0)}, 总 ${tokens}`);

  // v2 门禁仿真：按候选阈值输出自动落账命中率与红线指标，供选阈值用（§28-M0.4）
  const gateSim = runGateSim(rows, manifest);
  printGateSim(gateSim);

  fs.writeFileSync(path.join(resultsDir, `${cfg.model}.json`), JSON.stringify({ model: cfg.model, ranAt: new Date().toISOString(), promptSchemaVersion: 2, summary: { pass: scored.filter((r) => r.pass).length, total: manifest.length }, gateSim, rows }, null, 2));
  console.log(`结果已写 results/${cfg.model}.json`);
}
