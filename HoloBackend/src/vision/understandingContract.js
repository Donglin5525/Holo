// 截图识别记账 · 图片理解单契约（docs/plans/2026-09-09-screenshot-receipt-billing-plan.md §2/§6）
// 职责：把视觉模型的自由文本输出收进确定性的 schema——解析、逐字段钳制、安全护栏。
// 铁律对齐 BillImportAIService「AI 只指认不发明」：模型的口头承诺（currency="CNY"）
// 不可信（评测实证：美元小票被整体归一化成 ¥），货币判定以逐字抄录的
// amountOriginalText 为准，命中外币符号一律强制拒识。

// 「JP¥」里 ¥ 不是字母 Y，旧模式 JPY 匹配不到它；中文货币名（日元/美元等）同理
// 是金额原文里可能逐字出现的外币信号，一并收录。
export const FOREIGN_MONEY_PATTERN = /[$€£]|JP¥|USD|EUR|GBP|JPY|HKD|NT\$|美元|日元|欧元|英镑|港元|港币/i;

// v2（docs/finance/plans/2026-09-14-Holo图片账单快捷指令自动记账完整方案.md §7/§26）：
// 为「自动落账」升级契约——支付状态 + 逐笔字段级置信度 + 分类语义候选。
// v1 字段全部保留（旧客户端兼容）；新客户端对缺失新字段一律按不可自动写处理。
// v3（2026-09-19）：一图多笔各笔支付渠道可能不同（微信支付服务通知流实证：
// 同图两笔分别为信用卡/零钱）——transactions 每笔新增 paymentChannel，
// 顶层字段保留作整单回落。纯加字段，v2 客户端忽略未知键零破坏。
// v4（2026-11-06 截图记账开放转账/红包，docs/finance/plans/2026-11-06-截图记账开放转账与红包识别方案.md）：
// 新增可记账图型 personal_transfer（与他人之间的转账/红包，真实收支）；transfer_screenshot
// 收窄为「自己账户之间挪钱」（还款/提现/充值/理财申赎，仍拒识）。transactions 每笔新增
// transfer 对象（非转账恒为 null）。personal_transfer 只下发给声明了能力的客户端，
// 其余一律按老口径降级——老版本 App 行为不变。纯加字段，v3 客户端忽略未知键零破坏。
export const UNDERSTANDING_SCHEMA_VERSION = 4;

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
  "personal_transfer",
  "transfer_screenshot",
  "wealth_screenshot",
  "list_note",
  "foreign_currency",
  "pending_order",
  "unrelated",
];

const DEFAULT_REJECT_REASONS = {
  personal_transfer: "这笔转账或红包已经退回、过期或没有完成，不用记账",
  transfer_screenshot: "这是还款、提现或理财这类资金挪动，不计入收支",
  wealth_screenshot: "这是理财/余额页面，不涉及记账",
  list_note: "这是清单类内容，暂不支持转任务",
  foreign_currency: "外币消费暂不支持记账",
  pending_order: "订单尚未支付，支付完成后重试",
  unrelated: "这张图里没有可记账的内容",
};

const BILLABLE_TYPES = new Set(["receipt", "payment_screenshot", "personal_transfer"]);

// ---- 个人转账/红包（v4）----
// 客户端在识图请求里声明的能力名；只有声明了它且服务端总闸开着，personal_transfer 才放行。
export const VISION_CAPABILITY_PERSONAL_TRANSFER = "personal_transfer";
const TRANSFER_KINDS = new Set(["transfer", "red_packet"]);
// 转账「没成」的状态：已退回/失败/取消——不记账，但图型保持 personal_transfer，
// 让客户端给出「已退回或没有完成」的准确解释（而不是护栏二映射出的「待付款/无关图」）。
const TRANSFER_NOT_COMPLETED_STATUSES = new Set(["refunded", "failed", "cancelled"]);

/**
 * 识图请求的能力解析。capabilities 非数组、元素非字符串、空数组一律视为未声明（安全侧降级）。
 * @returns {{ allowPersonalTransfer: boolean }}
 */
export function resolveVisionCapabilities(body, { personalTransferEnabled }) {
  const declared = Array.isArray(body?.capabilities)
    ? body.capabilities.filter((capability) => typeof capability === "string")
    : [];
  return {
    allowPersonalTransfer: personalTransferEnabled === true
      && declared.includes(VISION_CAPABILITY_PERSONAL_TRANSFER),
  };
}

function normalizeTransferInfo(raw) {
  const source = raw && typeof raw === "object" ? raw : {};
  return {
    kind: TRANSFER_KINDS.has(source.kind) ? source.kind : "transfer",
    counterparty: clampString(source.counterparty, 60),
    counterpartyAccount: clampString(source.counterpartyAccount, 40),
    awaitingReceipt: source.awaitingReceipt === true,
  };
}

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
 * allowPersonalTransfer：调用方用 resolveVisionCapabilities 按「客户端声明 + 服务端总闸」算出；
 * 缺省 false = 老口径（personal_transfer 降级为 transfer_screenshot 并清空交易）。
 */
