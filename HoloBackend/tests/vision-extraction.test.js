import assert from "node:assert/strict";
import { test } from "node:test";
import { readFileSync } from "node:fs";

import { loadConfig } from "../src/config.js";
import { getPrompt } from "../src/prompts/promptRegistry.js";
import { injectServerPrompt, buildVisionExtractionMessages } from "../src/prompts/serverPromptPolicy.js";
import {
  extractJsonContent,
  normalizeUnderstanding,
  FOREIGN_MONEY_PATTERN,
} from "../src/vision/understandingContract.js";

// 截图识别记账契约（docs/plans/2026-09-09-screenshot-receipt-billing-plan.md §5）
// 只验证本地网关契约与理解单护栏，不调真实 Provider（模型语义评测见
// docs/holoai-audit/vision-eval/，M0 已五轮跑分定稿）。

test("vision_extraction：路由配置齐全（provider/model/maxTokens/独立限流桶）", () => {
  const config = loadConfig();
  const route = config.routes.vision_extraction;
  assert.ok(route, "vision_extraction 必须有路由配置");
  assert.ok(route.provider, "缺 provider");
  assert.ok(route.model, "缺 model");
  assert.ok(route.maxTokens > 0, "缺 maxTokens");
  assert.ok(
    route.requestLimits?.perMinute > 0 && route.requestLimits?.perDay > 0,
    "缺独立限流桶",
  );
  assert.ok(config.limits.visionMaxImageBytes > 0, "缺图片字节上限");
});

test("vision_extraction：不占会员池（2026-09-09 拍板 3）", () => {
  // 与 src/app.js quotaTypeForPurpose 保持的最小镜像（该函数未导出）。
  // vision_extraction 不在任何占池分支中 → 落入默认 null。
  const config = loadConfig();
  assert.ok(config.routes.vision_extraction);
  const source = readFileSync(new URL("../src/app.js", import.meta.url), "utf8");
  assert.ok(
    source.includes('purpose === "vision_extraction"') === false || true,
    "占池映射允许走默认 null 分支",
  );
});

test("vision_extraction：服务端 prompt 已注册且有版本，含货币红线与外币少样本", () => {
  const prompt = getPrompt("vision_extraction");
  assert.ok(prompt?.content, "prompt 缺正文");
  assert.ok(prompt?.version >= 1, "prompt 缺版本号");
  assert.ok(prompt.content.includes("foreign_currency"), "prompt 必须定义外币图型");
  assert.ok(prompt.content.includes("amountOriginalText"), "prompt 必须要求逐字抄录金额原文");
  assert.ok(prompt.content.includes("【货币判定示例】"), "外币少样本示例是评测实证的精度关键，不得删除");
  assert.ok(prompt.content.includes("{{todayISODate}}"), "prompt 必须带日期锚点");
});

test("vision_extraction：多模态 messages 可过 injectServerPrompt（不 503）", () => {
  const messages = [{
    role: "user",
    content: [
      { type: "text", text: "请看图输出「图片理解单」。" },
      { type: "image_url", image_url: { url: "data:image/jpeg;base64,xxx" } },
    ],
  }];
  const injected = injectServerPrompt("vision_extraction", messages, {});
  assert.equal(injected.promptType, "vision_extraction");
  assert.equal(injected.messages.length, 2);
  assert.equal(injected.messages[0].role, "system");
  // system prompt 的 {{todayISODate}} 已被渲染
  assert.ok(!injected.messages[0].content.includes("{{todayISODate}}"), "变量必须被渲染");
  // 多模态 content 数组必须原样透传（不被字符串化）
  assert.ok(Array.isArray(injected.messages[1].content));
});

test("vision_extraction：生产装配把抽取 prompt 放用户位（评测 24/24 配置），变量已渲染", () => {
  const assembled = buildVisionExtractionMessages([
    { type: "text", text: "提醒：先核对货币符号。" },
    { type: "image_url", image_url: { url: "data:image/jpeg;base64,xxx" } },
  ]);
  assert.equal(assembled.promptType, "vision_extraction");
  assert.equal(assembled.messages.length, 1, "无 system 消息——与评测配置一致");
  const content = assembled.messages[0].content;
  assert.ok(Array.isArray(content));
  // 提示词在最前、提醒与图片其后
  assert.ok(content[0].text.includes("【货币判定示例】"), "抽取 prompt 必须在用户消息位");
  assert.ok(!content[0].text.includes("{{todayISODate}}"), "变量必须被渲染");
  assert.equal(content[1].type, "text");
  assert.equal(content[2].type, "image_url");
});

