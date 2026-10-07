//
//  FinanceComponents.swift
//  Holo
//
//  财务模块共用组件
//

import SwiftUI
import CoreData

nonisolated struct HoloRectCorner: OptionSet {
    let rawValue: Int

    static let topLeft = HoloRectCorner(rawValue: 1 << 0)
    static let topRight = HoloRectCorner(rawValue: 1 << 1)
    static let bottomLeft = HoloRectCorner(rawValue: 1 << 2)
    static let bottomRight = HoloRectCorner(rawValue: 1 << 3)
    static let allCorners: HoloRectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

/// 支持只圆化指定角的 Shape
struct RoundedCorner: Shape {
    var radius: CGFloat = 0
    var corners: HoloRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // 如果所有角都圆角化，直接用圆角矩形
        if corners == .allCorners {
            return Path(roundedRect: rect, cornerRadius: radius)
        }

        // 否则手动绘制路径
        let w = rect.width
        let h = rect.height
        let r = min(radius, min(w, h) / 2)

        // 起点：左上角
        path.move(to: CGPoint(x: rect.minX + (corners.contains(.topLeft) ? r : 0), y: rect.minY))

        // 顶边 + 右上角
        path.addLine(to: CGPoint(x: rect.maxX - (corners.contains(.topRight) ? r : 0), y: rect.minY))
        if corners.contains(.topRight) {
            path.addArc(
                center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
                radius: r,
                startAngle: .degrees(-90),
                endAngle: .degrees(0),
                clockwise: false
            )
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }

        // 右边 + 右下角
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - (corners.contains(.bottomRight) ? r : 0)))
        if corners.contains(.bottomRight) {
            path.addArc(
                center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
                radius: r,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }

        // 底边 + 左下角
        path.addLine(to: CGPoint(x: rect.minX + (corners.contains(.bottomLeft) ? r : 0), y: rect.maxY))
        if corners.contains(.bottomLeft) {
            path.addArc(
                center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
                radius: r,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }

        // 左边 + 左上角
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + (corners.contains(.topLeft) ? r : 0)))
        if corners.contains(.topLeft) {
            path.addArc(
                center: CGPoint(x: rect.minX + r, y: rect.minY + r),
                radius: r,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }

        path.closeSubpath()
        return path
    }
}

// MARK: - Finance Ledger View（集成周视图 + 月历 + 弹窗月历 + 按日筛选）

/// 账本列表视图（集成日历组件）
/// 修复：① 日历 icon 弹出底部抽屉  ② 展开月历时隐藏周视图
///       ③ 安全区避开灵动岛  ④ 单日期标题  ⑤ 返回按钮 + 手势

// MARK: - Summary Card

/// 收支概览卡片
/// 设计原则：去边框化、微观渐变、负空间平衡、毛玻璃
struct SummaryCard: View {
    let title: String
    let amount: Decimal
    let iconName: String
    let iconColor: Color
    let gradientStart: Color
    let gradientEnd: Color
    let strokeColor: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 图标 + 标题，留白充足
            HStack(spacing: HoloSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.08))
                        .frame(width: 36, height: 36)
                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(iconColor)
                }
                Text(title)
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
            }
            
            Spacer(minLength: 16)
            
            // 金额，留白呼吸（数字滚动：切月份/记账后金额平滑滚动到新值）
            Text(NumberFormatter.compactCurrency(amount))
                .holoText(.sectionTitle)
                .foregroundColor(.holoToolText)
                .contentTransition(.numericText())
                .animation(HoloAnimation.smooth, value: amount)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 136)
        .padding(HoloSpacing.lg) // 负空间：更大内边距
.holoSurface()
    }
}

// MARK: - Date Divider

/// 日期分隔线
struct DateDivider: View {
    let title: String
    
    var body: some View {
        HStack {
            VStack {
                Divider()
                    .background(Color.holoDivider)
            }
            
            Text(title)
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)
                .padding(.horizontal, HoloSpacing.md)
                .background(Color.holoToolBackground)
            
            VStack {
                Divider()
                    .background(Color.holoDivider)
            }
        }
        .padding(.vertical, HoloSpacing.md)
    }
}

// MARK: - Transaction Row View

/// 交易行视图
struct TransactionRowView: View {
    let transaction: Transaction
    var isCompact: Bool = false
    var showsDate: Bool = false
    /// iPad 双栏选中态（右栏详情联动左栏高亮）
    var isSelected: Bool = false
    let onTap: () -> Void

    /// 原交易的累计退款（「已退 ¥X」徽章；nil=无退款）。退款笔自身徽章走 isRefund 本地判断
    @State private var refundedTotal: Decimal?

    /// 标题下方的退款族徽章：退款笔「退款」/ 原交易「已退 ¥X」。
    /// 独立成行不与标题挤同一行（徽章带金额太长会把科目名挤成省略号）
    private var refundBadgeText: String? {
        if transaction.isRefund { return String(localized: "退款") }
        if let refundedTotal, refundedTotal > 0 {
            return String(localized: "已退 ¥\(refundedTotal.formattedAsCurrency())")
        }
        return nil
    }

