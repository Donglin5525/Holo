#!/usr/bin/env node
/**
 * W4 协议层评测跑批 · 「想法自动整理增强」
 *
 * 把冻结合成评测集灌进后端真实校验器(协议真源,零 mock):
 *   - followupSchema.validateFollowupRequest / validateFollowupModelOutput(§6 C2 verify-followup,含 quoteAlignment 逐字回源)
 *   - semanticRelateSchema.validateRelateRequest(schema 4 definition 校验,§4 A1 规则 ≤240 UTF-16)
 *
 * 三段评测:
 *   A 正向集:语料 groundTruth 的 61 对关系逐对组装合法 verify-followup 响应 + 3 条预标脉络,
 *            应全部通过(none/insufficient 的证据按 labels-key 约定置 null)。
 *   B 结构反证集:从语料真实文本派生的协议违例,应 100% 被拒(伪造引文/range 越界倒置/
 *            none 带证据/thread 缺锚点/thread <3/标题超 32/windowRef 虚构)。
 *   C schema 4:rule-samples.json 14 条规则的 definition ≤240 应全过,派生 241 超限例应拒。
 *
 * 用法:任意目录 `node <本文件路径>`(以脚本位置定位数据文件)。零 npm 依赖,仅 Node 内置模块
 * + 本仓库两个校验器源文件。每次运行幂等覆盖 protocol-eval-report.json。
 * 退出码:全部符合预期 0,任何失败 1。
 */
'use strict';

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const EVAL_DIR = path.resolve(__dirname, '..');
const REPO_ROOT = path.resolve(EVAL_DIR, '..', '..', '..', '..', '..');
const REPORT_PATH = path.join(EVAL_DIR, 'protocol-eval-report.json');

const ESTABLISHED = new Set(['continues', 'adds_example', 'contrasts', 'revises']);

// 协议真源:后端真实校验器,非复刻、非 mock。
const { validateFollowupRequest, validateFollowupModelOutput, FOLLOWUP_LIMITS, THOUGHT_FOLLOWUP_POLICY_VERSION } =
  await import(pathToFileURL(path.join(REPO_ROOT, 'HoloBackend', 'src', 'thoughts', 'followupSchema.js')).href);
const { validateRelateRequest, RELATE_LIMITS } =
  await import(pathToFileURL(path.join(REPO_ROOT, 'HoloBackend', 'src', 'thoughts', 'semanticRelateSchema.js')).href);

function loadJson(file) {
  return JSON.parse(fs.readFileSync(path.join(EVAL_DIR, file), 'utf8'));
}

const corpus = loadJson('synthetic-corpus.json');
const ruleSamples = loadJson('rule-samples.json');
const notes = corpus.notes;
const byId = new Map(notes.map((n) => [n.id, n]));

// ---------- 通用小件 ----------

let opSeq = 0;
function makeOperationId() {
  opSeq += 1;
  // validateFollowupRequest 要求 UUID;固定前缀 + 序号尾,确定性且可复跑。
  return `9f2bb45b-5dd4-457d-88cc-${opSeq.toString(16).padStart(12, '0')}`;
}

/** 每条笔记一个 W0 全文窗口;协议窗口上限 600 UTF-16,冻结语料实测全部满足,越界即算语料/协议错配,大声失败。 */
function buildWindows(note) {
  if (note.text.length > FOLLOWUP_LIMITS.windowTextMaxUTF16) {
    throw new Error(`${note.id} text ${note.text.length} UTF-16 超过单窗口上限 ${FOLLOWUP_LIMITS.windowTextMaxUTF16},协议层无法整篇装窗`);
  }
  return [{ ref: 'W0', text: note.text }];
}
const windowsById = new Map(notes.map((n) => [n.id, buildWindows(n)]));

function locateEvidence(windows, quote) {
  const w = windows.find((x) => x.text.includes(quote));
  if (!w) throw new Error(`引文未逐字命中任何窗口:「${quote}」`);
  const start = w.text.indexOf(quote);
  return { windowRef: w.ref, range: [start, start + quote.length] };
}

function noteToRequestNote(note) {
  return { ref: note.id, createdAtMs: note.createdAtMs, windows: windowsById.get(note.id) };
}

