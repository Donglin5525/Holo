// 「一个发现」v4 洞察闸门单测（2026-11-20 方案 02-后端实施·测试节）。
// 每一条检查各 1 个通过用例 + 1 个拒绝用例；中文数字（「三周」「两三次」）必须被拦截。
// 数字纪律测试样例与 iOS DiscoveryInsightContractTests 共用同一组向量（双端一致红线）。
import assert from "node:assert/strict";
import { test } from "node:test";

import {
  containsNumerals, validateInsightPacket, parseModelDraft,
  evaluateInsightDraft, repairInsightDraft, buildDraftEnvelope, extractModelJson, stripBareNumerals,
} from "../src/discovery/insightGate.js";

function packet(overrides = {}) {
  return validateInsightPacket({
    schemaVersion: 1,
    kind: "insightInput",
    requestId: "req-11111111",
    window: { days: 28 },
    portrait: [
      { id: "p_early_sleep", dimension: "recentState", confidence: "confirmed", statement: "说想早睡", evidenceSummary: "目标原文", sourceDomains: ["goal"] },
    ],
    features: [
      { id: "f_late_night", domain: "finance", description: "深夜下单比之前少", direction: "down", slots: [{ name: "lateWeeks", unit: "weeks" }, { name: "lateCount", unit: "times" }] },
      { id: "f_task_overdue", domain: "task", description: "断签日与任务逾期日重合", direction: "divergent", slots: [{ name: "overdueDays", unit: "days" }] },
    ],
    userIntents: [{ id: "u_1", source: "goal", text: "想早睡" }],
    recentTopics: ["finance-trend×coffee"],
    rejectedAngles: ["health-steps×weekend"],
    ...overrides,
  });
}

function selected(overrides = {}) {
  return {
    angleKey: "sleep×lateNight",
    headline: "早睡在顺带帮你省钱",
    insight: "你说想早睡的那段时间，深夜下单反而变少了，早睡好像在顺带帮你省钱。",
    evidence: [{ refId: "f_late_night", template: "最近{lateWeeks}周里深夜下单明显变少" }],
    prompt: "",
    criteria: ["D1", "D2", "D4"],
    sourceDomains: ["habit", "finance"],
    ...overrides,
  };
}

// 双端共享数字纪律向量（iOS DiscoveryInsightContractTests.NUMBER_VECTORS 同一组）。
export const NUMBER_VECTORS = [
  { text: "最近4周你花了更多", hit: true },
  { text: "最近四周你花了更多", hit: true },
  { text: "两三次深夜下单", hit: true },
  { text: "半个月里几乎每次", hit: true },
  { text: "半夜十二点还在下单", hit: true },
  { text: "大概是几分之一的原因", hit: true },
  { text: "花费翻倍", hit: false },
  { text: "早睡好像在顺带帮你省钱", hit: false },
  { text: "断签的日子任务也更容易逾期", hit: false },
  // 2026-11-20 实测误报修正：之/几/分 出裸字符集（「之前/几乎/部分」不再误杀）。
  { text: "入睡时间比之前更晚", hit: false },
  { text: "几乎每次都在深夜", hit: false },
  { text: "深夜下单大多与加班有关", hit: false },
];

test("数字纪律：共享向量逐一验证（中文数字/全角/阿拉伯都算数字）", () => {
  for (const { text, hit } of NUMBER_VECTORS) {
    assert.equal(containsNumerals(text), hit, `向量判定错误: ${text}`);
  }
});

test("检查1 schema/长度：完整合格通过；headline 超长拒绝", () => {
  const p = packet();
  assert.equal(evaluateInsightDraft(selected(), p).ok, true);
  const tooLong = "一二三四五六七八九十一二三四五六七八九十一"; // 21 字 > 18
  assert.equal(evaluateInsightDraft(selected({ headline: tooLong }), p).reason, "headline");
  const longInsight = "啊".repeat(91);
  assert.equal(evaluateInsightDraft(selected({ insight: longInsight }), p).reason, "insight");
});

test("检查2 数字禁令：判断句三字段出现数字即拒（headline/insight/prompt 逐字段）", () => {
  const p = packet();
  assert.equal(evaluateInsightDraft(selected({ headline: "最近三周的深夜变化" }), p).reason, "bare_number");
  assert.equal(evaluateInsightDraft(selected({ insight: "深夜下单大概两三次。" }), p).reason, "bare_number");
  assert.equal(evaluateInsightDraft(selected({ prompt: "要不要看看这4周的账单" }), p).reason, "bare_number");
  assert.equal(evaluateInsightDraft(selected(), p).ok, true);
});

test("检查3 引用：未知 refId 拒、越界 slot 拒、portrait 引用带 slot 拒、合法通过", () => {
  const p = packet();
  assert.equal(evaluateInsightDraft(selected({ evidence: [{ refId: "f_ghost", template: "无空位模板" }] }), p).reason, "unknown_ref:f_ghost");
  assert.equal(
    evaluateInsightDraft(selected({ evidence: [{ refId: "f_late_night", template: "共{overdueDays}天逾期" }] }), p).reason,
    "slot_not_allowed:overdueDays",
  );
  assert.equal(
    evaluateInsightDraft(selected({ evidence: [{ refId: "p_early_sleep", template: "你写过{lateWeeks}条目标" }] }), p).reason,
    "slot_not_allowed:lateWeeks",
  );
  assert.equal(evaluateInsightDraft(selected({ evidence: [{ refId: "p_early_sleep", template: "你自己写过想早睡" }] }), p).ok, true);
});

