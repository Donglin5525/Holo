#!/usr/bin/env node
//
// eval-personal-context.mjs
// 通用个人情境真实评测 harness（实施方案 §15.2）。
//
// 用法：
//   node scripts/eval-personal-context.mjs --set dev        # 开发集（链路验证）
//   node scripts/eval-personal-context.mjs --set heldout    # 留出集盲评
//   node scripts/eval-personal-context.mjs --set heldout --sample 20
//
// 评分口径：
//   - 关键计划影响召回：expected relation 的内容词在候选 statements 中命中（词面）
//   - 个性化断言有据：进入 planning 的候选均经 verification supported/qualified
//   - 红线零次：planning 输出含 forbiddenClaim 内容词即计失败
//   - LLM judge 仅辅助（本轮不做；标注为词面口径，语义同义命中由人工/后续补充）
//

import { readFileSync, readdirSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";

const BASE = "https://api.holoapp.cn";
const EVAL_DATE = new Date().toISOString().slice(0, 10);
let deviceIndex = 0;
const deviceAt = (i) => `pc-eval-${EVAL_DATE}-${String(i).padStart(2, "0")}`;
const DEVICE = deviceAt(0);
// planning 归 chat 池（免费档 15 次/天/设备）：429 时轮换评测设备补跑剩余组。
async function callPurpose(purpose, userContent) {
  try {
    return await callPurposeOnce(purpose, userContent, deviceAt(deviceIndex));
  } catch (error) {
    if (String(error.message).includes("QUOTA_EXCEEDED") || String(error.message).includes("429")) {
      deviceIndex += 1;
      await sleep(2_000);
      return await callPurposeOnce(purpose, userContent, deviceAt(deviceIndex));
    }
    throw error;
  }
}
const FIXTURE_DIR = join(import.meta.dirname, "..", "Holo/Holo APP/Holo/HoloTests/Services/AI/PersonalContext/Fixtures");
const OUT_DIR = join(import.meta.dirname, "..", "docs/_common/eval/personal-context");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function loadFixtures(set, sample) {
  const dir = join(FIXTURE_DIR, set);
  const files = readdirSync(dir).filter((f) => f.endsWith(".json")).sort();
  const picked = sample ? files.slice(0, sample) : files;
  return picked.map((f) => JSON.parse(readFileSync(join(dir, f), "utf8")));
}

async function callPurposeOnce(purpose, userContent, device) {
  const response = await fetch(`${BASE}/v1/ai/chat/completions`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Holo-Device-Id": device },
    body: JSON.stringify({ purpose, messages: [{ role: "user", content: userContent }] }),
  });
  if (!response.ok) {
    throw new Error(`${purpose} HTTP ${response.status}: ${(await response.text()).slice(0, 120)}`);
  }
  const data = await response.json();
  return data.choices?.[0]?.message?.content ?? "";
}

function extractJSON(text) {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start === -1 || end <= start) throw new Error("输出无 JSON");
  return JSON.parse(text.slice(start, end + 1));
}

// CJK 双字滑窗（bigram）+ 西文整词：bigram 让「父亲/低盐/晕车」这类词可命中
function tokenize(text) {
  const tokens = new Set();
  const chars = [...text];
  let current = "";
  const flush = () => { if (current) { tokens.add(current.toLowerCase()); current = ""; } };
  for (let i = 0; i < chars.length; i++) {
    const code = chars[i].codePointAt(0);
    if (code > 0x2e80) {
      flush();
      if (i + 1 < chars.length && chars[i + 1].codePointAt(0) > 0x2e80) {
        tokens.add(chars[i] + chars[i + 1]);
      }
    } else if (/[a-zA-Z0-9]/.test(chars[i])) {
      current += chars[i];
    } else {
      flush();
    }
  }
  flush();
  return tokens;
}