    /// 支出原交易的退款累计查询（列表行懒加载内跑，索引查询；退款增删靠通知刷新）
    private func refreshRefundBadge() async {
        guard transaction.transactionType == .expense, !transaction.isRefund else {
            refundedTotal = nil
            return
        }
        let refunds = (try? await FinanceRepository.shared.getRefunds(for: transaction)) ?? []
        let total = refunds.reduce(Decimal(0)) { $0 + $1.amountAsDecimal }
        refundedTotal = total > 0 ? total : nil
    }

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
                            .holoText(.body)
                            .foregroundColor(.holoToolText)
                            .lineLimit(1)
                            .layoutPriority(1)

                        // 分期期数胶囊，如 "3/12期"
                        if let label = transaction.installmentLabel {
                            CardBadge(text: label, color: .holoPrimary)
                                .fixedSize()
                        }
                    }

                    // 退款 mini 胶囊：标题下方独立一行，不挤占科目名
                    if let refundBadgeText {
                        Text(refundBadgeText)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(.holoSuccessDark)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Color.holoSuccessDark.opacity(0.12))
                            .clipShape(Capsule())
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    if isCompact {
                        if let compactMetadataText {
                            Text(compactMetadataText)
                                .font(.system(size: 11))
                                .foregroundColor(.holoToolTextSecondary)
                                .lineLimit(1)
                        }
                    } else if showsDate {
                        Text(searchMetadataText)
                            .font(.system(size: 12))
                            .foregroundColor(.holoToolTextSecondary)
                            .lineLimit(1)
                    } else {
                        // 副标题：有备注显示备注，无备注不显示副标题
                        if hasRemark, let remark = transaction.remark {
                            Text(remark)
                                .font(.system(size: 12))
                                .foregroundColor(.holoToolTextSecondary)
                                .lineLimit(1)
                        }

                        // 挂靠的财务项目（如东京旅行）
                        if let tag = FinanceProjectTagCache.lookup(transaction.financeProjectId) {
                            Text("\(tag.icon) \(tag.name)")
                                .font(.system(size: 11))
                                .foregroundColor(.holoToolTextSecondary.opacity(0.7))
                                .lineLimit(1)
                        }

                        // 非默认账户时显示账户名
                        if let account = transaction.account, !account.isDefault {
                            Text(account.name)
                                .font(.system(size: 11))
                                .foregroundColor(.holoToolTextSecondary.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 0)

                // 金额：右侧对齐，空间不足时自动缩放
                Text(transaction.formattedAmount)
                    .holoText(.body)
                    .foregroundColor(transaction.transactionType == .expense ? .holoToolText : .holoSuccess)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .frame(alignment: .trailing)
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, isCompact ? 6 : 11)
            .padding(.trailing, isCompact ? HoloSpacing.sm : HoloSpacing.md)
            .padding(.vertical, isCompact ? HoloSpacing.xs : 10)
            .background(
                // 双栏选中高亮：主色浅底，与右栏详情建立视觉对应
                isSelected
                    ? AnyShapeStyle(Color.holoPrimary.opacity(0.10))
                    : AnyShapeStyle(Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(HoloPressStyle())
        .holoRecordArrival(transaction.id, domain: .finance)
        .task(id: transaction.id) { await refreshRefundBadge() }
        .onReceive(NotificationCenter.default.publisher(for: .financeDataDidChange)) { _ in
            Task { await refreshRefundBadge() }
        }
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
/// isFirstRecord=true：全库还没有任何已发生交易（真·第一笔），显示激活引导副文案 + CTA；
/// false：只是选中那天没记录——老用户不需要被教怎么记账，只留一句陈述。
/// ctaTitle+ctaAction 同时提供且为首笔时显示行动按钮，空态从陈述句变成一键直达的起点（激活方案 §3.2）。
struct EmptyStateView: View {
    var isFirstRecord: Bool = true
    var ctaTitle: String? = nil
    var ctaAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "wallet.pass")
                .font(.system(size: 64, weight: .light))
                .foregroundColor(.holoToolTextSecondary.opacity(0.3))

            Text(isFirstRecord ? String(localized: "暂无交易记录") : String(localized: "这一天还没有记录"))
                .holoText(.body)
                .foregroundColor(.holoToolTextSecondary)

            if isFirstRecord {
                Text(String(localized: "说一句话或手动记一笔，都可以开始"))
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary.opacity(0.7))
                    .multilineTextAlignment(.center)

                if let ctaTitle, let ctaAction {
                    Button(action: ctaAction) {
                        Label(ctaTitle, systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 26)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.holoPrimary)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(HoloPressStyle())
                    .padding(.top, 4)
                    .accessibilityIdentifier("financeEmptyCta")
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    FinanceView()
}