test("检查4 复述启发式：方向词+无连接词+criteria不足拒；有推测词或criteria达标过", () => {
  const p = packet();
  const restatement = selected({
    angleKey: "finance-dining×trend",
    insight: "你餐饮支出增加了。",
    criteria: ["D3"],
    evidence: [{ refId: "f_late_night", template: "无空位" }],
  });
  assert.equal(evaluateInsightDraft(restatement, p).reason, "restatement");
  const withSpeculation = selected({ ...restatement, criteria: ["D2", "D3"], insight: "你餐饮支出增加了，可能与加班有关。" });
  assert.equal(evaluateInsightDraft(withSpeculation, p).ok, true);
  const withTwoCriteria = selected({ ...restatement, criteria: ["D1", "D3"] });
  assert.equal(evaluateInsightDraft(withTwoCriteria, p).ok, true);
});

test("检查5 角度去重：recentTopics 与 rejectedAngles 命中拒", () => {
  const p = packet();
  assert.equal(evaluateInsightDraft(selected({ angleKey: "finance-trend×coffee" }), p).reason, "angle_recent_or_rejected");
  assert.equal(evaluateInsightDraft(selected({ angleKey: "health-steps×weekend" }), p).reason, "angle_recent_or_rejected");
});

test("检查6 安全词表：医疗断言与人格贬损拒（移植自 PortraitSafetyGate 最小集）", () => {
  const p = packet();
  assert.equal(evaluateInsightDraft(selected({ insight: "你可能得了抑郁症。" }), p).reason.startsWith("safety:"), true);
  assert.equal(evaluateInsightDraft(selected({ headline: "你太懒惰了" }), p).reason.startsWith("safety:"), true);
});

test("criteria 数量：少于两项拒、枚举外值拒", () => {
  const p = packet();
  assert.equal(evaluateInsightDraft(selected({ criteria: ["D1"] }), p).reason, "criteria");
  assert.equal(evaluateInsightDraft(selected({ criteria: ["D1", "D9"] }), p).reason, "criteria");
});

test("parseModelDraft：围栏容错/坏 JSON/none 枚举校验", () => {
  const good = JSON.stringify({ selected: selected(), noneReason: null });
  assert.equal(parseModelDraft(`\`\`\`json\n${good}\n\`\`\``).ok, true);
  assert.equal(parseModelDraft("不是 JSON").reason, "not_json");
  assert.equal(parseModelDraft('{"selected":null,"noneReason":"weird"}').reason, "none_reason");
  const none = parseModelDraft('{"selected":null,"noneReason":"none_worthwhile"}');
  assert.equal(none.ok && none.none && none.noneReason, "none_worthwhile");
  assert.deepEqual(extractModelJson('前置噪声 {"a":1} 尾部'), { a: 1 });
});

test("validateInsightPacket：数量上限/枚举非法 → 400；超限 portrait 12 条拒绝", () => {
  const tooManyPortrait = Array.from({ length: 13 }, (_, i) => ({
    id: `p_${i}`, dimension: "identity", confidence: "inferred", statement: "s", evidenceSummary: "", sourceDomains: [],
  }));
  assert.throws(() => packet({ portrait: tooManyPortrait }), /exceeds 12/);
  assert.throws(() => packet({ features: [{ id: "f_x", domain: "sports", description: "d", direction: "up", slots: [] }] }), /enum invalid/);
  assert.throws(() => packet({ requestId: "不合法的请求 ID！" }), /requestId invalid/);
});

test("修复层：截断超长+剔除非法 evidence 后重校验通过；全部剔除后仍拒", () => {
  const p = packet();
  const bad = selected({
    extraField: "应被剥掉",
    headline: "早睡在顺带帮你省钱，顺便还有更多好处发生", // 20 字，修复截到 18
    evidence: [
      { refId: "f_ghost", template: "无效引用" },
      { refId: "f_late_night", template: "最近{lateWeeks}周里深夜下单明显变少" },
    ],
  });
  const repaired = repairInsightDraft(bad, p);
  assert.equal(repaired.headline.length <= 18, true);
  assert.equal(repaired.evidence.length, 1);
  assert.equal("extraField" in repaired, false);
  assert.equal(evaluateInsightDraft(repaired, p).ok, true);
  const allBad = repairInsightDraft(selected({ evidence: [{ refId: "f_ghost", template: "x" }] }), p);
  assert.equal(allBad.evidence.length, 0);
  assert.equal(evaluateInsightDraft(allBad, p).ok, false);
});

test("修复层裸数字剥除：数字+量词剥、非计数用法不动（bare_number 拒因主攻）", () => {
  assert.equal(stripBareNumerals("最近四周里深夜下单变多"), "最近里深夜下单变多");
  assert.equal(stripBareNumerals("大概两三次"), "大概");
  assert.equal(stripBareNumerals("半夜还在下单"), "半夜还在下单");   // 半+夜 非计数
  assert.equal(stripBareNumerals("十分稳定的节奏"), "十分稳定的节奏"); // 十+分 非计数
  assert.equal(stripBareNumerals("花了12块左右"), "花了左右");
});

test("buildDraftEnvelope：线上形状与 iOS InsightDraft 解码端对齐", () => {
  const withSelected = JSON.parse(buildDraftEnvelope({ selected: selected() }));
  assert.equal(withSelected.schemaVersion, 1);
  assert.equal(withSelected.kind, "insightDraft");
  assert.deepEqual(Object.keys(withSelected.selected), ["angleKey", "headline", "insight", "evidence", "prompt", "criteria", "sourceDomains"]);
  assert.equal(withSelected.noneReason, null);
  const none = JSON.parse(buildDraftEnvelope({ selected: null, noneReason: "gate_rejected" }));
  assert.equal(none.selected, null);
  assert.equal(none.noneReason, "gate_rejected");
});