/** 组装一对关系的合法 verify-followup 请求体(锚点=较晚侧,toId=较早侧)。 */
function buildPairRequestBody(anchorNote, otherNote) {
  return {
    schemaVersion: 1,
    operationId: makeOperationId(),
    policyVersion: THOUGHT_FOLLOWUP_POLICY_VERSION,
    scopeTitle: '产品思考',
    anchorRef: anchorNote.id,
    notes: [noteToRequestNote(anchorNote), noteToRequestNote(otherNote)],
  };
}

/** 按 §6 C2 组装单条决定:成立关系带双侧真实证据;none/insufficient 三字段全 null(labels-key §3)。 */
function buildDecision(anchorNote, otherNote, relation) {
  if (!ESTABLISHED.has(relation.relation)) {
    return { otherRef: otherNote.id, relation: relation.relation, reason: null, anchorEvidence: null, otherEvidence: null };
  }
  const anchorLoc = locateEvidence(windowsById.get(anchorNote.id), relation.evidenceSpans[0]);
  const otherLoc = locateEvidence(windowsById.get(otherNote.id), relation.evidenceSpans[1]);
  return {
    otherRef: otherNote.id,
    relation: relation.relation,
    reason: relation.reason,
    anchorEvidence: { windowRef: anchorLoc.windowRef, quote: relation.evidenceSpans[0], rangeUTF16: anchorLoc.range },
    otherEvidence: { windowRef: otherLoc.windowRef, quote: relation.evidenceSpans[1], rangeUTF16: otherLoc.range },
  };
}

function runFollowup(body, decisions, thread) {
  const parsed = validateFollowupRequest(body); // 非法请求抛 GatewayError
  return validateFollowupModelOutput({ decisions, thread }, parsed);
}

// ---------- 语料分母复核(与 README 冻结表对照,不一致视为语料被污染,直接失败) ----------

const relationPairs = [];
for (const note of notes) {
  for (const relation of note.groundTruth.relations) {
    relationPairs.push({ anchor: note, other: byId.get(relation.toId), relation });
  }
}
const establishedPairs = relationPairs.filter((p) => ESTABLISHED.has(p.relation.relation));
const negativePairs = relationPairs.filter((p) => !ESTABLISHED.has(p.relation.relation));
const threadRegistry = new Map();
for (const note of notes) {
  for (const t of note.groundTruth.threads) threadRegistry.set(t.title, t);
}

const denominatorErrors = [];
function expectDenominator(actual, expected, label) {
  if (actual !== expected) denominatorErrors.push(`${label}: 实际 ${actual},冻结分母 ${expected}`);
}
expectDenominator(notes.length, 50, '语料笔记');
expectDenominator(relationPairs.length, 61, '预标注关系对');
expectDenominator(establishedPairs.length, 45, '成立关系');
expectDenominator(negativePairs.length, 16, '负向关系(none/insufficient)');
expectDenominator(threadRegistry.size, 3, '预标脉络');
for (const t of threadRegistry.values()) {
  const members = t.memberIds.map((id) => byId.get(id));
  const anchor = members.reduce((a, b) => (b.createdAtMs > a.createdAtMs ? b : a));
  if (t.memberIds[0] !== anchor.id) denominatorErrors.push(`脉络「${t.title}」memberIds[0] 不是最晚成员(锚点)`);
  for (const m of members) {
    if (m.id === anchor.id) continue;
    const rel = anchor.groundTruth.relations.find((r) => r.toId === m.id);
    if (!rel || !ESTABLISHED.has(rel.relation)) denominatorErrors.push(`脉络「${t.title}」锚点 ${anchor.id} 对 ${m.id} 无成立关系`);
  }
}
if (denominatorErrors.length > 0) {
  console.error('语料分母与冻结表不一致,按 README 约定视为语料被污染,终止:');
  for (const e of denominatorErrors) console.error('  - ' + e);
  process.exit(1);
}

// ---------- 评测结果收集 ----------

