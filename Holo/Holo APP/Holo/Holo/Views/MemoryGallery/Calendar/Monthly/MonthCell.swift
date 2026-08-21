//
//  MonthCell.swift
//  Holo
//
//  月历单格（P2：支持 heatmap 热力色深 / badge 数字徽章 两种形式）
//

import SwiftUI

struct MonthCell: View {
    @Environment(\.colorScheme) private var colorScheme

    let day: Date
    let events: [CalendarEvent]
    let isThisMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let cellStyle: MonthCellStyle        // P2
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            switch cellStyle {
            case .heatmap: heatmapBody
            case .badge:   badgeBody
            }
        }
        .buttonStyle(.plain)
        .disabled(!isThisMonth || isFuture)
        .opacity(isThisMonth ? (isFuture ? 0.42 : 1) : 0.35)
        .accessibilityHint(isFuture ? "未来日期还没有可回看的记忆" : "")
    }

    // MARK: - 热力色深（默认）

    private var heatmapBody: some View {
        VStack(spacing: 0) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.system(size: 14, weight: dayWeight, design: .serif))
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
        .shadow(color: isSelected ? Color.holoPrimary.opacity(0.13) : Color.clear, radius: 7, x: 0, y: 2)
    }

    // MARK: - 数字徽章（P2）

    private var badgeBody: some View {
        VStack(spacing: 2) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.system(size: 12, weight: dayWeight, design: .rounded))
                .foregroundColor(dayNumberColor)
            if events.isEmpty {
                Spacer(minLength: 0)
            } else {
                Text("\(events.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(badgeColor)
                    .clipShape(Circle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            isThisMonth
                ? Color.holoCardBackground
                : CalendarHeatmap.color(forLevel: 0, colorScheme: colorScheme)
        )
        .overlay(borderOverlay)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
    }

    // MARK: - 共享衍生

    private var backgroundColor: Color {
        guard isThisMonth else { return Color.holoNestedCardBackground.opacity(0.45) }
        guard !events.isEmpty else { return Color.holoCardBackground.opacity(0.72) }
        return CalendarHeatmap.color(forCount: events.count, colorScheme: colorScheme)
    }

    /// 徽章色 = 活跃度色深（与热力同色阶，徽章形式仍能看出活跃度）
    private var badgeColor: Color {
        CalendarHeatmap.color(forCount: events.count, colorScheme: colorScheme)
    }

    private var dayWeight: Font.Weight {
        (isToday || isSelected) ? .bold : .semibold
    }

    private var dayNumberColor: Color {
        if !isThisMonth { return .holoTextPlaceholder }
        if isFuture { return .holoTextPlaceholder }
        if isToday { return .holoPrimary }
        return .holoTextPrimary
    }

    private var isFuture: Bool {
        Calendar.current.startOfDay(for: day) > Calendar.current.startOfDay(for: Date())
    }

    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: HoloRadius.sm)
            .stroke(
                isSelected ? Color.holoPrimary :
                (isToday ? Color.holoPrimary.opacity(0.65) : Color.clear),
                lineWidth: isSelected ? 1.5 : (isToday ? 1 : 0)
            )
    }

    /// 底部模块色条：当天涉及的模块各占一段（去重 + 按 rawValue 稳定排序）
    private var moduleBar: some View {
        let modules = Array(Set(events.map { $0.module }))
            .sorted { $0.rawValue < $1.rawValue }
        return HStack(spacing: 0) {
            ForEach(modules, id: \.self) { module in
                Rectangle().fill(module.color.opacity(0.78))
            }
        }
        .frame(height: 2)
        .clipShape(Capsule())
    }
}