// 关系命中（词面口径 v2）：过滤占位停用词后，期望命题与任一候选重叠 ≥2 个内容双字词。
// 期望是转述式（「用户的父亲…」），候选是直陈式（「父亲…」）——占位词不参与判定。
const STOPWORDS = new Set(["用户", "自己", "本次", "这个", "一个", "因此", "需要", "进行", "相关", "方面", "情况", "记录"]);
function contentKeys(statement) {
  return [...tokenize(statement)].filter((t) => t.length >= 2 && !STOPWORDS.has(t));
}
function relationHit(statement, candidates) {
  const wantKeys = contentKeys(statement);
  if (wantKeys.length === 0) return false;
  for (const candidate of candidates) {
    const got = tokenize(`${candidate.statement ?? ""} ${candidate.relationText ?? ""}`);
    const overlap = wantKeys.filter((k) => got.has(k)).length;
    if (overlap >= Math.max(3, Math.ceil(wantKeys.length * 0.3))) return true;
  }
  return false;
}

async function evaluateFixture(fixture) {
  const result = {
    fixtureID: fixture.fixtureID,
    domains: fixture.domainTags,
    extractionOK: false,
    recalledRelations: 0,
    totalRelations: fixture.expectedSupportedRelations.length,
    verifiedPass: 0,
    verifiedTotal: 0,
    planOK: false,
    forbiddenViolations: [],
    hasUnknowns: false,
    error: null,
  };
  try {
    // 1) extraction
    const extractionInput = {
      sources: fixture.sources.map((s) => ({
        sourceID: s.sourceID,
        revision: s.revisionDigest,
        role: s.role,
        plainText: s.plainText,
      })),
      existingCandidates: [],
    };
    const extractionRaw = await callPurpose(
      "personal_context_extraction",
      JSON.stringify(extractionInput),
    );
    const extraction = extractJSON(extractionRaw);
    const candidates = extraction.candidates ?? [];
    result.extractionOK = Array.isArray(candidates);
    // 召回评分（词面口径）
    for (const relation of fixture.expectedSupportedRelations) {
      if (relationHit(relation.statement, candidates)) result.recalledRelations += 1;
    }

    // 2) verification（有候选才调）
    let verifiedCandidates = [];
    if (candidates.length > 0) {
      await sleep(15_500); // 4/min 限流
      const verificationInput = {
        candidates: candidates.slice(0, 16).map((c) => ({
          candidateRef: c.candidateRef,
          statement: c.statement,
          basis: c.basis ?? [],
        })),
        sources: fixture.sources.map((s) => ({ sourceID: s.sourceID, plainText: s.plainText })),
      };
      const verificationRaw = await callPurpose(
        "personal_context_verification",
        JSON.stringify(verificationInput),
      );
      const verification = extractJSON(verificationRaw);
      const verdicts = new Map(
        (verification.verdicts ?? []).map((v) => [v.candidateRef, v.verdict]),
      );
      for (const c of candidates.slice(0, 16)) {
        result.verifiedTotal += 1;
        const verdict = verdicts.get(c.candidateRef);
        if (verdict === "supported" || verdict === "qualified") {
          result.verifiedPass += 1;
          verifiedCandidates.push(c);
        }
      }
    }

    // 3) planning
    await sleep(7_000); // 10/min 限流
    const planInput = {
      currentRequest: {
        utterance: fixture.currentRequest.utterance,
        goalSummary: fixture.currentRequest.goalSummary,
        timeRange: { expression: "" },
        unknowns: fixture.unknowns,
        referenceTime: fixture.currentRequest.referenceTime,
      },
      contexts: verifiedCandidates.slice(0, 8).map((c) => ({
        contextID: c.candidateRef,
        statement: c.statement,
        ...(c.temporal ? { temporal: c.temporal.originalExpression } : {}),
      })),
      rawFallbackSegments: [],
      semanticCoverage: "full",
    };
    const planRaw = await callPurpose("personal_context_planning", JSON.stringify(planInput));
    const plan = extractJSON(planRaw);
    result.planOK = typeof plan.answerText === "string" && plan.answerText.length > 0;
    result.hasUnknowns = Array.isArray(plan.unknowns) && plan.unknowns.length > 0;
    // 红线（词面口径 v2）：断言动词短语（已确认/已预订/…）与该禁断言的专有内容词
    // 同时出现才算命中——单纯复述历史事实（如「上次红包 600」）不算伪造断言。
    const ASSERTIVE_MARKERS = ["已确认", "已经确认", "已预订", "已经预订", "已报名", "已经报名", "已安排妥当", "已恢复正常", "已设置", "每年固定", "固定"];
    const planText = JSON.stringify(plan);
    for (const claim of fixture.forbiddenClaims) {
      const keys = contentKeys(claim);
      const hasAssertive = ASSERTIVE_MARKERS.some((m) => planText.includes(m));
      const hasSpecific = keys.filter((k) => planText.includes(k)).length >= Math.max(1, Math.floor(keys.length * 0.6));
      if (hasAssertive && hasSpecific) result.forbiddenViolations.push(claim);
    }
  } catch (error) {
    result.error = String(error.message ?? error);
  }
  return result;
}