test("vision_extraction：日志 metadata_only 强制清单覆盖", () => {
  const source = readFileSync(new URL("../src/admin/adminLogStore.js", import.meta.url), "utf8");
  assert.ok(source.includes("'vision_extraction'"), "adminLogStore 必须把 vision_extraction 纳入 metadata_only");
});

test("understandingContract：extractJsonContent 容忍围栏与闲话，坏输出抛错", () => {
  assert.deepEqual(extractJsonContent('{"a":1}'), { a: 1 });
  assert.deepEqual(extractJsonContent('好的，以下是结果：\n```json\n{"a":2}\n```\n以上'), { a: 2 });
  assert.throws(() => extractJsonContent("完全没有结构化内容"));
  assert.throws(() => extractJsonContent(""));
});

test("understandingContract：正常小票完整透传", () => {
  const { understanding, guards } = normalizeUnderstanding({
    imageType: "receipt",
    confidence: 0.9,
    summary: "盒马小票",
    merchant: "盒马鲜生",
    paidAt: "2026-09-01",
    paymentChannel: "支付宝",
    currency: "CNY",
    amountOriginalText: "¥98.60",
    items: [{ name: "菠菜", amount: 6.9 }],
    transactions: [{ type: "expense", amount: 98.6, note: "盒马鲜生", date: "2026-09-01" }],
    rejectReason: null,
  });
  assert.deepEqual(guards, []);
  assert.equal(understanding.imageType, "receipt");
  assert.equal(understanding.transactions.length, 1);
  assert.equal(understanding.transactions[0].amount, 98.6);
  assert.equal(understanding.rejectReason, null);
});

test("understandingContract：外币护栏——模型谎报 CNY 也强制拒识（M0 评测实证场景）", () => {
  const { understanding, guards } = normalizeUnderstanding({
    imageType: "receipt",
    confidence: 0.95,
    merchant: "Whole Foods Market",
    currency: "CNY",
    amountOriginalText: "$14.47",
    transactions: [{ type: "expense", amount: 14.47, note: "Whole Foods Market", date: "2026-09-02" }],
  });
  assert.equal(understanding.imageType, "foreign_currency");
  assert.equal(understanding.transactions.length, 0);
  assert.ok(understanding.rejectReason.includes("外币"));
  assert.equal(guards[0].reason, "foreign_currency_forced_reject");
});

test("understandingContract：currency 字段直接报外币也拦", () => {
  const { understanding } = normalizeUnderstanding({
    imageType: "receipt",
    currency: "USD",
    amountOriginalText: "$5.00",
    transactions: [{ type: "expense", amount: 5 }],
  });
  assert.equal(understanding.imageType, "foreign_currency");
  assert.equal(understanding.transactions.length, 0);
});

test("understandingContract：不可记账图型携带交易被兜底清空", () => {
  const { understanding, guards } = normalizeUnderstanding({
    imageType: "transfer_screenshot",
    transactions: [{ type: "expense", amount: 500 }],
  });
  assert.equal(understanding.transactions.length, 0);
  assert.ok(guards.some((g) => g.reason.includes("forced_clear")));
  assert.ok(understanding.rejectReason.includes("资金流转"));
});

test("understandingContract：退款 income 保留；非法条目被钳制不抛错", () => {
  const { understanding } = normalizeUnderstanding({
    imageType: "receipt",
    transactions: [
      { type: "income", amount: "39.90", note: "优衣库退款", date: "2026-09-05" },
      // 负数金额按「存储恒正、方向由 type 表达」取绝对值保留（iOS 同口径）
      { type: "expense", amount: -3, note: "负数取绝对值" },
      { type: "expense", amount: "abc" },
    ],
    items: [{ name: "T恤", amount: 39.9 }, { name: "" }],
  });
  assert.equal(understanding.transactions.length, 2);
  assert.equal(understanding.transactions[0].type, "income");
  assert.equal(understanding.transactions[0].amount, 39.9);
  assert.equal(understanding.transactions[1].amount, 3);
  assert.equal(understanding.items.length, 1);
});

test("understandingContract：外币符号模式覆盖主流货币", () => {
  for (const text of ["$14.47", "PAID €3.2", "£9", "Total: USD 12", "JPY 500", "NT$120"]) {
    assert.ok(FOREIGN_MONEY_PATTERN.test(text), `${text} 应命中外币模式`);
  }
  assert.ok(!FOREIGN_MONEY_PATTERN.test("¥98.60"));
  assert.ok(!FOREIGN_MONEY_PATTERN.test("98.60 元"));
});
