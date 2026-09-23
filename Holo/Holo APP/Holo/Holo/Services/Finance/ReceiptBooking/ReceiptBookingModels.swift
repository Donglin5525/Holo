//
//  ReceiptBookingModels.swift
//  Holo
//
//  图片快捷指令自动记账 · 领域契约（2026-09-14 完整方案 §23.2/§23.3/§24.1）
//  全部是纯值类型：跨 await 只传 UUID/String/Decimal/Date 快照，
//  禁止 UIImage / Account / Category / FinanceProject / 聊天消息对象进入本层。
//

import Foundation

// MARK: - 来源与选择

/// 识别图片的入口来源（方案 §23.2）
enum ReceiptBookingSource: String, Codable, Sendable, Equatable {
    case chat
    case shortcutScreenshot
    case shortcutCamera
    case shareSheet
    case lockedCamera
}

/// 账户选择（方案 §21.2）：自动识别，或用户在某条快捷指令里固定的账户
enum ReceiptAccountChoice: Codable, Sendable, Equatable {
    case automatic
    case fixed(UUID)
}

/// 项目选择（方案 §21.3）：不挂 / 按图片与附言明确匹配 / 固定项目。
/// 计划文本用 none 命名；Swift 里 none 与 Optional 语义相撞，改用 noProject，语义不变。
enum ReceiptProjectChoice: Codable, Sendable, Equatable {
    case noProject
    case explicitTextMatch
    case fixed(UUID)
}

/// 处理方式：安全时自动记账 / 始终先确认（AppEnum 一致性在 AppIntents 文件里补充）
enum ReceiptBookingMode: String, Codable, Sendable, Equatable, CaseIterable {
    case autoWhenSafe
    case alwaysReview
}

// MARK: - 请求

struct ReceiptBookingRequest: Sendable {
    /// 原始图片数据（调用方拿到什么传什么；压缩/规范化在协调器内完成）
    let rawImageData: Data
    let source: ReceiptBookingSource
    let mode: ReceiptBookingMode
    /// 用户附言（最长 200 字，调用方或协调器裁剪）
    let caption: String?
    /// 截图/拍摄的捕获时间（快捷指令来源用于「无票面日期时用捕获当天」）
    let capturedAt: Date
    let invocationID: UUID
    let accountChoice: ReceiptAccountChoice
    let projectChoice: ReceiptProjectChoice
}

// MARK: - 原因码（方案 §24.1，稳定机器码，文案在展示层映射）

enum ReceiptBookingReason: String, Sendable, Equatable, CaseIterable {
    // ---- 复核类 ----
    case reviewMultipleTransactions = "review.multipleTransactions"
    case reviewAmountLowConfidence = "review.amountLowConfidence"
    case reviewAmountConflict = "review.amountConflict"
    case reviewDirectionLowConfidence = "review.directionLowConfidence"
    case reviewPaymentStatusLowConfidence = "review.paymentStatusLowConfidence"
    case reviewDateMissingForHistoricalImage = "review.dateMissingForHistoricalImage"
    case reviewDateOutsideProjectRange = "review.dateOutsideProjectRange"
    case reviewPossibleDuplicate = "review.possibleDuplicate"
    case reviewAccountChoiceUnavailable = "review.accountChoiceUnavailable"
    case reviewProjectChoiceUnavailable = "review.projectChoiceUnavailable"
    case reviewProjectAmbiguous = "review.projectAmbiguous"
    case reviewProjectNotSupportedForIncome = "review.projectNotSupportedForIncome"
    case reviewContractGuarded = "review.contractGuarded"
    /// 旧契约（schemaVersion<2 或缺字段级置信度）：缺字段一律复核，不用整体 confidence 冒充
    case reviewLegacyContract = "review.legacyContract"
    // ---- 拒绝类 ----
    case rejectTransfer = "reject.transfer"
    case rejectWealth = "reject.wealth"
    case rejectPending = "reject.pending"
    case rejectFailedPayment = "reject.failedPayment"
    case rejectForeignCurrency = "reject.foreignCurrency"
    case rejectUnrelated = "reject.unrelated"
    case rejectInvalidImage = "reject.invalidImage"
    // ---- 失败类 ----
    case failureNetwork = "failure.network"
    case failureRateLimited = "failure.rateLimited"
    case failureServer = "failure.server"
    case failureCancelled = "failure.cancelled"
    case failureNotConfigured = "failure.notConfigured"

