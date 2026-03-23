//
//  DayCellView.swift
//  Holo
//
//  单日格子 — 周视图 / 月历网格 / 弹窗月历 复用
//

import SwiftUI

// MARK: - 样式枚举

/// 格子样式：周视图紧凑 vs 月历宽松
enum DayCellStyle {
    case week
    case calendar
}

// MARK: - DayCellView

/// 日期格子视图
/// - Parameters:
///   - date: 日期
///   - summary: 当日汇总（nil = 无数据）
///   - isSelected: 是否选中
///   - isCurrentMonth: 是否属于当前显示月
///   - style: 显示样式
///   - onTap: 点击回调
///   - onLongPress: 长按回调（用于快速记账，nil = 不支持长按）
struct DayCellView: View {
    let date: Date
    let summary: DailySummary?
    let isSelected: Bool
    let isCurrentMonth: Bool
    let style: DayCellStyle
    let onTap: () -> Void
    var onLongPress: (() -> Void)? = nil
    
    /// 长按缩放反馈
    @State private var isLongPressing: Bool = false
    
    private var dayString: String {
        "\(Calendar.current.component(.day, from: date))"
    }
    
    var body: some View {
        cellContent
            .frame(maxWidth: .infinity)
            .frame(height: style == .week ? 56 : 40)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.holoPrimary.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(date.isToday && !isSelected ? Color.holoPrimary.opacity(0.4) : Color.clear, lineWidth: 1.5)
            )
            .scaleEffect(isLongPressing ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isLongPressing)
            .onTapGesture { onTap() }
            .onLongPressGesture(
                minimumDuration: 0.5,
                pressing: { pressing in isLongPressing = pressing },
                perform: {
                    HapticManager.medium()
                    onLongPress?()
                }
            )
    }
    
    /// 格子内容（日期数字 + 指示点/金额）
    private var cellContent: some View {
        VStack(spacing: style == .week ? 4 : 2) {
            Text(dayString)
                .font(.system(size: style == .week ? 15 : 14, weight: isSelected ? .bold : .regular))
                .foregroundColor(textColor)
            
            if let s = summary, s.hasTransactions {
                if style == .week {
                    Text(CalendarDateFormatter.compactAmount(s.totalExpense))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.holoError.opacity(0.8))
                        .lineLimit(1)
                } else {
                    Circle()
                        .fill(Color.holoPrimary)
                        .frame(width: 4, height: 4)
                }
            } else {
                if style == .week {
                    Text(" ")
                        .font(.system(size: 10))
                } else {
                    Color.clear.frame(width: 4, height: 4)
                }
            }
        }
    }
    
    private var textColor: Color {
        if !isCurrentMonth { return .holoTextSecondary.opacity(0.3) }
        if isSelected { return .holoPrimary }
        if date.isToday { return .holoPrimary }
        if date.isWeekend { return .holoTextSecondary.opacity(0.6) }
        return .holoTextPrimary
    }
}
