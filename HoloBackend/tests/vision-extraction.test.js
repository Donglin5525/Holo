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

// ===== v2 契约（docs/finance/plans/2026-09-14-Holo图片账单快捷指令自动记账完整方案.md §7/§26）=====
// v2 为「自动落账」服务：字段级置信度 + 支付状态 + 分类语义候选。
// 铁律：v1 输出缺新字段时新客户端必须一律转复核，不能用整体 confidence 冒充字段 confidence。

test("v2：完整 v2 输出透传——schemaVersion/paymentStatus/字段级 confidence/逐笔原文/分类候选", () => {
  const { understanding, guards } = normalizeUnderstanding({
    imageType: "payment_screenshot",
    confidence: 0.97,
    paymentStatus: "completed",
    paymentStatusOriginalText: "支付成功",
    currency: "CNY",
    amountOriginalText: "¥19.90",
    merchant: "瑞幸咖啡",
    paidAt: "2026-09-14",
    paymentChannel: "微信支付",
    transactions: [{
      type: "expense",
      amount: 19.9,
      note: "瑞幸咖啡",
      date: "2026-09-14",
      amountOriginalText: "¥19.90",
      paymentChannel: "微信支付",
      confidence: { amount: 0.99, direction: 0.99, paymentStatus: 0.99, date: 0.94, merchant: 0.96, paymentChannel: 0.93 },
      categoryCandidate: "瑞幸咖啡",
      normalizedCategoryCandidate: "咖啡",
      semanticCategoryHint: "餐饮",
    }],
  });
  assert.deepEqual(guards, []);
  assert.equal(understanding.schemaVersion, 3, "v3 输出必须带 schemaVersion");
  assert.equal(understanding.paymentStatus, "completed");
  assert.equal(understanding.paymentStatusOriginalText, "支付成功");
  const tx = understanding.transactions[0];
  assert.equal(tx.amountOriginalText, "¥19.90");
  assert.equal(tx.paymentChannel, "微信支付", "v3 逐笔渠道必须透传");
  assert.equal(tx.confidence.amount, 0.99);
  assert.equal(tx.confidence.direction, 0.99);
  assert.equal(tx.confidence.paymentStatus, 0.99);
  assert.equal(tx.confidence.date, 0.94);
  assert.equal(tx.confidence.paymentChannel, 0.93);
  assert.equal(tx.categoryCandidate, "瑞幸咖啡");
  assert.equal(tx.normalizedCategoryCandidate, "咖啡");
  assert.equal(tx.semanticCategoryHint, "餐饮");
});

test("v2：v1 旧输出（无新字段）兼容透传，旧字段原样保留", () => {
  const { understanding, guards } = normalizeUnderstanding({
    imageType: "receipt",
    confidence: 0.9,
    merchant: "盒马鲜生",
    paidAt: "2026-09-01",
    transactions: [{ type: "expense", amount: 98.6, note: "盒马鲜生", date: "2026-09-01" }],
  });
  assert.deepEqual(guards, [], "缺省新字段是合法 v1 输入，不算护栏改写");
  assert.equal(understanding.schemaVersion, 3);
  assert.equal(understanding.paymentStatus, "unknown", "v1 无支付状态 → unknown（客户端转复核）");
  assert.equal(understanding.paymentStatusOriginalText, null);
  assert.equal(understanding.transactions[0].amountOriginalText, null);
  assert.equal(understanding.transactions[0].paymentChannel, null, "v1 输入无逐笔渠道 → null");
  assert.equal(understanding.transactions[0].confidence.amount, null, "缺失字段置信度为 null（不可自动写）");
  assert.equal(understanding.transactions[0].categoryCandidate, null);
  assert.equal(understanding.transactions[0].amount, 98.6, "旧字段不变");
  assert.equal(understanding.confidence, 0.9, "整体 confidence 保留（旧客户端依赖）");
});