const report = {
  reportVersion: 1,
  tool: 'eval/tools/run-protocol-eval.mjs',
  generatedAt: new Date().toISOString(),
  inputs: {
    corpus: 'synthetic-corpus.json(2026-11-16 冻结)',
    hardNegatives: 'hard-negatives.json(负例语义已由语料 groundTruth 承载,本层不单独跑批)',
    ruleSamples: 'rule-samples.json',
    validators: {
      followup: 'HoloBackend/src/thoughts/followupSchema.js(含 quoteAlignment 逐字回源)',
      semanticRelate: 'HoloBackend/src/thoughts/semanticRelateSchema.js',
      policyVersion: THOUGHT_FOLLOWUP_POLICY_VERSION,
    },
    limits: { quoteMaxUTF16: FOLLOWUP_LIMITS.quoteMaxUTF16, reasonMaxUTF16: FOLLOWUP_LIMITS.reasonMaxUTF16, threadTitleMaxUTF16: FOLLOWUP_LIMITS.threadTitleMaxUTF16, definitionMaxUTF16: RELATE_LIMITS.definitionMaxUTF16 },
  },
  corpusDenominators: { notes: notes.length, relationPairs: relationPairs.length, established: establishedPairs.length, negative: negativePairs.length, threads: threadRegistry.size },
  sections: {},
  summary: {},
};

function failDetail(label, err) {
  return { error: err && err.message ? err.message : String(err), code: err && err.code ? err.code : undefined };
}

// ========== A. 正向集:61 对关系 + 3 条脉络,应全部通过 ==========

const positiveCases = [];
let positivePassed = 0;

for (const pair of relationPairs) {
  const caseId = `P-REL-${pair.anchor.id}-${pair.other.id}`;
  let ok = true;
  let detail = '';
  try {
    const body = buildPairRequestBody(pair.anchor, pair.other);
    const decision = buildDecision(pair.anchor, pair.other, pair.relation);
    const result = runFollowup(body, [decision], null);
    if (result.malformed) {
      ok = false;
      detail = `协议拒绝:${result.reason}`;
    } else {
      // canonical 回显断言:成立关系回显逐字引文与服务端重算区间;负向关系回显全 null。
      const d = result.decisions[0];
      if (ESTABLISHED.has(pair.relation.relation)) {
        const aSpan = pair.relation.evidenceSpans[0];
        const oSpan = pair.relation.evidenceSpans[1];
        if (d.anchorEvidence.quote !== aSpan || d.otherEvidence.quote !== oSpan) {
          ok = false; detail = 'canonical 引文回显与语料引文不一致';
        } else if (d.anchorEvidence.rangeUTF16[1] - d.anchorEvidence.rangeUTF16[0] !== aSpan.length
            || d.otherEvidence.rangeUTF16[1] - d.otherEvidence.rangeUTF16[0] !== oSpan.length) {
          ok = false; detail = '服务端重算的 rangeUTF16 长度与引文不符';
        }
      } else if (d.reason !== null || d.anchorEvidence !== null || d.otherEvidence !== null) {
        ok = false; detail = '负向关系 canonical 回显非全 null';
      }
    }
  } catch (err) {
    ok = false;
    detail = JSON.stringify(failDetail('validator threw', err));
  }
  if (ok) positivePassed += 1;
  positiveCases.push({ id: caseId, kind: 'relationPair', anchor: pair.anchor.id, other: pair.other.id, relation: pair.relation.relation, result: ok ? 'PASS' : 'FAIL', detail });
}

