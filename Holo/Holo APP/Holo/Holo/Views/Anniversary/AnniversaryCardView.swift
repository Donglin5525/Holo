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
            return days == 0 ? String(localized: "就是今天") : String(localized: "还有")
        case .elapsed:
            return String(localized: "已过")
        }
    }

    private var infoLine: String {
        let formatter = DateFormatter()
        let baseDate = anniversary.repeatYearly ? anniversary.nextOccurrenceDate() : anniversary.date
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")

        var parts: [String] = [formatter.string(from: baseDate)]
        if anniversary.repeatYearly { parts.append(String(localized: "每年")) }
        if anniversary.reminderEnabled {
            if let preset = AnniversaryReminderPreset(rawValue: anniversary.reminderDaysBefore) {
                parts.append(preset == .sameDay ? String(localized: "当天提醒") : String(localized: "\(preset.displayName)提醒"))
            } else {
                parts.append(String(localized: "提前\(anniversary.reminderDaysBefore)天提醒"))
            }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Hero 主卡（列表页情感焦点）

/// 列表页首屏大卡：最近倒数的日子；到期当天自动变脸为庆祝样式
struct AnniversaryHeroCard: View {

    let anniversary: Anniversary
    let onTap: () -> Void

    private var tint: Color { Color(hex: anniversary.color) }

    var body: some View {
        Button(action: onTap) {
            Group {
                if anniversary.isToday {
                    todayContent
                } else {
                    countdownContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(heroBackground)
            .overlay(todayBadge)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var heroBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(
                    colors: [tint, tint.darker(by: 0.28), tint.darker(by: 0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            // 右上光斑
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(0.22), .clear], center: .center, startRadius: 2, endRadius: 130))
                .frame(width: 240, height: 240)
                .offset(x: 110, y: -110)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: tint.opacity(0.35), radius: 14, y: 7)
    }

    @ViewBuilder
    private var todayBadge: some View {
        if anniversary.isToday {
            Text(String(localized: "🎉 就是今天"))
                .font(.system(size: 10.5, weight: .heavy))
                .foregroundColor(Color(hex: "#C2410C"))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white))
                .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(14)
        }
    }

    // MARK: 倒数态

    private var countdownContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(red: 0.99, green: 0.90, blue: 0.54))
                    .frame(width: 6, height: 6)
                    .shadow(color: Color(red: 0.99, green: 0.90, blue: 0.54), radius: 4)
                Text(String(localized: "下一个重要的日子"))
                    .font(.system(size: 11, weight: .heavy))
                    .kerning(1.2)
                    .foregroundColor(.white.opacity(0.92))
            }

            HStack(spacing: 12) {
                Group {
                    if EmojiCatalog.isEmojiIcon(anniversary.icon) {
                        Text(anniversary.icon).font(.system(size: 24))
                    } else {
                        Image(systemName: anniversary.icon)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 46, height: 46)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.white.opacity(0.22)))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if anniversary.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        Text(anniversary.title)
                            .font(.system(size: 19, weight: .heavy))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    Text(heroSubtitle)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 13)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(anniversary.displayDays)")
                    .font(.system(size: 54, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                Text(String(localized: "天后"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white.opacity(0.92))
            }
            .padding(.top, 12)

            HStack {
                Text(heroDateText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))
                Spacer()
                if let progress = anniversary.yearlyCycleProgress {
                    Text(String(localized: "本轮周期 \(Int((progress * 100).rounded()))%"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                }
            }
            .padding(.top, 12)

            if let progress = anniversary.yearlyCycleProgress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22))
                        Capsule()
                            .fill(LinearGradient(colors: [Color(red: 0.99, green: 0.90, blue: 0.54), Color.white.opacity(0.9)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 5)
                .padding(.top, 11)
            }
        }
    }

    // MARK: 当天庆祝态

    private var todayContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(celebrationKicker)
                    .font(.system(size: 11, weight: .heavy))
                    .kerning(1.2)
                    .foregroundColor(.white.opacity(0.95))
                Spacer()
            }

            HStack(spacing: 12) {
                Group {
                    if EmojiCatalog.isEmojiIcon(anniversary.icon) {
                        Text(anniversary.icon).font(.system(size: 26))
                    } else {
                        Image(systemName: anniversary.icon)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 46, height: 46)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.white.opacity(0.22)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(anniversary.title)
                        .font(.system(size: 19, weight: .heavy))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(todaySubtitle)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 14)

            Text(String(localized: "就是今天 🎉"))
                .font(.system(size: 36, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .padding(.top, 12)

            HStack {
                Text(heroDateText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))
                Spacer()
                Text(String(localized: "送上祝福 ›"))
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(Color(hex: "#C2410C"))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white))
            }
            .padding(.top, 12)
        }
    }

    private var celebrationKicker: String {
        switch anniversary.anniversaryType {
        case .birthday: return String(localized: "🎂 今天到了 · 生日快乐")
        case .anniversary: return String(localized: "❤️ 今天到了 · 周年快乐")
        default: return String(localized: "✨ 今天到了")
        }
    }

    private var todaySubtitle: String {
        if anniversary.repeatYearly {
            let n = anniversary.anniversaryNumber
            return n > 0 ? String(localized: "第 \(n + 1) 个周年") : String(localized: "每年循环")
        }
        return String(localized: "等到了这一天")
    }

    private var heroSubtitle: String {
        var parts: [String] = []
        if anniversary.repeatYearly {
            let n = anniversary.anniversaryNumber + 1
            parts.append(String(localized: "第 \(n) 个周年"))
        }
        switch anniversary.anniversaryType {
        case .countdown: parts.append(String(localized: "倒数日"))
        case .milestone: parts.append(String(localized: "里程碑"))
        default: break
        }
        return parts.joined(separator: " · ")
    }

    private var heroDateText: String {
        let formatter = DateFormatter()
        let baseDate = anniversary.repeatYearly ? anniversary.nextOccurrenceDate() : anniversary.date
        formatter.setLocalizedDateFormatFromTemplate("M月d日EEEE")
        return formatter.string(from: baseDate)
    }
}

// MARK: - Color 加深工具（Hero 卡渐变）

extension Color {
    /// 按比例加深（0...1），用于主题色渐变的深色端
    func darker(by ratio: Double) -> Color {
        let uiColor = UIColor(self)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        uiColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: min(saturation * 1.12, 1), brightness: max(brightness * (1 - ratio), 0.1), opacity: alpha)
    }
}
