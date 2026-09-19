// 截图识别记账 · 图片理解单契约（docs/plans/2026-09-09-screenshot-receipt-billing-plan.md §2/§6）
// 职责：把视觉模型的自由文本输出收进确定性的 schema——解析、逐字段钳制、安全护栏。
// 铁律对齐 BillImportAIService「AI 只指认不发明」：模型的口头承诺（currency="CNY"）
// 不可信（评测实证：美元小票被整体归一化成 ¥），货币判定以逐字抄录的
// amountOriginalText 为准，命中外币符号一律强制拒识。

export const FOREIGN_MONEY_PATTERN = /[$€£]|USD|EUR|GBP|JPY|HKD|NT\$/i;

// v2（docs/finance/plans/2026-09-14-Holo图片账单快捷指令自动记账完整方案.md §7/§26）：
// 为「自动落账」升级契约——支付状态 + 逐笔字段级置信度 + 分类语义候选。
// v1 字段全部保留（旧客户端兼容）；新客户端对缺失新字段一律按不可自动写处理。
// v3（2026-09-19）：一图多笔各笔支付渠道可能不同（微信支付服务通知流实证：
// 同图两笔分别为信用卡/零钱）——transactions 每笔新增 paymentChannel，
// 顶层字段保留作整单回落。纯加字段，v2 客户端忽略未知键零破坏。
export const UNDERSTANDING_SCHEMA_VERSION = 3;

export const PAYMENT_STATUSES = [
  "completed",
  "refunded",
  "pending",
  "failed",
  "cancelled",
  "unknown",
];

// 未完成支付三类：即使图型是可记账的支付截图也绝不允许保留交易候选。
// refunded 不在列——退款到账是合法 income 候选，由客户端门禁结合证据判断。
const AUTO_INELIGIBLE_PAYMENT_STATUSES = new Set(["pending", "failed", "cancelled"]);
const PAYMENT_STATUS_IMAGE_TYPES = { pending: "pending_order", failed: "unrelated", cancelled: "unrelated" };

export const UNDERSTANDING_IMAGE_TYPES = [
  "receipt",
  "payment_screenshot",
  "transfer_screenshot",
  "wealth_screenshot",
  "list_note",
  "foreign_currency",
  "pending_order",
  "unrelated",
];

const DEFAULT_REJECT_REASONS = {
  transfer_screenshot: "这是转账/还款类截图，属于资金流转，不计入收支",
  wealth_screenshot: "这是理财/余额页面，不涉及记账",
  list_note: "这是清单类内容，暂不支持转任务",
  foreign_currency: "外币消费暂不支持记账",
  pending_order: "订单尚未支付，支付完成后重试",
  unrelated: "这张图里没有可记账的内容",
};

const BILLABLE_TYPES = new Set(["receipt", "payment_screenshot"]);

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

function clampString(value, maxLength) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed.slice(0, maxLength) : null;
}

function clampAmount(value) {
  const number = Math.abs(Number(value));
  if (!Number.isFinite(number) || number <= 0) return null;
  return Math.round(number * 100) / 100;
}

function clampDate(value) {
  return typeof value === "string" && ISO_DATE.test(value.trim()) ? value.trim() : null;
}

/** 字段级置信度钳制：数字夹到 0...1；非数字/缺失一律 null（null=不可作为自动写依据）。 */
function clampConfidence(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return null;
  return Math.min(1, Math.max(0, number));
}

function normalizeTransactionConfidence(raw) {
  const source = raw && typeof raw === "object" ? raw : {};
  const pick = (key) => (source[key] === undefined || source[key] === null ? null : clampConfidence(source[key]));
  return {
    amount: pick("amount"),
    direction: pick("direction"),
    paymentStatus: pick("paymentStatus"),
    date: pick("date"),
    merchant: pick("merchant"),
    paymentChannel: pick("paymentChannel"),
  };
}

/** 从模型自由文本里抠出 JSON 对象（容忍代码块围栏与前后闲话）。解析失败抛错。 */
export function extractJsonContent(text) {
  if (typeof text !== "string" || text.length === 0) {
    throw new Error("empty vision model content");
  }
  const cleaned = text.trim().replace(/^```(?:json)?/i, "").replace(/```$/, "").trim();
  const start = cleaned.indexOf("{");
  const end = cleaned.lastIndexOf("}");
  if (start < 0 || end <= start) {
    throw new Error(`no JSON object in vision model content: ${cleaned.slice(0, 120)}`);
  }
  return JSON.parse(cleaned.slice(start, end + 1));
}

/**
 * 归一化 + 护栏。返回 { understanding, guards }；guards 记录被护栏改写的行为，
 * 供客户端提示与日志观测。任何字段异常都被钳制成合法值，绝不抛出半截 schema。
 */