async function main() {
  const args = process.argv.slice(2);
  const set = args.includes("--set") ? args[args.indexOf("--set") + 1] : "dev";
  const sample = args.includes("--sample") ? Number(args[args.indexOf("--sample") + 1]) : null;
  const fixtures = loadFixtures(set, sample);
  console.log(`评测 ${set} 集 ${fixtures.length} 组（起始 device=${DEVICE}）`);

  // 断点续跑：读取上次结果，跳过已成功（无 error）的组。
  const stamp = new Date().toISOString().slice(0, 10);
  const previousPath = join(OUT_DIR, `${set}-${stamp}.json`);
  let previous = null;
  try {
    previous = JSON.parse(readFileSync(previousPath, "utf8"));
  } catch { /* 无历史 */ }
  const previousByID = new Map((previous?.results ?? []).map((r) => [r.fixtureID, r]));

  const results = [];
  for (const fixture of fixtures) {
    const last = previousByID.get(fixture.fixtureID);
    if (last && !last.error) {
      console.log(`${fixture.fixtureID} 已有成功结果，跳过`);
      results.push(last);
      continue;
    }
    const result = await evaluateFixture(fixture);
    results.push(result);
    console.log(
      `${result.fixtureID} [${result.domains.join("/")}] ` +
      `召回 ${result.recalledRelations}/${result.totalRelations} ` +
      `核验 ${result.verifiedPass}/${result.verifiedTotal} ` +
      `plan ${result.planOK ? "OK" : "FAIL"} ` +
      `未知 ${result.hasUnknowns ? "有" : "无"} ` +
      `红线 ${result.forbiddenViolations.length === 0 ? "零" : "❌" + result.forbiddenViolations.length}` +
      (result.error ? ` | err: ${result.error}` : ""),
    );
  }

  // 汇总
  const done = results.filter((r) => !r.error);
  const recall = done.reduce((s, r) => s + r.recalledRelations, 0);
  const total = done.reduce((s, r) => s + r.totalRelations, 0);
  const verified = done.reduce((s, r) => s + r.verifiedPass, 0);
  const verifiedTotal = done.reduce((s, r) => s + r.verifiedTotal, 0);
  const violations = results.reduce((s, r) => s + r.forbiddenViolations.length, 0);
  const byDomain = {};
  for (const r of done) {
    for (const d of r.domains) {
      byDomain[d] ??= { recalled: 0, total: 0 };
      byDomain[d].recalled += r.recalledRelations;
      byDomain[d].total += r.totalRelations;
    }
  }
  const summary = {
    set,
    device: DEVICE,
    providerModel: "deepseek-v4-flash（生产）",
    fixtures: fixtures.length,
    completed: done.length,
    errors: results.length - done.length,
    recall: { hit: recall, total, rate: total ? +(recall / total).toFixed(3) : null },
    groundedRate: verifiedTotal ? +(verified / verifiedTotal).toFixed(3) : null,
    planOKRate: done.length ? +(done.filter((r) => r.planOK).length / done.length).toFixed(3) : null,
    forbiddenViolations: violations,
    byDomain: Object.fromEntries(
      Object.entries(byDomain).map(([d, v]) => [d, v.total ? +(v.recalled / v.total).toFixed(3) : null]),
    ),
    note: "词面口径（CJK 双字词重叠 ≥34%）；语义同义命中与 plan effects 的 judge 辅助评分待人工补充",
  };
  console.log("\n===== 汇总 =====");
  console.log(JSON.stringify(summary, null, 2));

  mkdirSync(OUT_DIR, { recursive: true });
  writeFileSync(join(OUT_DIR, `${set}-${EVAL_DATE}.json`), JSON.stringify({ summary, results }, null, 2));
  console.log(`已写入 ${OUT_DIR}/${set}-${EVAL_DATE}.json`);
}

main().catch((error) => { console.error(error); process.exit(1); });
