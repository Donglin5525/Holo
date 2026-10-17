//
//  TransactionChatCard.swift
//  Holo
//
//  记账卡片视图（支出/收入）
//

import SwiftUI

struct TransactionChatCard: View {

    let data: TransactionCardData
    var isDeleted: Bool = false
    var onTap: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onModifyCategory: (() -> Void)?

    /// 金额主字号走 .amount 角色 token，随动态字体缩放（¥ 符号按 0.62 倍派生）
    @ScaledMetric(relativeTo: .largeTitle) private var heroAmountSize = HoloTextRole.amount.size

    var body: some View {
        // 已取消的记账没有关联实体，可点但无动作等于假交互：与待确认态一并禁点
        ChatCardView(isDeleted: isDeleted, onTap: data.requiresConfirmation || data.isCancelled ? nil : onTap) {
            if isConfirmed {
                confirmedCard
            } else {
                CardHeaderView(
                    icon: data.requiresConfirmation ? "yensign.circle" : data.categoryIcon,
                    title: headerTitle,
                    badge: badge,
                    subtitle: headerSubtitle,
                    isDeleted: isDeleted
                )

                // 金额
                Text(formattedAmount)
                    .holoText(.amount)
                    .monospacedDigit()
                    .foregroundColor(.holoToolText)
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
                    .strikethrough(isDeleted || data.isCancelled)

                // 备注
                if let note = data.note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.holoToolTextSecondary)
                        .strikethrough(isDeleted)
                }

                // 分类 + 记录日期
                categoryDateRow

                // 退款关联信息（确认后冲减原支出）
                if data.isRefundCandidate, data.requiresConfirmation {
                    refundCandidateInfo
                }

                // 分期信息
                if data.isInstallment, data.requiresConfirmation {
                    installmentInfo
                }

                if data.requiresConfirmation {
                    if !data.isInstallment && !data.isConfirming {
                        modifyCategoryLink
                    }
                    pendingActions
                } else if data.isCancelled {
                    cancelledInfo
                } else if data.isFailed {
                    failedInfo
                }
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Confirmed（已入账终态：金额主角卡）

    /// 已入账终态：正常确认完成（待确认 / 已取消 / 失败态走原有布局）
    private var isConfirmed: Bool {
        !data.requiresConfirmation && !data.isCancelled && !data.isFailed
    }

    /// 金额主角卡：金额做主视觉，标题与分类合并一行，底部日期 + 状态胶囊。
    /// 整卡可点进详情（外层 ChatCardView 的 Button 已覆盖），不再单独渲染「查看明细」入口。
    private var confirmedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hero 行：金额左对齐 + 分类图标右上角
            HStack(alignment: .top) {
                heroAmount
                Spacer(minLength: 12)
                categoryIconGlyph(data.categoryIcon, size: 11, color: .holoPrimary)
                    .frame(width: 24, height: 24)
                    .background(Color.holoPrimary.opacity(0.12))
                    .clipShape(Circle())
            }

            // 标题 · 分类（与金额行间距 4pt）
            metadataRow
                .padding(.top, 4)

            // hairline 分隔线
            Rectangle()
                .fill(Color.holoDivider.opacity(0.6))
                .frame(height: 0.5)
                .padding(.top, 12)

            // 底行：记账日期 + 状态胶囊
            bottomRow
                .padding(.top, 12)
        }
    }

    /// 金额主视觉：¥ 符号缩至 0.62 倍字号、与数字 baseline 对齐；
    /// fixedSize + lineLimit 保证「-¥12,345.67」级样例单行不换行不裁切（金额不靠缩字号适配）
    private var heroAmount: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(data.isExpense ? "-" : "+")
            Text("¥")
                .font(.system(size: heroAmountSize * 0.62, weight: .semibold))
            Text(data.amount)
                .monospacedDigit()
        }
        .font(.system(size: heroAmountSize, weight: .semibold))
        .foregroundColor(.holoToolText)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .strikethrough(isDeleted)
    }

    /// 「标题 · 分类」单行：空间不足时优先保分类完整（layoutPriority 给分类，先截标题尾部）
    private var metadataRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(metadataTitle)
                .holoText(.supporting)
                .fontWeight(.medium)
                .foregroundColor(.holoToolText)
                .lineLimit(1)
                .strikethrough(isDeleted)

            if let category = data.categoryPath {
                Text("·")
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
                Text(category)
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }

    /// 标题位文本：备注与派生标题同文（常态，displayTitle 即备注）时直接用标题；
    /// 不同文时用备注顶标题位，避免信息丢失
    private var metadataTitle: String {
        if let note = data.note, !note.isEmpty, note != data.displayTitle {
            return note
        }
        return data.displayTitle
    }

    /// 底行：左记账日期（沿用 relativeDateText 友好口径，今天补既有「今天」词条）+ 右状态胶囊
    private var bottomRow: some View {
        HStack {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 11))
                Text(confirmedDateText)
                    .holoText(.metadata)
                    .fontWeight(.medium)
                    .strikethrough(isDeleted)
            }
            .foregroundColor(.holoToolTextSecondary)

            Spacer()

            statusCapsule
        }
    }

    /// 终态卡日期：relativeDateText 今天返回 nil（旧口径为省空间不占位），
    /// 终态卡日期有专属槽位，用项目既有「今天」词条补齐
    private var confirmedDateText: String {
        relativeDateText ?? String(localized: "今天")
    }

    /// 右端状态胶囊：已删除回溯态沿用「已删除」灰胶囊，正常态「已入账」绿胶囊
    @ViewBuilder private var statusCapsule: some View {
        if isDeleted {
            Text("已删除")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.holoToolTextSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.holoToolTextSecondary.opacity(0.12)))
        } else {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                Text(String(localized: "已入账"))
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.holoToolSuccess)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.holoSuccess.opacity(0.1)))
        }
    }

    /// 无障碍朗读：终态完整读出金额、标题、分类、日期、已入账；其余分支维持原口径
    private var accessibilityText: String {
        if isConfirmed {
            let category = data.categoryPath ?? String(localized: "未分类")
            return String(localized: "记账卡片：\(data.displayTitle)，\(data.isExpense ? "支出" : "收入")\(data.amount)元，分类\(category)，\(confirmedDateText)，已入账")
        }
        return String(localized: "记账卡片：\(data.displayTitle)，\(data.isExpense ? "支出" : "收入")\(data.amount)元")
    }

    // MARK: - Header

    private var headerTitle: String {
        if data.requiresConfirmation {
            return data.isExpense ? String(localized: "支出待确认") : String(localized: "收入待确认")
        }
        return data.displayTitle
    }

    private var headerSubtitle: String? {
        if data.requiresConfirmation {
            return nil
        }
        return data.categoryPath
    }

    private var badge: CardBadge? {
        if data.requiresConfirmation {
            return CardBadge(text: String(localized: "待确认"), color: .holoPrimary)
        }
        if data.isCancelled {
            return CardBadge(text: String(localized: "已取消"), color: .holoToolTextSecondary)
        }
        return nil
    }

    // MARK: - Refund Candidate Info

    /// 退款关联块：显示将冲减的原支出，确认前让用户核对关联对象
    private var refundCandidateInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11))
                Text(String(localized: "退款 · 关联原支出"))
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.holoSuccessDark)

            if let title = data.refundCandidateTitle {
                let amountText = data.refundCandidateAmount.map { " · ¥\($0)" } ?? ""
                let dateText = data.refundCandidateDate.map { " · \($0)" } ?? ""
                Text("\(title)\(amountText)\(dateText)")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.holoToolTextSecondary)
            }

            Text(String(localized: "确认后自动冲减该笔支出，不计入收入"))
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.holoToolTextSecondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoSuccess.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Installment Info

    private var installmentInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 11))
                Text(data.installmentSummary ?? String(localized: "按月分期"))
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.holoPrimary)

            if let periods = data.installmentPeriods, periods > 0,
               let totalStr = data.installmentTotalAmount,
               let total = Decimal(string: totalStr) {
                let perPeriod = total / Decimal(periods)
                Text("每期 ¥\(perPeriod.description) × \(periods) 期")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.holoToolTextSecondary)
            }

            if let fee = data.installmentFeePerPeriod, fee != "0" {
                Text("手续费 ¥\(fee)/期")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.holoToolTextSecondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoPrimary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Modify Category Link

    private var modifyCategoryLink: some View {
        Button {
            onModifyCategory?()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .medium))
                Text("分类不准？点击修改")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.holoPrimary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pending Actions

    private var pendingActions: some View {
        HStack(spacing: 12) {
            Button {
                onCancel?()
            } label: {
                Text("取消")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(Color.holoToolTextSecondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(data.isConfirming)

            Button {
                onConfirm?()
            } label: {
                Text(data.isConfirming ? String(localized: "正在记录…") : String(localized: "确认"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoToolOnAction)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(data.isConfirming ? Color.holoToolAction.opacity(0.5) : Color.holoToolAction)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(data.isConfirming)
        }
    }

    // MARK: - Cancelled State

    private var cancelledInfo: some View {
        HStack {
            Text("已取消记账")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.holoToolTextSecondary)
            Spacer()
        }
    }

    // MARK: - Failed State

    private var failedInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = data.confirmationError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.holoToolError)
            }

            HStack {
                Spacer()
                Button {
                    onConfirm?()
                } label: {
                    Text("重试")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoToolOnAction)
                        .padding(.horizontal, 20)
                        .frame(minHeight: 44)
                        .background(Color.holoToolAction)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Formatting

    private var formattedAmount: String {
        if data.isExpense {
            return "-¥\(data.amount)"
        }
        return "+¥\(data.amount)"
    }

    /// 分类 + 记录日期行
    /// 分类始终展示；仅当日期非今天时在右侧露出（今天记账是常态，不占位）
    @ViewBuilder private var categoryDateRow: some View {
        let path = data.categoryPath
        let dateText = relativeDateText
        if path != nil || dateText != nil {
            HStack(spacing: 6) {
                if let path {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                        Text(path)
                            .font(.system(size: 13, weight: .medium))
                            .strikethrough(isDeleted)
                    }
                }

                Spacer()

                if let dateText {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 11))
                        Text(dateText)
                            .font(.system(size: 13, weight: .medium))
                            .strikethrough(isDeleted)
                    }
                }
            }
            .foregroundColor(.holoToolTextSecondary)
        }
    }

    /// 把 data.date 解析为相对文本：今天 → nil（不显示），昨天/前天/历史日期 → 友好文本
    private var relativeDateText: String? {
        guard let raw = data.date?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let parsed = NLDateParser.parse(raw) else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(parsed) { return nil }
        if calendar.isDateInYesterday(parsed) { return String(localized: "昨天") }
        if let dayBefore = calendar.date(byAdding: .day, value: -2, to: Date()),
           calendar.isDate(parsed, inSameDayAs: dayBefore) { return String(localized: "前天") }
        return Self.dateFormatter.string(from: parsed)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()
}
