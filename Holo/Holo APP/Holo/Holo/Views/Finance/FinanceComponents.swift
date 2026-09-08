//
//  FinanceComponents.swift
//  Holo
//
//  财务模块共用组件
//

import SwiftUI
import CoreData

// MARK: - Notification Name

extension Notification.Name {
    /// 财务数据发生变化时发送此通知，账本列表监听后刷新
    static let financeDataDidChange = Notification.Name("financeDataDidChange")
}

// MARK: - Transaction Row View

/// 交易行视图
struct TransactionRowView: View {
    let transaction: Transaction
    var isCompact: Bool = false
    var showsDate: Bool = false
    let onTap: () -> Void

    /// 是否有用户填写的名称
    private var hasNote: Bool {
        if let note = transaction.note, !note.isEmpty {
            return true
        }
        return false
    }

    /// 是否有备注
    private var hasRemark: Bool {
        if let remark = transaction.remark, !remark.isEmpty {
            return true
        }
        return false
    }

    private var compactMetadataText: String? {
        var parts: [String] = []

        if showsDate {
            parts.append(formatDateTime(transaction.date))
        }
        if hasRemark, let remark = transaction.remark {
            parts.append(remark)
        }
        if let account = transaction.account, !account.isDefault {
            parts.append(account.name)
        }

        let text = parts.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    /// 搜索等跨账户场景的元信息行：时间 · 账户 · 备注。
    /// 账户不受「默认账户省略」规则限制——搜索结果跨账户，账户是关键上下文。
    private var searchMetadataText: String {
        var parts = [formatDateTime(transaction.date)]
        if let account = transaction.account {
            parts.append(account.name)
        }
        if hasRemark, let remark = transaction.remark {
            parts.append(remark)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onTap) {
            // 列表行风格：左侧分类信息，右侧金额严格对齐
            HStack(alignment: .center, spacing: isCompact ? 10 : HoloSpacing.md) {
                // 分类图标
                categoryIcon

                VStack(alignment: .leading, spacing: isCompact ? 2 : 4) {
                    // 主标题 + 分期标签
                    HStack(spacing: 4) {
                        Text(hasNote ? (transaction.note ?? "") : (transaction.category?.name ?? String(localized: "未分类")))
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                            .lineLimit(1)
                            .layoutPriority(1)

                        // 分期期数胶囊，如 "3/12期"
                        if let label = transaction.installmentLabel {
                            CardBadge(text: label, color: .holoPrimary)
                                .fixedSize()
                        }
                    }

                    if isCompact {
                        if let compactMetadataText {
                            Text(compactMetadataText)
                                .font(.system(size: 11))
                                .foregroundColor(.holoTextSecondary)
                                .lineLimit(1)
                        }
                    } else if showsDate {
                        Text(searchMetadataText)
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                            .lineLimit(1)
                    } else {
                        // 副标题：有备注显示备注，无备注不显示副标题
                        if hasRemark, let remark = transaction.remark {
                            Text(remark)
                                .font(.system(size: 12))
                                .foregroundColor(.holoTextSecondary)
                                .lineLimit(1)
                        }

                        // 挂靠的财务项目（如东京旅行）
                        if let tag = FinanceProjectTagCache.lookup(transaction.financeProjectId) {
                            Text("\(tag.icon) \(tag.name)")
                                .font(.system(size: 11))
                                .foregroundColor(.holoTextSecondary.opacity(0.7))
                                .lineLimit(1)
                        }

                        // 非默认账户时显示账户名
                        if let account = transaction.account, !account.isDefault {
                            Text(account.name)
                                .font(.system(size: 11))
                                .foregroundColor(.holoTextSecondary.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 0)

                // 金额：右侧对齐，空间不足时自动缩放
                Text(transaction.formattedAmount)
                    .font(.holoBody)
                    .foregroundColor(transaction.transactionType == .expense ? .holoTextPrimary : .holoSuccess)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .frame(alignment: .trailing)
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, isCompact ? 6 : 11)
            .padding(.trailing, isCompact ? HoloSpacing.sm : HoloSpacing.md)
            .padding(.vertical, isCompact ? HoloSpacing.xs : 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    /// 分类图标
    private var categoryIcon: some View {
        let cat = transaction.category
        let color: Color = (cat?.isDeleted ?? false) ? .holoPrimary : (cat?.swiftUIColor ?? .holoPrimary)
        let iconName = cat?.icon ?? "questionmark.folder.fill"
        return CategoryIconBadge(iconName: iconName, color: color, diameter: isCompact ? 40 : 48)
    }

    private func formatDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        // 同年省略年份，跨年带年份，避免跨年列表（如搜索结果）产生年份歧义
        if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
            f.setLocalizedDateFormatFromTemplate("MMMdHHmm")
        } else {
            f.setLocalizedDateFormatFromTemplate("yMMMdHHmm")
        }
        return f.string(from: date)
    }
}

// MARK: - Empty State View

/// 空状态视图
/// isFirstRecord=true：本月还没有任何收支（真·第一笔）；
/// false：只是选中那天没记录，不该再说「第一笔」。
struct EmptyStateView: View {
    var isFirstRecord: Bool = true

    var body: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "wallet.pass")
                .font(.system(size: 64, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.3))

            Text(isFirstRecord ? String(localized: "暂无交易记录") : String(localized: "这一天还没有记录"))
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)

            Text(isFirstRecord ? String(localized: "点击 + 按钮记录第一笔交易") : String(localized: "点击 + 按钮记一笔"))
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Preview

#Preview {
    FinanceView()
}