for (const [title, t] of threadRegistry) {
  const caseId = `P-THR-${t.memberIds[0]}`;
  let ok = true;
  let detail = '';
  try {
    const members = t.memberIds.map((id) => byId.get(id));
    const anchor = members[0];
    const others = members.slice(1);
    const body = {
      schemaVersion: 1,
      operationId: makeOperationId(),
      policyVersion: THOUGHT_FOLLOWUP_POLICY_VERSION,
      scopeTitle: '产品思考',
      anchorRef: anchor.id,
      notes: members.map(noteToRequestNote),
    };
    const decisions = others.map((m) => {
      const rel = anchor.groundTruth.relations.find((r) => r.toId === m.id);
      if (!rel) throw new Error(`脉络「${title}」锚点 ${anchor.id} 缺少对 ${m.id} 的关系标注`);
      return buildDecision(anchor, m, rel);
    });
    const threadOut = { title: t.title, question: t.question, memberRefs: t.memberIds };
    const result = runFollowup(body, decisions, threadOut);
    if (result.malformed) {
      ok = false;
      detail = `协议拒绝:${result.reason}`;
    } else if (!result.thread || result.thread.title !== t.title || JSON.stringify(result.thread.memberRefs) !== JSON.stringify(t.memberIds)) {
      ok = false;
      detail = 'thread 回显与预标脉络不一致';
    }
  } catch (err) {
    ok = false;
    detail = JSON.stringify(failDetail('validator threw', err));
  }
  if (ok) positivePassed += 1;
  positiveCases.push({ id: caseId, kind: 'thread', title, memberIds: t.memberIds, result: ok ? 'PASS' : 'FAIL', detail });
}

report.sections.positive = {
  denominator: relationPairs.length + threadRegistry.size,
  passed: positivePassed,
  failedCount: positiveCases.length - positivePassed,
  breakdown: {
    relationPairs: { denominator: relationPairs.length, passed: positiveCases.filter((c) => c.kind === 'relationPair' && c.result === 'PASS').length },
    threads: { denominator: threadRegistry.size, passed: positiveCases.filter((c) => c.kind === 'thread' && c.result === 'PASS').length },
  },
  cases: positiveCases,
};

// ========== B. 结构反证集:从语料真实文本派生,应 100% 被拒 ==========

// 基线取材(全部真实语料对):
const base44to04 = establishedPairs.find((p) => p.anchor.id === 'N44' && p.other.id === 'N04'); // revises
const base44to24 = establishedPairs.find((p) => p.anchor.id === 'N44' && p.other.id === 'N24'); // continues
const base50to44 = establishedPairs.find((p) => p.anchor.id === 'N50' && p.other.id === 'N44'); // continues
const base34to07 = establishedPairs.find((p) => p.anchor.id === 'N34' && p.other.id === 'N07'); // adds_example
const base44to16 = negativePairs.find((p) => p.anchor.id === 'N44' && p.other.id === 'N16'); // none(H01 转述)
const base27to18 = negativePairs.find((p) => p.anchor.id === 'N27' && p.other.id === 'N18'); // none(H09 计划)
const threadT1 = threadRegistry.get('AI 做决定的边界');

function baselinePair(anchorNote, otherNote, relation) {
  return { body: buildPairRequestBody(anchorNote, otherNote), decisions: [buildDecision(anchorNote, otherNote, relation)], thread: null };
}

/** 跑一个反证例:预期 malformed=true 且 reason=expectedReason。 */
function runNegative(caseId, group, derivation, expectedReason, build) {
  let ok = true;
  let detail = '';
  let actual = null;
  try {
    const { body, decisions, thread } = build();
    const result = runFollowup(body, decisions, thread);
    actual = result.malformed ? { malformed: true, reason: result.reason } : { malformed: false, accepted: true };
    if (!result.malformed) {
      ok = false;
      detail = '预期拒绝,实际被接受';
    } else if (result.reason !== expectedReason) {
      ok = false;
      detail = `拒绝原因不符:预期 ${expectedReason},实际 ${result.reason}`;
    }
  } catch (err) {
    ok = false;
    actual = { threw: true };
    detail = JSON.stringify(failDetail('validator threw(反证例不允许在请求装配层抛错)', err));
  }
  return { id: caseId, group, derivation, expectation: 'reject', expectedReason, actual, result: ok ? 'PASS(按预期拒绝)' : 'FAIL', detail };
}

const negativeCases = [];

