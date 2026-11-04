// 「一个发现」1.1.5 修复层与引用修复测试（2026-11-02 重设计 S1/S7）。
// S1：deepseek-chat 常把 timeRange 写成纯日期（今晚试评 r13：7/18 全部 time_range_value），
//     修复层按请求 anchorNow 的时区偏移确定性补全为完整时刻；无偏移不修（照常拒）。
// S7①：引用锚定必须按原文真实下标回取（此前用归一化下标切原文，原文含空白/引号时整体错位）。
// S7②：数词兜底只对「这两次」类数词句生效（阿拉伯数字句客户端只认 metricIDs，补引用无效）。
import assert from "node:assert/strict";
import { test } from "node:test";

import { validateDiscoveryOutput } from "../src/discovery/discoveryOutputSchema.js";
import {
  anchorQuoteToSource,
  padCountWordCitations,
  timezoneOffsetOf,
} from "../src/discovery/discoveryCitationRepair.js";

function envelopeWithRange(timeRange, extra = {}) {
  return {
    schemaVersion: 1,
    kind: "candidates",
    runID: "run-repair-1",
    noFindingReason: "none",
    candidates: [{
      candidateID: "C01",
      type: extra.type ?? "two_episodes",
      subjectKey: "restart",
      scopeKind: extra.scopeKind ?? "two_episodes",
      timeRange,
      claims: [
        { claimID: "T", kind: "observation", text: "这两次重新开始，你都把第一步变轻了。",
          citations: [{ evidenceID: "E01", quote: "今天先出去走了十分钟" }, { evidenceID: "E02", quote: "今晚只翻了两页" }],
          metricIDs: [] },
        { claimID: "B", kind: "fact", text: "恢复运动时先走十分钟。",
          citations: [{ evidenceID: "E01", quote: "今天先出去走了十分钟" }], metricIDs: [] },
      ],
      titleClaimID: "T",
      bodyClaimIDs: ["B"],
      supportEvidenceIDs: ["E01", "E02"],
      counterSearch: [{ domains: ["thought"], anchorRefs: [], keywords: ["重新开始"] }],
      sensitivity: "non_sensitive",
      comparisonPeriods: extra.comparisonPeriods ?? [],
    }],
  };
}

// ===== S1 纯日期补全 =====

test("S1 纯日期 timeRange + 已知偏移 → 补全为当天 00:00:00 / 23:59:59（偏移取 anchorNow）", () => {
  const { envelope } = validateDiscoveryOutput(
    JSON.stringify(envelopeWithRange({ start: "2026-10-08", end: "2026-10-17" })),
    { expectedKind: "candidates", expectedRunID: "run-repair-1", timezoneOffset: "+08:00" },
  );
  assert.deepEqual(envelope.candidates[0].timeRange, {
    start: "2026-10-08T00:00:00+08:00",
    end: "2026-10-17T23:59:59+08:00",
  });
});

test("S1 compared_periods 的纯日期同样补全", () => {
  const raw = envelopeWithRange(
    { start: "2026-09-01", end: "2026-10-20" },
    {
      type: "change_over_time",
      scopeKind: "compared_periods",
      comparisonPeriods: [
        { start: "2026-09-01", end: "2026-09-15" },
        { start: "2026-10-05T00:00:00+08:00", end: "2026-10-20" },
      ],
    },
  );
  const { envelope } = validateDiscoveryOutput(JSON.stringify(raw), {
    expectedKind: "candidates", expectedRunID: "run-repair-1", timezoneOffset: "+08:00",
  });
  assert.deepEqual(envelope.candidates[0].comparisonPeriods, [
    { start: "2026-09-01T00:00:00+08:00", end: "2026-09-15T23:59:59+08:00" },
    { start: "2026-10-05T00:00:00+08:00", end: "2026-10-20T23:59:59+08:00" },
  ]);
});

test("S1 没有时区偏移时不猜测：纯日期照常 time_range_value 拒绝", () => {
  assert.throws(
    () => validateDiscoveryOutput(
      JSON.stringify(envelopeWithRange({ start: "2026-10-08", end: "2026-10-17" })),
      { expectedKind: "candidates", expectedRunID: "run-repair-1" },
    ),
    (error) => error.code === "DISCOVERY_MODEL_OUTPUT_INVALID" && error.details.reason === "time_range_value",
  );
});

test("S1 非日期垃圾值不被修复层吞掉（仍拒）", () => {
  assert.throws(
    () => validateDiscoveryOutput(
      JSON.stringify(envelopeWithRange({ start: "上周三", end: "2026-10-17" })),
      { expectedKind: "candidates", expectedRunID: "run-repair-1", timezoneOffset: "+08:00" },
    ),
    (error) => error.details.reason === "time_range_value",
  );
});