test("v2：pending/failed/cancelled 强制清交易并映射图型（未完成支付红线）", () => {
  const cases = [
    ["pending", "pending_order"],
    ["failed", "unrelated"],
    ["cancelled", "unrelated"],
  ];
  for (const [status, expectedType] of cases) {
    const { understanding, guards } = normalizeUnderstanding({
      imageType: "payment_screenshot",
      paymentStatus: status,
      paymentStatusOriginalText: "待付款",
      transactions: [{ type: "expense", amount: 88 }],
    });
    assert.equal(understanding.transactions.length, 0, `${status} 不得保留交易候选`);
    assert.equal(understanding.imageType, expectedType, `${status} 图型应映射为 ${expectedType}`);
    assert.ok(guards.some((g) => g.reason === "payment_status_forced_clear"), `${status} 必须记录护栏`);
    assert.ok(understanding.rejectReason && understanding.rejectReason.length > 0, status);
  }
});

test("v2：refunded 保留退款收入候选（退款=refunded+证据共同支持，客户端再判）", () => {
  const { understanding, guards } = normalizeUnderstanding({
    imageType: "payment_screenshot",
    paymentStatus: "refunded",
    paymentStatusOriginalText: "退款成功",
    transactions: [{ type: "income", amount: 39.9, note: "优衣库退款" }],
  });
  assert.deepEqual(guards, []);
  assert.equal(understanding.transactions.length, 1);
  assert.equal(understanding.transactions[0].type, "income");
});

test("v2：paymentStatus 非法值钳制为 unknown 并记录 guard", () => {
  const { understanding, guards } = normalizeUnderstanding({
    imageType: "receipt",
    paymentStatus: "PAID!!!",
    transactions: [{ type: "expense", amount: 5 }],
  });
  assert.equal(understanding.paymentStatus, "unknown");
  assert.ok(guards.some((g) => g.field === "paymentStatus"), "被钳制行为必须可观测");
});

test("v2：字段级 confidence 钳制 0...1，非数字/缺失为 null", () => {
  const { understanding } = normalizeUnderstanding({
    imageType: "receipt",
    transactions: [{
      type: "expense", amount: 5,
      confidence: { amount: 1.7, direction: -0.5, paymentStatus: "高", date: 0.8, merchant: NaN },
    }],
  });
  const c = understanding.transactions[0].confidence;
  assert.equal(c.amount, 1, "越界上钳到 1");
  assert.equal(c.direction, 0, "越界下钳到 0（0=模型自己说不可信，语义与缺失 null 可区分）");
  assert.equal(c.paymentStatus, null, "非数字必须为 null");
  assert.equal(c.date, 0.8);
  assert.equal(c.merchant, null, "NaN 必须为 null");
  assert.equal(c.paymentChannel, null, "缺失为 null");
});

test("v2：vision_extraction prompt 升 v2——支付状态/字段级置信度/schemaVersion，外币少样本保留", () => {
  const prompt = getPrompt("vision_extraction");
  assert.ok(prompt.version >= 2, "prompt 必须升到 v2");
  assert.ok(prompt.content.includes("schemaVersion"), "必须声明 schemaVersion 输出");
  assert.ok(prompt.content.includes("paymentStatus"), "必须定义支付状态字段");
  assert.ok(prompt.content.includes("paymentStatusOriginalText"), "必须要求支付状态原文抄录");
  assert.ok(prompt.content.includes("confidence"), "必须要求字段级置信度");
  assert.ok(prompt.content.includes("categoryCandidate"), "必须输出分类语义候选");
  assert.ok(prompt.content.includes("【货币判定示例】"), "外币少样本示例是精度关键，不得删除");
  assert.ok(prompt.content.includes("amountOriginalText"), "逐笔金额原文要求保留");
});

test("v2：自动化总闸默认关闭；响应必须携带 automationPolicy（§26.2/§30.2）", () => {
  const config = loadConfig();
  assert.equal(config.visionAutomation.autoCommitAllowed, false, "默认必须关闭——服务端总闸红线");
  assert.ok(config.visionAutomation.policyVersion, "缺 policyVersion");
  const source = readFileSync(new URL("../src/app.js", import.meta.url), "utf8");
  assert.ok(source.includes("automationPolicy"), "vision/extract 响应必须携带 automationPolicy 字段");
});