// B1 伪造引文(quote 改一字)——排版对齐只容忍空白/大小写/引号形态,实字改动必须拒。
{
  const quote = base44to04.relation.evidenceSpans[0]; // 「低风险自动,高影响先确认」
  const forged = quote.replace('确', '批');
  negativeCases.push(runNegative('X01', 'G1-伪造引文', `N44→N04 revises,锚侧引文「${quote}」改一字为「${forged}」`, 'anchor_evidence_invalid', () => {
    const base = baselinePair(base44to04.anchor, base44to04.other, base44to04.relation);
    base.decisions[0].anchorEvidence.quote = forged;
    return base;
  }));
}
{
  const quote = base44to24.relation.evidenceSpans[1]; // 「出错的时候是真难纠正」(较早侧/N24)
  const forged = quote.replace('纠', '改');
  negativeCases.push(runNegative('X02', 'G1-伪造引文', `N44→N24 continues,对方侧引文「${quote}」改一字为「${forged}」`, 'other_evidence_invalid', () => {
    const base = baselinePair(base44to24.anchor, base44to24.other, base44to24.relation);
    base.decisions[0].otherEvidence.quote = forged;
    return base;
  }));
}

// B2 rangeUTF16 越界/倒置——结构检查必拒;窗口内错位由服务端按 canonical quote 重算(设计如此,见报告说明)。
{
  const wLen = windowsById.get('N50')[0].text.length;
  negativeCases.push(runNegative('X03', 'G2-range越界/错位', `N50→N44 continues,锚侧 rangeUTF16 端点越界:${wLen}+5 > 窗口长 ${wLen}`, 'anchor_evidence_invalid', () => {
    const base = baselinePair(base50to44.anchor, base50to44.other, base50to44.relation);
    base.decisions[0].anchorEvidence.rangeUTF16 = [0, wLen + 5];
    return base;
  }));
}
negativeCases.push(runNegative('X04', 'G2-range越界/错位', 'N50→N44 continues,对方侧 rangeUTF16 起点>终点:[10,5]', 'other_evidence_invalid', () => {
  const base = baselinePair(base50to44.anchor, base50to44.other, base50to44.relation);
  base.decisions[0].otherEvidence.rangeUTF16 = [10, 5];
  return base;
}));

// B3 none 带证据——labels-key §3:负向关系的 reason 与双侧证据必须全 null;语料里的「表面相似」审计引文照抄即拒。
negativeCases.push(runNegative('X05', 'G3-none带证据', 'N44→N16 none(H01 转述),照抄语料审计引文两侧 + reason(模型最易犯的形态)', 'negative_decision_fields_not_null', () => {
  // baselinePair 对 none 已按协议置全 null;这里显式改回「naive 模型照抄审计引文」的违例形态。
  const base = baselinePair(base44to16.anchor, base44to16.other, base44to16.relation);
  const decision = base.decisions[0];
  decision.reason = base44to16.relation.reason;
  decision.anchorEvidence = { windowRef: 'W0', quote: base44to16.relation.evidenceSpans[0], rangeUTF16: [0, base44to16.relation.evidenceSpans[0].length] };
  decision.otherEvidence = { windowRef: 'W0', quote: base44to16.relation.evidenceSpans[1], rangeUTF16: [0, base44to16.relation.evidenceSpans[1].length] };
  return base;
}));
negativeCases.push(runNegative('X06', 'G3-none带证据', 'N27→N18 none(H09 计划),仅 reason 非 null(证据为 null)', 'negative_decision_fields_not_null', () => {
  const base = baselinePair(base27to18.anchor, base27to18.other, base27to18.relation);
  base.decisions[0].reason = base27to18.relation.reason;
  return base;
}));