export function normalizeUnderstanding(raw) {
  const guards = [];
  const source = raw && typeof raw === "object" ? raw : {};

  let imageType = UNDERSTANDING_IMAGE_TYPES.includes(source.imageType)
    ? source.imageType
    : "unrelated";
  if (source.imageType !== imageType) {
    guards.push({ field: "imageType", from: source.imageType ?? null, to: imageType });
  }

  const confidenceRaw = Number(source.confidence);
  const confidence = Number.isFinite(confidenceRaw)
    ? Math.min(1, Math.max(0, confidenceRaw))
    : 0.5;

  // v2 支付状态：非法值钳制为 unknown 并记录 guard（改写可观测）。
  const paymentStatusRaw = typeof source.paymentStatus === "string" ? source.paymentStatus.trim().toLowerCase() : "";
  const paymentStatus = PAYMENT_STATUSES.includes(paymentStatusRaw) ? paymentStatusRaw : "unknown";
  if (paymentStatusRaw !== "" && paymentStatusRaw !== paymentStatus) {
    guards.push({ field: "paymentStatus", from: source.paymentStatus, to: paymentStatus });
  }
  const paymentStatusOriginalText = clampString(source.paymentStatusOriginalText, 60);

  let transactions = (Array.isArray(source.transactions) ? source.transactions : [])
    .slice(0, 10)
    .map((transaction) => {
      const amount = clampAmount(transaction?.amount);
      if (amount === null) return null;
      return {
        type: transaction?.type === "income" ? "income" : "expense",
        amount,
        note: clampString(transaction?.note, 120),
        date: clampDate(transaction?.date),
        // v2 逐笔新增：金额原文、字段级置信度、分类语义候选。
        // 分类只给语义候选，禁止模型输出用户账本里的分类名/ID（最终匹配在 iOS 本地完成）。
        // v3 逐笔新增：该笔自己的支付渠道（多笔渠道可能不同），iOS 逐笔匹配账户。
        amountOriginalText: clampString(transaction?.amountOriginalText, 60),
        paymentChannel: clampString(transaction?.paymentChannel, 40),
        confidence: normalizeTransactionConfidence(transaction?.confidence),
        categoryCandidate: clampString(transaction?.categoryCandidate, 120),
        normalizedCategoryCandidate: clampString(transaction?.normalizedCategoryCandidate, 120),
        semanticCategoryHint: clampString(transaction?.semanticCategoryHint, 40),
      };
    })
    .filter(Boolean);
  if (Array.isArray(source.transactions) && transactions.length !== Math.min(source.transactions.length, 10)) {
    guards.push({ field: "transactions", reason: "invalid_entries_dropped" });
  }

  // 护栏一（货币红线）：金额原文或 currency 命中外币符号 → 强制拒识。
  // 不信模型自己填的 currency（评测实证它会把 USD 小票填成 CNY）。
  const amountOriginalText = clampString(source.amountOriginalText, 60);
  const currency = clampString(source.currency, 8) ?? "CNY";
  const foreignByOriginalText = amountOriginalText !== null && FOREIGN_MONEY_PATTERN.test(amountOriginalText);
  const foreignByCurrency = currency !== null && !/CNY|RMB|人民币/i.test(currency);
  if (transactions.length > 0 && (foreignByOriginalText || foreignByCurrency)) {
    guards.push({
      field: "transactions",
      reason: "foreign_currency_forced_reject",
      amountOriginalText,
      currency,
    });
    transactions = [];
    imageType = "foreign_currency";
  }

  // 护栏二（v2 支付状态红线）：未完成支付（待付/失败/已取消）绝不允许保留消费候选。
  // 图型同步映射成对应拒识类型，让客户端既有文案给出正确解释（待付款/无法识别）。
  if (transactions.length > 0 && AUTO_INELIGIBLE_PAYMENT_STATUSES.has(paymentStatus)) {
    guards.push({
      field: "transactions",
      reason: "payment_status_forced_clear",
      paymentStatus,
    });
    transactions = [];
    imageType = PAYMENT_STATUS_IMAGE_TYPES[paymentStatus];
  }

  // 护栏三（图型红线）：不可记账图型绝不允许携带交易——模型偶尔会无视规则
  // 给转账/待付款截图也塞 transactions，这里兜底清掉。
  if (!BILLABLE_TYPES.has(imageType) && transactions.length > 0) {
    guards.push({ field: "transactions", reason: `non_billable_type_${imageType}_forced_clear` });
    transactions = [];
  }

  const understanding = {
    schemaVersion: UNDERSTANDING_SCHEMA_VERSION,
    imageType,
    confidence,
    paymentStatus,
    paymentStatusOriginalText,
    summary: clampString(source.summary, 200),
    merchant: clampString(source.merchant, 120),
    paidAt: clampDate(source.paidAt),
    paymentChannel: clampString(source.paymentChannel, 40),
    currency: imageType === "foreign_currency" ? (foreignByCurrency ? currency : "FOREIGN") : "CNY",
    amountOriginalText,
    items: (Array.isArray(source.items) ? source.items : [])
      .slice(0, 30)
      .map((item) => {
        const amount = clampAmount(item?.amount);
        const name = clampString(item?.name, 80);
        return amount !== null && name !== null ? { name, amount } : null;
      })
      .filter(Boolean),
    transactions,
    rejectReason: transactions.length === 0
      ? (clampString(source.rejectReason, 200) ?? DEFAULT_REJECT_REASONS[imageType])
      : null,
  };
  return { understanding, guards };
}
