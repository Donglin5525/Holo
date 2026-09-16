//
//  ReceiptBookingPolicy.swift
//  Holo
//
//  图片快捷指令自动记账 · 自动落账门禁（2026-09-14 完整方案 §8/§24/§26.2/§26.3）
//  纯函数：不访问 UI / 网络 / Core Data。模型只给候选，能否自动写由这里确定性决定。
//
//  阈值依据：docs/holoai-audit/vision-eval/README.md v2 评测（2026-09-15）
//  —— deepseek-v4-flash-vision-exp 在 0.90/0.95 档均零红线，首版取保守端 0.95；
//  真实截图语料回灌后复测再放宽。
//

import Foundation

/// 字段级自动写阈值（M0 评测定标；评测命令见 README「运行」）
enum ReceiptBookingPolicyThresholds {
    static let amount: Double = 0.95
    static let direction: Double = 0.95
    static let paymentStatus: Double = 0.95
}

/// 门禁输入快照：协调器把理解单 + 解析结果压成纯值后传入
struct ReceiptBookingPolicyInput: Sendable, Equatable {
    // 理解单快照
    let imageType: String
    let currency: String?
    let paymentStatus: String?          // v1 响应为 nil
    let schemaVersion: Int              // v1 响应视为 1
    let guardsPresent: Bool             // 服务端护栏发生过改写
    let transactions: [ReceiptBookingPolicyTransaction]

    // 解析层结论（DraftResolver 产出）
    let fixedAccountUnavailable: Bool
    let projectChoiceUnavailable: Bool
    let projectAmbiguous: Bool
    let incomeWithAttachedProject: Bool
    let transactionDateOutsideProjectRange: Bool

    // 语义重查结论
    let hasHighCertaintyDuplicate: Bool
    let hasAmbiguousDuplicate: Bool

    // 日期上下文
    let transactionHasExplicitDate: Bool
    let source: ReceiptBookingSource
}

struct ReceiptBookingPolicyTransaction: Sendable, Equatable {
    let amount: Decimal
    let typeIsIncome: Bool
    let confidenceAmount: Double?
    let confidenceDirection: Double?
    let confidencePaymentStatus: Double?
}

enum ReceiptBookingPolicyDecision: Sendable, Equatable {
    case autoCommit
    case needsReview([ReceiptBookingReason])
    case reject(ReceiptBookingReason)
}

enum ReceiptBookingPolicy {