export function normalizeUnderstanding(raw, { allowPersonalTransfer = false } = {}) {
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
  let paymentStatus = PAYMENT_STATUSES.includes(paymentStatusRaw) ? paymentStatusRaw : "unknown";
  if (paymentStatusRaw !== "" && paymentStatusRaw !== paymentStatus) {
    guards.push({ field: "paymentStatus", from: source.paymentStatus, to: paymentStatus });
  }
  const paymentStatusOriginalText = clampString(source.paymentStatusOriginalText, 60);

  const isPersonalTransfer = imageType === "personal_transfer";
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
        // v4 逐笔新增：转账信息只属于 personal_transfer，其余图型恒为 null（键恒在）。
        transfer: isPersonalTransfer ? normalizeTransferInfo(transaction?.transfer) : null,
      };
    })
    .filter(Boolean);
  if (Array.isArray(source.transactions) && transactions.length !== Math.min(source.transactions.length, 10)) {
    guards.push({ field: "transactions", reason: "invalid_entries_dropped" });
  }

  // 转账块（v4）：必须先于下方护栏一至四执行——护栏二会把 pending 的交易清空并把图型
  // 改成 pending_order、把 failed/cancelled 改成 unrelated；护栏四会清掉非可记账图型的
  // 交易。不前置，放行结果会被既有护栏静默击败（方案审核 P1）。
  if (isPersonalTransfer) {
    if (!allowPersonalTransfer) {
      // 老客户端 / 总闸关闭：退回老口径，与 v3 时代完全一致
      guards.push({ field: "imageType", reason: "personal_transfer_not_enabled", from: imageType, to: "transfer_screenshot" });
      imageType = "transfer_screenshot";
      transactions = [];
    } else if (paymentStatus === "pending") {
      // 「待对方收款/待你收款/红包未领完」：钱已经离开或即将到账，东林拍板照常记账并提示。
      // 这是领域口径而非数据异常，不记 guard——guard 会让客户端显示「识别结果有异常」。
      paymentStatus = "completed";
      transactions = transactions.map((transaction) => ({
        ...transaction,
        transfer: { ...transaction.transfer, awaitingReceipt: true },
      }));
    } else if (TRANSFER_NOT_COMPLETED_STATUSES.has(paymentStatus) && transactions.length > 0) {
      // 已退回/失败/取消：不记账，图型保持 personal_transfer（客户端据此说「已退回或没有完成」）
      guards.push({ field: "transactions", reason: "transfer_not_completed_cleared", paymentStatus });
      transactions = [];
    }
  }

  // 护栏一（货币红线）：实付金额本身是外币 → 强制拒识。
  // 不信模型自己填的 currency（评测实证它会把 USD 小票填成 CNY）。
  // 2026-10-01 境外人民币结算放行（微信支付境外消费账单实证：标价 6070 日元 +
  // 汇率明细 + 实付 ¥254.45）：这类账单实付的是人民币，不是外币。判定以逐笔
  // 金额原文为最强信号，分三档：
  //   任一笔 amountOriginalText 命中外币 → 拒（实付外币）；
  //   逐笔原文全部齐全且干净、仅顶层字段沾到外币（模型抄到标价/汇率行）→ 放行，
  //     currency 由输出层钳回 CNY，guard 记录供观测；
  //   逐笔原文缺失 → 回落旧口径：顶层 amountOriginalText / currency 命中即拒。
  const amountOriginalText = clampString(source.amountOriginalText, 60);
  const currency = clampString(source.currency, 8) ?? "CNY";
  const foreignByOriginalText = amountOriginalText !== null && FOREIGN_MONEY_PATTERN.test(amountOriginalText);
  const foreignByCurrency = currency !== null && !/CNY|RMB|人民币/i.test(currency);
  const foreignByTopLevel = foreignByOriginalText || foreignByCurrency;
  const anyForeignPerTransaction = transactions.some(
    (transaction) => transaction.amountOriginalText !== null
      && FOREIGN_MONEY_PATTERN.test(transaction.amountOriginalText)
  );
  const everyTransactionTextPresent = transactions.length > 0
    && transactions.every((transaction) => transaction.amountOriginalText !== null);
  if (transactions.length > 0 && (anyForeignPerTransaction || (foreignByTopLevel && !everyTransactionTextPresent))) {
    guards.push({
      field: "transactions",
      reason: "foreign_currency_forced_reject",
      amountOriginalText,
      currency,
    });
    transactions = [];
    imageType = "foreign_currency";
  } else if (transactions.length > 0 && foreignByTopLevel) {
    guards.push({
      field: "currency",
      reason: "foreign_settled_in_cny_allowed",
      amountOriginalText,
      currency,
    });
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

  // 护栏三（图型-状态一致性，2026-09-23）：模型自相矛盾时以它亲口给的支付状态为准。
  // 生产实锤（美团外卖「商家已接单」页）：模型一边把 paymentStatus 判成 completed，
  // 一边把 imageType 判成 pending_order——若不纠正，下方图型红线会把伴随的交易
  // 一并清掉，一笔已支付的账被当成未支付拒识。paymentStatus=completed 是模型的
  // 明确判断，pending_order 只能由 pending 状态支撑；此处改写图型让交易存活。
  // 必须排在图型红线之前。
  if (imageType === "pending_order" && paymentStatus === "completed") {
    guards.push({
      field: "imageType",
      reason: "completed_status_pending_type_coerced",
      from: imageType,
      to: "payment_screenshot",
    });
    imageType = "payment_screenshot";
  }

  // 护栏四（图型红线）：不可记账图型绝不允许携带交易——模型偶尔会无视规则
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
      ? (clampString(source.rejectReason, 200) ?? defaultRejectReason(imageType, paymentStatus))
      : null,
  };
  return { understanding, guards };
}

/** 图型默认拒识文案；personal_transfer 只有「没成」的状态才说已退回，其余空交易=没认出金额（iOS 同口径）。 */
function defaultRejectReason(imageType, paymentStatus) {
  if (imageType === "personal_transfer" && !TRANSFER_NOT_COMPLETED_STATUSES.has(paymentStatus)) {
    return null;
  }
  return DEFAULT_REJECT_REASONS[imageType] ?? null;
}