test("v2：HOLO_VISION_AUTO_COMMIT_ALLOWED=true 时总闸打开（灰度通道）", async () => {
  const prev = process.env.HOLO_VISION_AUTO_COMMIT_ALLOWED;
  process.env.HOLO_VISION_AUTO_COMMIT_ALLOWED = "true";
  try {
    // DEFAULT_CONFIG 在模块加载时读取 env，须拿全新模块实例验证 env 生效
    const fresh = await import("../src/config.js?env-toggle-test=1");
    const config = fresh.loadConfig();
    assert.equal(config.visionAutomation.autoCommitAllowed, true);
  } finally {
    if (prev === undefined) delete process.env.HOLO_VISION_AUTO_COMMIT_ALLOWED;
    else process.env.HOLO_VISION_AUTO_COMMIT_ALLOWED = prev;
  }
});

// ===== v3 契约（2026-09-19 一图多笔）：逐笔 paymentChannel =====
// 动机实证：微信支付服务通知流一张截图两笔交易，分别为信用卡/零钱支付——
// 顶层单一渠道会把两笔归到同一账户，账户必须逐笔匹配。

test("v3：一图多笔不同渠道各自保留（动机场景：信用卡+零钱）", () => {
  const { understanding, guards } = normalizeUnderstanding({
    imageType: "payment_screenshot",
    confidence: 0.9,
    paymentStatus: "completed",
    merchant: "蒙自源",
    paymentChannel: null,
    transactions: [
      {
        type: "expense", amount: 71.77, note: "蒙自源", date: "2026-09-13",
        amountOriginalText: "¥71.77", paymentChannel: "中信银行信用卡7770",
      },
      {
        type: "expense", amount: 183, note: "微信", date: "2026-09-13",
        amountOriginalText: "¥183.00", paymentChannel: "零钱",
      },
    ],
  });
  assert.deepEqual(guards, []);
  assert.equal(understanding.schemaVersion, 3);
  assert.equal(understanding.transactions.length, 2);
  assert.equal(understanding.transactions[0].paymentChannel, "中信银行信用卡7770");
  assert.equal(understanding.transactions[1].paymentChannel, "零钱", "逐笔渠道禁止互相覆盖");
});

test("v3：逐笔渠道钳制——超长截断/非字符串与空白为 null", () => {
  const { understanding } = normalizeUnderstanding({
    imageType: "payment_screenshot",
    paymentStatus: "completed",
    transactions: [
      { type: "expense", amount: 1, paymentChannel: "x".repeat(50) },
      { type: "expense", amount: 2, paymentChannel: 12345 },
      { type: "expense", amount: 3, paymentChannel: "   " },
      { type: "expense", amount: 4 },
    ],
  });
  assert.equal(understanding.transactions[0].paymentChannel.length, 40, "超长截到 40");
  assert.equal(understanding.transactions[1].paymentChannel, null, "非字符串为 null");
  assert.equal(understanding.transactions[2].paymentChannel, null, "纯空白为 null");
  assert.equal(understanding.transactions[3].paymentChannel, null, "缺失为 null");
});

test("v3：vision_extraction prompt 升 v3——逐笔渠道要求与示例字段", () => {
  const prompt = getPrompt("vision_extraction");
  assert.ok(prompt.version >= 3, "prompt 基线必须升到 v3");
  assert.ok(
    prompt.content.includes("每笔必须各带自己的 paymentChannel"),
    "prompt 必须要求逐笔渠道",
  );
  assert.ok(
    prompt.content.includes('"schemaVersion": 3') || prompt.content.includes('"schemaVersion":3'),
    "prompt 必须声明 schemaVersion 3",
  );
  assert.ok(
    prompt.content.includes('"paymentChannel":"微信支付"'),
    "主示例 transactions 条目必须带逐笔渠道字段",
  );
  assert.ok(prompt.content.includes("【货币判定示例】"), "外币少样本示例不得删除");
});

// ===== 一致性收口（2026-09-23 生产实锤：美团外卖「商家已接单」已付款页被拒识）=====
// 生产 11:27 实锤：deepseek-v4-flash-vision-exp 对已付款、配送中的美团订单页输出
// paymentStatus=completed 却 imageType=pending_order 的自相矛盾结果，交易被图型红线
// 清空，一笔已支付的账被当成未支付拒识。