    var isReview: Bool { rawValue.hasPrefix("review.") }
    var isReject: Bool { rawValue.hasPrefix("reject.") }
    var isFailure: Bool { rawValue.hasPrefix("failure.") }

    /// 拒识原因的用户文案。快捷指令结果文字与结果通知共用同一份口径。
    /// 2026-09-23 拒识反馈必达（东林拍板）：拒绝类必须让用户看到「没记+原因」，
    /// 不允许静默——后台/自动化运行时快捷指令的结果文字用户根本看不到。
    nonisolated var rejectionUserText: String {
        switch self {
        case .rejectTransfer:
            return String(localized: "这是转账/还款，属于资金流转，不计入收支。")
        case .rejectWealth:
            return String(localized: "这是理财/余额页面，没有需要记的账。")
        case .rejectPending:
            return String(localized: "订单还没支付。支付完成后再试一次。")
        case .rejectFailedPayment:
            return String(localized: "支付没有完成或已取消，不记账。")
        case .rejectForeignCurrency:
            return String(localized: "这是外币消费，目前只支持人民币记账。")
        case .rejectUnrelated:
            return String(localized: "这张图里没有能记账的内容。")
        case .rejectInvalidImage:
            return String(localized: "没认出可靠的金额，没有入账。截图仍在照片里，可以拍清楚些再试。")
        default:
            return String(localized: "这张图不适合记账，未入账。")
        }
    }
}

// MARK: - 结果回执

/// 「识别于 …」时间文案（2026-09-23 起确认页与复核列表必显）：
/// 今天/昨天用相对表述，更早用「M月d日 HH:mm」。历史草案必须一眼可辨，
/// 杜绝旧识别结果被当成这次的（东林 9-23 实锤：昨天的 65 元草案被当成今天识别的金额）。
nonisolated enum ReceiptRecognizedTimeText {
    static func text(for date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        if calendar.isDateInToday(date) {
            return String(localized: "今天 \(timeFormatter.string(from: date))")
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "昨天 \(timeFormatter.string(from: date))")
        }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdHHmm")
        return formatter.string(from: date)
    }
}

/// 自动记账成功（或命中精确重复返回既有交易）的回执快照
struct ReceiptBookingReceipt: Sendable {
    let transactionID: UUID
    /// 展示用摘要，如「已记 ¥19.90 · 瑞幸咖啡 · 餐饮/咖啡 · 微信 · 无项目」
    let summaryText: String
    let usedDefaultAccount: Bool
    let categoryNeedsConfirmation: Bool
    /// 截图无票面日期、按捕获当天推断
    let dateInferredFromCapture: Bool
    let sourceKey: String
    let itemKey: String
    /// 限时撤销权（方案 §25.4：10 分钟内有效；duplicate 命中的既有交易不发撤销权）
    let undoToken: UUID?
    let createdAt: Date
}

/// 逐笔复核快照（2026-09-19 一图多笔）：每笔独立幂等键与解析上下文。
/// 账户/科目/项目最终解析在复核确认时按笔完成。
struct ReceiptReviewItemSnapshot: Sendable, Equatable {
    /// 稳定条目键（transaction:0/1/…），复核确认与自动写共用（§25.2）
    let itemKey: String
    let amountText: String
    let typeIsIncome: Bool
    /// 票面日期（逐笔；缺了回落整单 paidAt）
    let dateText: String?
    let note: String?
    /// 该笔自己的支付渠道（v3 契约；缺了回落整单顶层渠道）
    let paymentChannel: String?
    /// 金额原文证据（复核页展示，方案 §7：原文必须保留）
    let amountOriginalText: String?
    /// 分类语义候选（复核确认重走分类链）
    let categoryCandidate: String?
    let normalizedCategoryCandidate: String?
    let semanticCategoryHint: String?
    /// 逐笔警示（金额/方向低置信等），确认页在该笔卡片上提示
    let reviewNotes: [ReceiptBookingReason]
}