test("S1 补全后 start 晚于 end 仍按 time_range_order 拒（修复不掩盖语义错误）", () => {
  assert.throws(
    () => validateDiscoveryOutput(
      JSON.stringify(envelopeWithRange({ start: "2026-10-17", end: "2026-10-08" })),
      { expectedKind: "candidates", expectedRunID: "run-repair-1", timezoneOffset: "+08:00" },
    ),
    (error) => error.details.reason === "time_range_order",
  );
});

test("timezoneOffsetOf：从 anchorNow 取偏移；Z 视为 +00:00；无偏移返回 null", () => {
  assert.equal(timezoneOffsetOf("2026-11-02T00:28:42+08:00"), "+08:00");
  assert.equal(timezoneOffsetOf("2026-11-02T00:28:42.123-05:00"), "-05:00");
  assert.equal(timezoneOffsetOf("2026-11-01T16:28:42Z"), "+00:00");
  assert.equal(timezoneOffsetOf("2026-11-02"), null);
  assert.equal(timezoneOffsetOf(undefined), null);
});

// ===== S7① 引用锚定按原文真实下标 =====

test("S7① 原文开头带空白时，锚定结果是原文中真正对应的片段（不整体错位）", () => {
  const source = "   停了一阵，今天先出去走了十分钟。没有要求自己一定跑起来。";
  // 模型轻微改写（中段句号→逗号），前后缀各 8 字仍可锚定
  const quote = "今天先出去走了十分钟，没有要求自己一定跑起来";
  const anchored = anchorQuoteToSource(source, quote);
  assert.equal(anchored, "今天先出去走了十分钟。没有要求自己一定跑起来");
  assert.ok(source.includes(anchored));
});

test("S7① 原文内部含引号与换行时同样精确回取", () => {
  const source = "他说“先写提纲”。\n 然后我把 要点 写成提纲，再分清会上要讨论的事。";
  const quote = "然后我把要点写成了提纲，再分清会上要讨论的事";
  const anchored = anchorQuoteToSource(source, quote);
  assert.equal(anchored, "然后我把 要点 写成提纲，再分清会上要讨论的事");
});

test("S7① 已是原文子串 → 原样返回；锚不定 → 返回 null（交给客户端如实拒）", () => {
  const source = "今天先出去走了十分钟。";
  assert.equal(anchorQuoteToSource(source, "先出去走了十分钟"), "先出去走了十分钟");
  assert.equal(anchorQuoteToSource(source, "完全不相干的一句话内容在这里"), null);
});

test("S7① 前后缀相距过远（跨了大段无关原文）不锚定，避免引用膨胀", () => {
  const filler = "无关内容".repeat(40);
  const source = `今天先出去走了十分钟${filler}没有要求自己一定跑起来。`;
  const quote = "今天先出去走了十分钟，没有要求自己一定跑起来";
  assert.equal(anchorQuoteToSource(source, quote), null);
});

// ===== S7② 数词兜底只对数词句 =====

test("S7② 数词句（这两次）引用不足 2 条时，从候选支撑证据补齐", () => {
  const candidate = {
    supportEvidenceIDs: ["E01", "E02"],
    claims: [{ claimID: "T", kind: "observation", text: "这两次你都先降低了门槛。",
      citations: [{ evidenceID: "E01", quote: "先走十分钟" }], metricIDs: [] }],
  };
  const blocks = new Map([["E01", "先走十分钟。"], ["E02", "今晚只翻了两页。后来睡了。"]]);
  const added = padCountWordCitations(candidate, blocks);
  assert.equal(added, 1);
  assert.deepEqual(candidate.claims[0].citations.at(-1), { evidenceID: "E02", quote: "今晚只翻了两页。" });
});

test("S7② 阿拉伯数字句与百分比句不补引用（客户端只认 metricIDs / 一律拒，补了也是噪声）", () => {
  const candidate = {
    supportEvidenceIDs: ["E01", "E02"],
    claims: [
      { claimID: "A", kind: "fact", text: "你走了 10 分钟。", citations: [{ evidenceID: "E01", quote: "走了10分钟" }], metricIDs: [] },
      { claimID: "B", kind: "fact", text: "完成率提升到百分之八十，约 80%。", citations: [{ evidenceID: "E01", quote: "走了10分钟" }], metricIDs: [] },
    ],
  };
  const blocks = new Map([["E01", "走了10分钟。"], ["E02", "今晚只翻了两页。"]]);
  assert.equal(padCountWordCitations(candidate, blocks), 0);
  assert.equal(candidate.claims[0].citations.length, 1);
  assert.equal(candidate.claims[1].citations.length, 1);
});