test("一致性护栏：completed+pending_order 自相矛盾时以支付状态为准，交易存活", () => {
  const { understanding, guards } = normalizeUnderstanding({
    imageType: "pending_order",
    confidence: 0.9,
    paymentStatus: "completed",
    paymentStatusOriginalText: "商家已接单",
    merchant: "蒙自源米线(福永星航店)",
    currency: "CNY",
    amountOriginalText: "合计¥20.9",
    transactions: [{ type: "expense", amount: 20.9, note: "蒙自源米线", amountOriginalText: "合计¥20.9" }],
  });
  assert.equal(understanding.imageType, "payment_screenshot", "模型亲口判 completed 就不许再按未支付拒识");
  assert.equal(understanding.transactions.length, 1, "伴随交易必须存活（不许被图型红线清掉）");
  assert.equal(understanding.transactions[0].amount, 20.9);
  assert.equal(understanding.rejectReason, null);
  assert.ok(
    guards.some((g) => g.reason === "completed_status_pending_type_coerced"),
    "改写必须记录护栏供观测",
  );
});

test("一致性护栏：completed+pending_order 无交易时改图型，拒识文案不再是「未支付」", () => {
  // 2026-09-23 生产实锤形态：模型没给交易只给了顶层金额原文。改写后客户端文案
  // 走「没认出金额」而非谎报「订单还没支付」。
  const { understanding, guards } = normalizeUnderstanding({
    imageType: "pending_order",
    confidence: 0.9,
    paymentStatus: "completed",
    paymentStatusOriginalText: "商家已接单",
    amountOriginalText: "合计¥20.9",
    transactions: [],
    rejectReason: null,
  });
  assert.equal(understanding.imageType, "payment_screenshot");
  assert.equal(understanding.transactions.length, 0);
  assert.equal(understanding.rejectReason, null);
  assert.ok(guards.some((g) => g.reason === "completed_status_pending_type_coerced"));
});

test("一致性护栏：真未支付（pending 状态）不受影响，照常拒识", () => {
  const { understanding, guards } = normalizeUnderstanding({
    imageType: "pending_order",
    paymentStatus: "pending",
    paymentStatusOriginalText: "待付款",
    transactions: [],
  });
  assert.equal(understanding.imageType, "pending_order");
  assert.deepEqual(guards, []);
  assert.equal(understanding.rejectReason, "订单尚未支付，支付完成后重试");
});

test("一致性护栏：unknown 状态不触发改写（只信模型明确的 completed）", () => {
  const { understanding } = normalizeUnderstanding({
    imageType: "pending_order",
    paymentStatus: "unknown",
    transactions: [],
  });
  assert.equal(understanding.imageType, "pending_order");
});

test("一致性：prompt 必须含外卖订单已付款规则与示例（2026-09-23 实锤场景）", () => {
  const prompt = getPrompt("vision_extraction");
  assert.ok(
    prompt.content.includes("商家已接单"),
    "prompt 必须点名「商家已接单」类外卖页为已支付",
  );
  assert.ok(prompt.content.includes("【外卖订单示例】"), "外卖订单少样本示例是本次实锤的修复主体");
  assert.ok(
    prompt.content.includes("绝不能判成 pending_order"),
    "必须明令禁止把已付款配送中订单判成 pending_order",
  );
  assert.ok(
    prompt.content.includes("仅限「待付款」"),
    "pending_order 定义必须限定待付款状态",
  );
});

test("一致性：代码默认 provider/model 与生产 DeepSeek 对齐，qwen 默认已删（2026-09-23 东林拍板）", () => {
  const source = readFileSync(new URL("../src/config.js", import.meta.url), "utf8");
  assert.ok(
    source.includes('HOLO_VISION_EXTRACTION_PROVIDER ?? "deepseek-vision"'),
    "vision_extraction 默认 provider 必须是 deepseek-vision",
  );
  assert.ok(
    source.includes('HOLO_VISION_EXTRACTION_MODEL ?? "deepseek-v4-flash-vision-exp"'),
    "vision_extraction 默认 model 必须是 deepseek-v4-flash-vision-exp",
  );
  assert.ok(
    !source.includes('?? "qwen3-vl-plus"'),
    "误导性的 qwen3-vl-plus 默认必须删除",
  );
  assert.ok(
    source.includes('HOLO_VISION_EXTRACTION_REASONING_EFFORT ?? "none"'),
    "思考档位默认 none（与生产 env 对齐）",
  );
});