// B4/B5 脉络违例(基于 T1 真实脉络,4 条成员决定全合法,只破坏被考察的结构字段)。
function threadBaseline() {
  const members = threadT1.memberIds.map((id) => byId.get(id));
  const anchor = members[0];
  const body = {
    schemaVersion: 1,
    operationId: makeOperationId(),
    policyVersion: THOUGHT_FOLLOWUP_POLICY_VERSION,
    scopeTitle: '产品思考',
    anchorRef: anchor.id,
    notes: members.map(noteToRequestNote),
  };
  const decisions = members.slice(1).map((m) => buildDecision(anchor, m, anchor.groundTruth.relations.find((r) => r.toId === m.id)));
  return { body, decisions };
}
negativeCases.push(runNegative('X07', 'G4-thread缺锚点', `T1「${threadT1.title}」memberRefs 去掉锚点 ${threadT1.memberIds[0]},仅剩 4 名成员`, 'thread_missing_anchor', () => {
  const base = threadBaseline();
  return { ...base, thread: { title: threadT1.title, question: threadT1.question, memberRefs: threadT1.memberIds.slice(1) } };
}));
negativeCases.push(runNegative('X08', 'G5-thread成员<3', `T1 memberRefs 仅 2 个:[${threadT1.memberIds[0]}, ${threadT1.memberIds[2]}]`, 'thread_member_count', () => {
  const base = threadBaseline();
  return { ...base, thread: { title: threadT1.title, question: threadT1.question, memberRefs: [threadT1.memberIds[0], threadT1.memberIds[2]] } };
}));
negativeCases.push(runNegative('X09', 'G6-标题超32', `T1 标题「${threadT1.title}」重复 4 次 = ${threadT1.title.repeat(4).length} UTF-16 > 32`, 'thread_title_shape', () => {
  const base = threadBaseline();
  return { ...base, thread: { title: threadT1.title.repeat(4), question: threadT1.question, memberRefs: threadT1.memberIds } };
}));

// B7 锚点证据 windowRef 虚构(请求内不存在该窗口 ref)。
negativeCases.push(runNegative('X10', 'G7-windowRef虚构', 'N34→N07 adds_example,锚点证据 windowRef 指向请求中不存在的「W9」', 'anchor_evidence_invalid', () => {
  const base = baselinePair(base34to07.anchor, base34to07.other, base34to07.relation);
  base.decisions[0].anchorEvidence.windowRef = 'W9';
  return base;
}));

const negativeRejected = negativeCases.filter((c) => c.result !== 'FAIL').length;
report.sections.structuralNegative = {
  groups: new Set(negativeCases.map((c) => c.group)).size,
  denominator: negativeCases.length,
  rejected: negativeRejected,
  unexpectedAccepted: negativeCases.filter((c) => c.actual && c.actual.accepted === true).length,
  cases: negativeCases,
  notes: [
    '窗口内「错位但未越界」的 rangeUTF16 不在拒绝范围:服务端按 canonical quote 重算区间(followupSchema.canonicalEvidence 注释,与 semantic-relate v2+ 同口径),协议层只做结构检查(非负整数、半开区间形状、端点不越窗口)。本组以越界与倒置两例考察拒绝行为。',
  ],
};

// ========== C. schema 4:definition ≤240 全过,派生 241 超限全拒 ==========

function buildRelateBody(sample, definition) {
  return {
    schemaVersion: 4,
    operationId: `eval-${sample.id.toLowerCase()}`,
    textRevision: 'eval-1',
    engineVersion: 'run-protocol-eval-1',
    target: { ref: 'target-1', text: sample.text },
    candidates: [{
      ref: 'cat-1',
      title: sample.category,
      kind: 'category',
      definitionSource: 'user',
      definition,
      representatives: [{ ref: 'rep-1', text: sample.text }],
    }],
  };
}

const s4Pass = [];
const s4Reject = [];
for (const sample of ruleSamples.samples) {
  let ok = true;
  let detail = '';
  try {
    validateRelateRequest(buildRelateBody(sample, sample.categoryRule));
  } catch (err) {
    ok = false;
    detail = JSON.stringify(failDetail('预期通过,请求被拒', err));
  }
  if (ok) detail = `definition ${sample.categoryRule.length} UTF-16 ≤ 240`;
  s4Pass.push({ id: `S4-PASS-${sample.id}`, ruleLen: sample.categoryRule.length, result: ok ? 'PASS' : 'FAIL', detail });
}

for (const sample of ruleSamples.samples) {
  const overLen = RELATE_LIMITS.definitionMaxUTF16 + 1;
  const padded = sample.categoryRule + '测'.repeat(overLen - sample.categoryRule.length);
  let rejected = false;
  let detail = '';
  let code = null;
  try {
    validateRelateRequest(buildRelateBody(sample, padded));
    detail = `预期拒绝,实际被接受(definition ${overLen} UTF-16)`;
  } catch (err) {
    rejected = true;
    code = err.code ?? null;
    detail = `definition ${overLen} UTF-16 > ${RELATE_LIMITS.definitionMaxUTF16} 被拒(${code})`;
  }
  s4Reject.push({ id: `S4-REJ-${sample.id}`, ruleLen: overLen, result: rejected ? 'PASS(按预期拒绝)' : 'FAIL', detail, code });
}