/// 待复核快照：一张图一个草案，内含全部待确认笔；只存必要纯值字段，
/// 不存图片与完整 OCR 正文（方案 §25.1）
struct ReceiptReviewSnapshot: Sendable, Equatable {
    let draftID: UUID
    /// 整单级原因（reviewMultipleTransactions/账户选择失效等）
    let reasons: [ReceiptBookingReason]
    /// 全部待确认笔（2026-09-19 一图多笔，上限 10）
    let items: [ReceiptReviewItemSnapshot]
    let merchant: String?
    let paymentStatusOriginalText: String?
    /// 幂等来源键（复核确认与自动写共用，§25.2）
    let sourceKey: String
    let createdAt: Date

    var primaryItem: ReceiptReviewItemSnapshot? { items.first }

    /// 合计金额文本：仅当全部笔同向时有意义；混合方向返回 nil
    var uniformTotalAmountText: String? {
        guard let first = items.first, !items.isEmpty else { return nil }
        guard items.allSatisfy({ $0.typeIsIncome == first.typeIsIncome }) else { return nil }
        let total = items.reduce(Decimal(0)) {
            $0 + (ReceiptBookingCoordinator.decimal(fromText: $1.amountText) ?? 0)
        }
        return ReceiptBookingCoordinator.formatAmount(total)
    }
}

struct ReceiptBookingFailure: Sendable, Equatable {
    let reason: ReceiptBookingReason
    let retryable: Bool
    let userMessage: String
}

// MARK: - 统一结果

enum ReceiptBookingOutcome: Sendable {
    case booked(ReceiptBookingReceipt)
    case needsReview(ReceiptReviewSnapshot)
    case rejected(ReceiptBookingReason)
    case duplicate(ReceiptBookingReceipt)
    case failed(ReceiptBookingFailure)
}

// MARK: - 纯值草案（方案 §23.3）

/// 分类/账户/项目解析完成、尚未写库的草案。金额一律 Decimal，禁 Double。
struct ResolvedTransactionDraft: Sendable, Equatable {
    /// 稳定条目键（transaction:0/1/…；多笔复核确认时逐笔一个键）
    let itemKey: String
    let amount: Decimal
    let typeIsIncome: Bool
    let date: Date
    /// 日期是按捕获时间推断的（非票面日期）
    let dateInferredFromCapture: Bool
    let note: String?
    let remark: String?

    // 分类
    let categoryID: UUID
    let categoryPrimaryName: String?
    let categorySubName: String?
    /// 是否落到「待分类」（分类不确定允许自动写，回执须写明）
    let categoryIsPendingFallback: Bool

    // 账户
    let accountID: UUID
    let accountName: String
    let usedDefaultAccount: Bool

    // 项目
    let financeProjectID: UUID?
    let financeProjectName: String?

    // 图片证据（方案 §7：原文证据字段必须保留）
    let amountOriginalText: String?
    let paymentStatusOriginalText: String?
    let paymentChannelOriginalText: String?

    // 字段级置信度（nil = 模型未提供 = 不可作为自动写依据）
    let confidenceAmount: Double?
    let confidenceDirection: Double?
    let confidencePaymentStatus: Double?
    let confidenceDate: Double?

    // 幂等
    let imageDigest: String
    let sourceKey: String
    let schemaVersion: Int

    /// AI 候选（分类待确认时供编辑学习链）
    let aiCandidate: String?
}
