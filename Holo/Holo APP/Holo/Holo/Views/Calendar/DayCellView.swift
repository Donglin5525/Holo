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
struct DayCellView: View {
    let date: Date
    let summary: DailySummary?
    let isSelected: Bool
    let isCurrentMonth: Bool
    let style: DayCellStyle
    let onTap: () -> Void
    
    private var dayString: String {
        "\(Calendar.current.component(.day, from: date))"
    }
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: style == .week ? 4 : 2) {
                // 日期数字
                Text(dayString)
                    .font(.system(size: style == .week ? 15 : 14, weight: isSelected ? .bold : .regular))
                    .foregroundColor(textColor)
                
                // 交易指示点 / 金额
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
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var textColor: Color {
        if !isCurrentMonth { return .holoTextSecondary.opacity(0.3) }
        if isSelected { return .holoPrimary }
        if date.isToday { return .holoPrimary }
        if date.isWeekend { return .holoTextSecondary.opacity(0.6) }
        return .holoTextPrimary
    }
}
