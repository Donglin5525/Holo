//
//  MonthCell.swift
//  Holo
//
//  月历单格：色深背景（活跃度）+ 底部模块色条（当天涉及模块）+ 日期号 + 今天/选中态
//

import SwiftUI

struct MonthCell: View {
    let day: Date
    let events: [CalendarEvent]
    let isThisMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                Text("\(Calendar.current.component(.day, from: day))")
                    .font(.system(size: 14, weight: dayWeight, design: .rounded))
                    .foregroundColor(dayNumberColor)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.top, 5)
                    .padding(.leading, 6)

                Spacer(minLength: 0)

                moduleBar
                    .opacity(events.isEmpty ? 0 : 1)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .aspectRatio(1, contentMode: .fit)
            .background(backgroundColor)
            .overlay(borderOverlay)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
        }
        .buttonStyle(.plain)
        .disabled(!isThisMonth)
        .opacity(isThisMonth ? 1 : 0.35)
    }

    // MARK: - 衍生

    private var backgroundColor: Color {
        isThisMonth ? CalendarHeatmap.color(forCount: events.count) : Color(hex: "#F5F2ED")
    }

    private var dayWeight: Font.Weight {
        (isToday || isSelected) ? .bold : .semibold
    }

    private var dayNumberColor: Color {
        if !isThisMonth { return .holoTextPlaceholder }
        if isToday { return .holoPrimary }
        return .holoTextPrimary
    }

    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: HoloRadius.sm)
            .stroke(
                isSelected ? Color.holoTextPrimary :
                (isToday ? Color.holoPrimary : Color.clear),
                lineWidth: isSelected ? 2.5 : (isToday ? 1.5 : 0)
            )
    }

    /// 底部模块色条：当天涉及的模块各占一段（去重 + 按 rawValue 稳定排序）
    private var moduleBar: some View {
        let modules = Array(Set(events.map { $0.module }))
            .sorted { $0.rawValue < $1.rawValue }
        return HStack(spacing: 0) {
            ForEach(modules, id: \.self) { module in
                Rectangle().fill(module.color)
            }
        }
        .frame(height: 4)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}