const s4PassOk = s4Pass.filter((c) => c.result === 'PASS').length;
const s4RejectOk = s4Reject.filter((c) => c.result !== 'FAIL').length;
report.sections.schema4Definition = {
  withinLimit: { denominator: s4Pass.length, passed: s4PassOk, cases: s4Pass },
  overLimit: { denominator: s4Reject.length, rejected: s4RejectOk, cases: s4Reject },
};

// ========== 汇总与放行线 ==========

const positiveOk = report.sections.positive.failedCount === 0;
const negativeOk = report.sections.structuralNegative.unexpectedAccepted === 0 && negativeRejected === negativeCases.length;
const s4Ok = s4PassOk === s4Pass.length && s4RejectOk === s4Reject.length;
const gatePassed = positiveOk && negativeOk && s4Ok;

const totalChecks = report.sections.positive.denominator + negativeCases.length + s4Pass.length + s4Reject.length;
const passedChecks = positivePassed + negativeRejected + s4PassOk + s4RejectOk;

report.summary = {
  totalChecks,
  passed: passedChecks,
  failed: totalChecks - passedChecks,
  positivePassRate: `${positivePassed}/${report.sections.positive.denominator}`,
  negativeRejectRate: `${negativeRejected}/${negativeCases.length}`,
  schema4: `≤240 通过 ${s4PassOk}/${s4Pass.length};241 超限拒绝 ${s4RejectOk}/${s4Reject.length}`,
  releaseGate: {
    rule: '协议层放行线:正向集 100% 通过 且 结构反证集 100% 拒绝 且 schema4 definition 两向全符合',
    result: gatePassed ? 'PASS' : 'FAIL',
  },
};

fs.writeFileSync(REPORT_PATH, JSON.stringify(report, null, 2) + '\n', 'utf8');

// ---------- stdout 人读摘要 ----------

console.log('==== W4 协议层评测 · verify-followup + schema4 校验器(真实后端代码) ====');
console.log(`语料分母复核: 笔记 ${notes.length} · 关系对 ${relationPairs.length}(成立 ${establishedPairs.length} / 负向 ${negativePairs.length}) · 脉络 ${threadRegistry.size}`);
const pos = report.sections.positive;
console.log(`[A 正向集] 关系对 ${pos.breakdown.relationPairs.passed}/${pos.breakdown.relationPairs.denominator} · 脉络 ${pos.breakdown.threads.passed}/${pos.breakdown.threads.denominator} → 合计 ${pos.passed}/${pos.denominator}`);
for (const c of positiveCases.filter((x) => x.result === 'FAIL')) console.log(`  FAIL ${c.id} ${c.detail}`);
const neg = report.sections.structuralNegative;
console.log(`[B 结构反证集] ${neg.groups} 组 ${neg.denominator} 例,按预期拒绝 ${neg.rejected}/${neg.denominator}`);
for (const c of negativeCases) console.log(`  ${c.result === 'FAIL' ? 'FAIL' : 'ok  '} ${c.id} ${c.group} → ${c.actual && c.actual.reason ? c.actual.reason : c.detail}`);
const s4 = report.sections.schema4Definition;
console.log(`[C schema4 definition] ≤240: ${s4.withinLimit.passed}/${s4.withinLimit.denominator} 通过 · 241 超限: ${s4.overLimit.rejected}/${s4.overLimit.denominator} 拒绝`);
for (const c of [...s4Pass, ...s4Reject].filter((x) => x.result === 'FAIL')) console.log(`  FAIL ${c.id} ${c.detail}`);
console.log(`总体: ${passedChecks}/${totalChecks} · 放行线 → ${gatePassed ? 'PASS(正向 100%,反证 100% 拒)' : 'FAIL'}`);
console.log(`报告已写入: ${REPORT_PATH}`);
process.exit(gatePassed ? 0 : 1);
