//
//  AnniversaryCardView.swift
//  Holo
//
//  纪念日列表卡片（作为 List 行，自带卡片样式）
//

import SwiftUI

struct AnniversaryCardView: View {

    let anniversary: Anniversary
    let onTap: () -> Void

    @State private var dotPulse = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: HoloSpacing.md) {
                // 左侧：图标
                CategoryIconBadge(
                    iconName: anniversary.icon,
                    color: themeColor,
                    diameter: 48
                )

                // 中间：名称 + 日期信息块
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        if anniversary.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(themeColor)
                        }
                        Text(anniversary.title)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }

                    Text(infoLine)
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                // 右侧：天数 + 正倒数标识
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(anniversary.displayDays)")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(themeColor)
                        Text("天")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                    Text(directionLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isCountdown ? themeColor : .holoTextSecondary)
                        .opacity(isCountdown && anniversary.isApproaching ? (dotPulse ? 1.0 : 0.4) : 1.0)
                }
                .frame(alignment: .trailing)
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, 11)
            .padding(.trailing, HoloSpacing.md)
            .padding(.vertical, 10)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                    .stroke(themeColor.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onAppear {
            if isCountdown && anniversary.isApproaching {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    dotPulse = true
                }
            }
        }
    }

    // MARK: - 计算

    private var themeColor: Color {
        Color(hex: anniversary.color)
    }

    private var isCountdown: Bool {
        anniversary.displayMode.isCountdown
    }

    private var directionLabel: String {
        let mode = anniversary.displayMode
        switch mode {
        case .countdown(let days):
            return days == 0 ? "就是今天" : "还有"
        case .elapsed:
            return "已过"
        }
    }

    private var infoLine: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        let baseDate = anniversary.repeatYearly ? anniversary.nextOccurrenceDate() : anniversary.date
        formatter.dateFormat = "yyyy年M月d日"

        var parts: [String] = [formatter.string(from: baseDate)]
        if anniversary.repeatYearly { parts.append("每年") }
        if anniversary.reminderEnabled {
            if let preset = AnniversaryReminderPreset(rawValue: anniversary.reminderDaysBefore) {
                parts.append(preset == .sameDay ? "当天提醒" : "\(preset.displayName)提醒")
            } else {
                parts.append("提前\(anniversary.reminderDaysBefore)天提醒")
            }
        }
        return parts.joined(separator: " · ")
    }
}
