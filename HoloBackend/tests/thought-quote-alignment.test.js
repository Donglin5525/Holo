import test from "node:test";
import assert from "node:assert/strict";
import { alignQuoteToSource } from "../src/thoughts/quoteAlignment.js";
import { validateBriefRequest, validateBriefModelOutput } from "../src/thoughts/categoryBriefSchema.js";
import { validateRelateRequest, validateRelateModelOutput } from "../src/thoughts/semanticRelateSchema.js";

// 引用对齐回原文（2026-10-19 brief 空转根治）：排版微差（空白/大小写/引号形态）
// 由服务端修正为原文精确子串；内容性改写仍拒绝。生产背景：quote_not_verbatim
// 是 thought_category_brief_v1（288/341）与 relate 502 的绝对主因。

// ─────────────────────────── alignQuoteToSource 单元 ───────────────────────────

test("alignQuoteToSource 逐字命中原样返回", () => {
  const source = "今天跑了五公里，配速比上月快了十五秒。";
  assert.equal(alignQuoteToSource("跑了五公里", source), "跑了五公里");
});

test("alignQuoteToSource 空白差异对齐回原文精确子串（含中间被吞空白）", () => {
  const source = "出门喂猫  的时候发现楼下的桂花开了。";
  // 模型把两个空格吞成一个
  const aligned = alignQuoteToSource("喂猫 的时候发现楼下的桂花开了", source);
  assert.equal(aligned, "喂猫  的时候发现楼下的桂花开了");
  assert.ok(source.includes(aligned), "返回值必须是原文子串");
});

test("alignQuoteToSource 大小写与换行差异对齐", () => {
  const source = "Swift Concurrency\nin depth";
  const aligned = alignQuoteToSource("swift concurrency in depth", source);
  assert.equal(aligned, "Swift Concurrency\nin depth");
});

test("alignQuoteToSource 弯引号/中文引号形态差异对齐", () => {
  const source = "他说「今天不加班」就走了。";
  const aligned = alignQuoteToSource("他说\"今天不加班\"就走了", source);
  assert.equal(aligned, "他说「今天不加班」就走了");
});

test("alignQuoteToSource 内容性改写返回 null（不模糊匹配）", () => {
  const source = "食堂两个肉菜 53 块，这定价是认真的吗。";
  assert.equal(alignQuoteToSource("食堂两个肉菜五十三块", source), null);
  assert.equal(alignQuoteToSource("食堂定价太贵了", source), null);
});

test("alignQuoteToSource 非法输入返回 null", () => {
  assert.equal(alignQuoteToSource("", "原文"), null);
  assert.equal(alignQuoteToSource(null, "原文"), null);
  assert.equal(alignQuoteToSource("引用", ""), null);
  assert.equal(alignQuoteToSource("   ", "原文"), null);
});

// ─────────────────────────── brief 端到端 ───────────────────────────

function briefBody() {
  return {
    schemaVersion: 1,
    operationId: "op-align",
    engineVersion: "thought_semantic_v3.2",
    topic: { title: "碎碎念", userDefinition: null, currentBrief: null },
    members: [
      { ref: "R0", text: "食堂两个肉菜 53 块，这定价是认真的吗。", source: "user" },
      { ref: "R1", text: "出门喂猫的时候发现楼下的桂花开了，顺手记一下。", source: "user" },
      { ref: "R2", text: "Agent 越来越能干之后，人反而更不敢拍板了，记下这个感受。", source: "ai" },
    ],
    removals: [],
  };
}

test("brief 证据排版微差对齐入库为原文子串，不再整体 502", () => {
  const parsed = validateBriefRequest(briefBody());
  const out = validateBriefModelOutput({
    brief: { definition: "生活里顺手的碎碎念与即时感受。", exclusions: [] },
    // 模型吞了 53 前后的空格（排版微差）
    evidence: [{ ref: "R0", quote: "食堂两个肉菜53 块" }],
  }, parsed);
  assert.equal(out.evidence[0].quote, "食堂两个肉菜 53 块");
});

test("brief 证据内容性改写仍拒绝", () => {
  const parsed = validateBriefRequest(briefBody());
  const out = validateBriefModelOutput({
    brief: { definition: "生活里顺手的碎碎念与即时感受。", exclusions: [] },
    evidence: [{ ref: "R0", quote: "食堂定价太离谱了" }],
  }, parsed);
  assert.equal(out.malformed, true);
  assert.equal(out.reason, "quote_not_verbatim");
});

// ─────────────────────────── relate 端到端 ───────────────────────────

test("relate 主证据与主题侧依据排版微差对齐", () => {
  const parsed = validateRelateRequest({
    schemaVersion: 2,
    operationId: "op-align",
    textRevision: "r-1",
    engineVersion: "thought_semantic_v3.2",
    target: { ref: "T0", text: "今天跑了五公里， 配速比上月快了十五秒。" },
    candidates: [
      { ref: "P0", title: "跑步训练", summary: "跑步记录与配速感受", representatives: [{ ref: "M0", text: "配速 提升的喜悦" }] },
    ],
  });
  // 主证据吞掉「配速」前的空格；主题侧依据吞掉「配速」后的空格
  const out = validateRelateModelOutput({
    decisions: [
      { candidateRef: "P0", relation: "same_thread", quote: "配速比上月快了十五秒",
        representativeRef: "M0", representativeQuote: "配速提升的喜悦", sharedSubject: "跑步配速" },
    ],
  }, parsed);
  assert.equal(out.decisions[0].relation, "same_thread");
  assert.equal(out.decisions[0].quote, "配速比上月快了十五秒");
  assert.equal(out.decisions[0].rangeUTF16[0], "今天跑了五公里， 配速比上月快了十五秒。".indexOf("配速"));
  assert.equal(out.decisions[0].representativeQuote, "配速 提升的喜悦");
});
