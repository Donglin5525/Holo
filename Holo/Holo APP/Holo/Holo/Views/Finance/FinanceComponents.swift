//
//  FinanceComponents.swift
//  Holo
//
//  财务模块共用组件
//

import SwiftUI

struct HoloRectCorner: OptionSet {
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

// MARK: - Notification Name

extension Notification.Name {
    /// 财务数据发生变化时发送此通知，账本列表监听后刷新
    static let financeDataDidChange = Notification.Name("financeDataDidChange")
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
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }
            
            Spacer(minLength: 16)
            
            // 金额，留白呼吸
            Text(NumberFormatter.compactCurrency(amount))
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 136)
        .padding(HoloSpacing.lg) // 负空间：更大内边距
        .background {
            ZStack {
                // 毛玻璃：半透明模糊层增加深度
                Rectangle()
                    .fill(.ultraThinMaterial)
                // 微观渐变：浅色系薄层叠在毛玻璃上，不盖住模糊
                LinearGradient(
                    colors: [gradientStart, gradientEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(0.6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.xl)
                .stroke(strokeColor, lineWidth: 0.5) // 0.5px 半透明描边，去厚重边框
        )
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
                .foregroundColor(.holoTextSecondary)
                .padding(.horizontal, HoloSpacing.md)
                .background(Color.holoBackground)
            
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

    var body: some View {
        Button(action: onTap) {
            // 列表行风格：左侧分类信息，右侧金额严格对齐
            HStack(alignment: .center, spacing: HoloSpacing.md) {
                // 分类图标
                categoryIcon

                VStack(alignment: .leading, spacing: 4) {
                    // 主标题
                    Text(hasNote ? transaction.note! : transaction.category.name)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)

                    // 副标题：有备注显示备注，无备注不显示副标题
                    if hasRemark {
                        Text(transaction.remark!)
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                            .lineLimit(1)
                    }

                    // 非默认账户时显示账户名
                    if !transaction.account.isDefault {
                        Text(transaction.account.name)
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextSecondary.opacity(0.7))
                            .lineLimit(1)
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
            .padding(.leading, 11)
            .padding(.trailing, HoloSpacing.md)
            .padding(.vertical, 10)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    /// 分类图标
    private var categoryIcon: some View {
        ZStack {
            Circle()
                .fill(transaction.category.swiftUIColor.opacity(0.08))
                .frame(width: 48, height: 48)

            transactionCategoryIcon(transaction.category, size: 24)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Empty State View

/// 空状态视图
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "wallet.pass")
                .font(.system(size: 64, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.3))
            
            Text("暂无交易记录")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
            
            Text("点击 + 按钮记录第一笔交易")
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
