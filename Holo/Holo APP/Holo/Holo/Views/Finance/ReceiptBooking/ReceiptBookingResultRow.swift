//
//  ReceiptBookingResultRow.swift
//  Holo
//
//  图片快捷指令自动记账 · 结果行（2026-09-14 完整方案 §11/§25.4）
//  booked 且在撤销窗口内（10 分钟）提供精确撤销：只删本次明确创建的交易 ID，
//  不做模糊搜索删除；duplicate 命中的既有交易不发撤销权。
//

import SwiftUI

struct ReceiptBookingResultRow: View {
    let result: ReceiptBookingResultStore.StoredResult
    var onChanged: () -> Void

    @State private var showUndoConfirmation = false
    @State private var undoneLocally = false
    @State private var undoErrorMessage: String?

    private let undoWindow: TimeInterval = 10 * 60

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(mainText)
                    .font(.subheadline)
                Text(timeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if canUndo {
                Button("撤销") {
                    showUndoConfirmation = true
                }
                .font(.footnote)
                .buttonStyle(.bordered)
            }
        }
        .confirmationDialog("撤销这笔刚记的账？", isPresented: $showUndoConfirmation, titleVisibility: .visible) {
            Button("撤销这笔", role: .destructive) {
                undo()
            }
        }
        .alert("撤销失败", isPresented: Binding(
            get: { undoErrorMessage != nil },
            set: { if !$0 { undoErrorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(undoErrorMessage ?? "请到交易详情中手动删除。")
        }
    }

    private var effectiveKind: ReceiptBookingResultStore.StoredOutcomeKind {
        undoneLocally ? .undone : result.kind
    }

    private var iconName: String {
        switch effectiveKind {
        case .booked: return "checkmark.circle.fill"
        case .duplicate: return "doc.on.doc"
        case .needsReview: return "exclamationmark.circle"
        case .rejected: return "hand.raised"
        case .failed: return "xmark.circle"
        case .undone: return "arrow.uturn.backward.circle"
        }
    }

    private var iconColor: Color {
        switch effectiveKind {
        case .booked: return .green
        case .duplicate: return .blue
        case .needsReview: return .orange
        case .rejected: return .secondary
        case .failed: return .red
        case .undone: return .secondary
        }
    }

    private var mainText: String {
        switch effectiveKind {
        case .booked:
            return result.summaryText ?? String(localized: "已记账")
        case .duplicate:
            return result.summaryText.map { String(localized: "这张图已经记过：\($0)") } ?? String(localized: "这张图已经记过")
        case .needsReview:
            return String(localized: "已生成待复核项，未入账")
        case .rejected:
            return friendlyReasonText(result.reasonCode, fallback: String(localized: "没有发现需要记的账"))
        case .failed:
            return friendlyReasonText(result.reasonCode, fallback: String(localized: "记账没有成功"))
        case .undone:
            return String(localized: "已撤销")
        }
    }

    private func friendlyReasonText(_ code: String?, fallback: String) -> String {
        guard let code, let reason = ReceiptBookingReason(rawValue: code) else {
            return result.summaryText ?? fallback
        }
        switch reason {
        case .rejectTransfer: return String(localized: "资金转账，不计入收支")
        case .rejectWealth: return String(localized: "理财或余额页面，没有记账")
        case .rejectPending: return String(localized: "订单尚未支付，没有记账")
        case .rejectFailedPayment: return String(localized: "支付未完成，没有记账")
        case .rejectForeignCurrency: return String(localized: "暂不支持外币账单")
        case .rejectUnrelated, .rejectInvalidImage: return String(localized: "没有识别到可记账内容")
        case .failureNetwork: return String(localized: "网络不可用，未入账")
        case .failureRateLimited: return String(localized: "今日识别次数已用完")
        case .failureServer: return String(localized: "识别服务暂时不可用")
        case .failureCancelled: return String(localized: "已取消，未入账")
        case .failureNotConfigured: return String(localized: "图片记账尚未完成设置")
        default: return result.summaryText ?? fallback
        }
    }

    private var timeText: String {
        DateFormatter.localizedString(from: result.createdAt, dateStyle: .short, timeStyle: .short)
    }

    /// §25.4：10 分钟内的 booked 才有即时撤销；重复点击幂等
    private var canUndo: Bool {
        effectiveKind == .booked
            && result.undoToken != nil
            && Date().timeIntervalSince(result.createdAt) < undoWindow
    }

    private func undo() {
        // 2026-09-19 一图多笔：整批撤销——主笔 + additional 全删；任一缺失不阻断其余
        let ids = ([result.transactionID].compactMap { $0 } + (result.additionalTransactionIDs ?? []))
        guard !ids.isEmpty else { return }
        let repo = FinanceRepository.shared
        let transactions = ids.compactMap { repo.findTransaction(by: $0) }
        guard !transactions.isEmpty else {
            undoErrorMessage = String(localized: "没有找到这笔交易，可能已经被删除。")
            return
        }
        Task { @MainActor in
            do {
                for transaction in transactions {
                    try await repo.deleteTransaction(transaction)
                }
                await ReceiptBookingResultStore.shared.markUndone(resultID: result.id)
                undoneLocally = true
                onChanged()
            } catch {
                undoErrorMessage = String(localized: "没有撤销成功，请到交易详情中手动删除。")
            }
        }
    }
}
