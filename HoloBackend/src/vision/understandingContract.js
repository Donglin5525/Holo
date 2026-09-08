// 截图识别记账 · 图片理解单契约（docs/plans/2026-09-09-screenshot-receipt-billing-plan.md §2/§6）
// 职责：把视觉模型的自由文本输出收进确定性的 schema——解析、逐字段钳制、安全护栏。
// 铁律对齐 BillImportAIService「AI 只指认不发明」：模型的口头承诺（currency="CNY"）
// 不可信（评测实证：美元小票被整体归一化成 ¥），货币判定以逐字抄录的
// amountOriginalText 为准，命中外币符号一律强制拒识。

export const FOREIGN_MONEY_PATTERN = /[$€£]|USD|EUR|GBP|JPY|HKD|NT\$/i;

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

  // 护栏二（图型红线）：不可记账图型绝不允许携带交易——模型偶尔会无视规则
  // 给转账/待付款截图也塞 transactions，这里兜底清掉。
  if (!BILLABLE_TYPES.has(imageType) && transactions.length > 0) {
    guards.push({ field: "transactions", reason: `non_billable_type_${imageType}_forced_clear` });
    transactions = [];
  }

  const understanding = {
    imageType,
    confidence,
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