    /// 唯一决策入口。返回值只有三态，禁止布尔（方案 §24.1）
    static func evaluate(
        input: ReceiptBookingPolicyInput,
        mode: ReceiptBookingMode
    ) -> ReceiptBookingPolicyDecision {
        // ---- 拒绝类（非消费凭证 / 未完成支付 / 外币）----
        guard input.transactions.count == 1 else {
            if input.transactions.isEmpty {
                return .reject(decideRejectForEmptyTransactions(input: input))
            }
            return .needsReview([.reviewMultipleTransactions])
        }

        if let reason = decideRejectForImageType(input.imageType) {
            return .reject(reason)
        }
        // 币种双保险：服务端护栏之外，客户端再验一次（金额原文外币已在服务端拦截）
        if let currency = input.currency, currency != "CNY" {
            return .reject(.rejectForeignCurrency)
        }

        // ---- 复核类（风险场景一律不自动写）----
        var reasons: [ReceiptBookingReason] = []

        // 服务端护栏改写过 → 数据不可信（§26.2：只能复核或拒绝）
        if input.guardsPresent {
            reasons.append(.reviewContractGuarded)
        }
        // 旧契约缺字段级置信度 → 一律复核（§26.2）
        if input.schemaVersion < 2 {
            reasons.append(.reviewLegacyContract)
        }
        // 支付状态：只有 completed / refunded 可作为候选（§26.3）
        switch input.paymentStatus {
        case "completed":
            break
        case "refunded":
            // 退款方向必须是 income；方向存疑转复核
            if !input.transactions[0].typeIsIncome {
                reasons.append(.reviewDirectionLowConfidence)
            }
        case "unknown", nil:
            // v1 载荷已由 reviewLegacyContract 标注；v2 显式 unknown 也要复核
            if input.schemaVersion >= 2 {
                reasons.append(.reviewPaymentStatusLowConfidence)
            }
        case "pending":
            return .reject(.rejectPending)
        case "failed", "cancelled":
            return .reject(.rejectFailedPayment)
        default:
            reasons.append(.reviewPaymentStatusLowConfidence)
        }

        // 字段级置信度（缺失 = 不可作为自动写依据）
        let tx = input.transactions[0]
        if (tx.confidenceAmount ?? -1) < ReceiptBookingPolicyThresholds.amount {
            reasons.append(.reviewAmountLowConfidence)
        }
        if (tx.confidenceDirection ?? -1) < ReceiptBookingPolicyThresholds.direction {
            reasons.append(.reviewDirectionLowConfidence)
        }
        if (tx.confidencePaymentStatus ?? -1) < ReceiptBookingPolicyThresholds.paymentStatus {
            reasons.append(.reviewPaymentStatusLowConfidence)
        }

        // 用户显式选择失效不得静默回退（方案 §21.2/§21.3/铁律 4）
        if input.fixedAccountUnavailable {
            reasons.append(.reviewAccountChoiceUnavailable)
        }
        if input.projectChoiceUnavailable {
            reasons.append(.reviewProjectChoiceUnavailable)
        }
        if input.projectAmbiguous {
            reasons.append(.reviewProjectAmbiguous)
        }
        // 收入/退款 + 挂项目冲突（方案 §21.3 项目安全规则）
        if tx.typeIsIncome && input.incomeWithAttachedProject {
            reasons.append(.reviewProjectNotSupportedForIncome)
        }
        if input.transactionDateOutsideProjectRange {
            reasons.append(.reviewDateOutsideProjectRange)
        }

        // 日期规则（方案 §24.2）：截图/拍摄来源可用捕获当天；旧图/分享无日期转复核
        if !input.transactionHasExplicitDate {
            switch input.source {
            case .shortcutScreenshot, .shortcutCamera:
                break // 捕获当天推断，草案标记 dateInferredFromCapture
            case .chat, .shareSheet, .lockedCamera:
                reasons.append(.reviewDateMissingForHistoricalImage)
            }
        }

        // 语义重复：同额同日同商户高确定性 → 不写入；模糊命中 → 复核（方案 §9.2）
        if input.hasHighCertaintyDuplicate {
            return .needsReview([.reviewPossibleDuplicate])
        }
        if input.hasAmbiguousDuplicate {
            reasons.append(.reviewPossibleDuplicate)
        }

        if reasons.isEmpty {
            return mode == .alwaysReview ? .needsReview([]) : .autoCommit
        }
        return .needsReview(reasons)
    }

    // MARK: - 图型与空交易的拒绝判定

    /// 可记账图型返回 nil；其余映射到稳定拒绝码
    private static func decideRejectForImageType(_ imageType: String) -> ReceiptBookingReason? {
        switch imageType {
        case "receipt", "payment_screenshot":
            return nil
        case "transfer_screenshot":
            return .rejectTransfer
        case "wealth_screenshot":
            return .rejectWealth
        case "foreign_currency":
            return .rejectForeignCurrency
        case "pending_order":
            return .rejectPending
        case "list_note", "unrelated":
            return .rejectUnrelated
        default:
            return .rejectUnrelated
        }
    }

    /// 交易数组为空：优先按支付状态给精确原因，其次按图型，兜底无法确认金额
    private static func decideRejectForEmptyTransactions(input: ReceiptBookingPolicyInput) -> ReceiptBookingReason {
        switch input.paymentStatus {
        case "pending":
            return .rejectPending
        case "failed", "cancelled":
            return .rejectFailedPayment
        default:
            break
        }
        if let reason = decideRejectForImageType(input.imageType) {
            return reason
        }
        // 可记账图型但没能可靠认出金额（与聊天拒识口径一致：宁可问不瞎猜）
        return .rejectInvalidImage
    }
}
