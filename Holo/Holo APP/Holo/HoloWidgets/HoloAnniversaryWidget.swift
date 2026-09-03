//
//  HoloAnniversaryWidget.swift
//  HoloWidgets
//
//  纪念日倒数 · 主题色渐变倒数卡 + 时光轴 + 锁屏配件（当天自动变脸庆祝）
//

import SwiftUI
import WidgetKit

struct HoloAnniversaryWidget: Widget {
    let kind = HoloWidgetKind.anniversary.rawValue

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HoloAnniversaryProvider()) { entry in
            HoloAnniversaryWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "纪念日倒数"))
        .description(String(localized: "重要的日子，提前看见它走来；到了当天，替你先说一声恭喜。"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular])
    }
}

private struct HoloAnniversaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> HoloWidgetEntry<HoloWidgetAnniversarySnapshot> {
        HoloWidgetEntry(date: Date(), value: .sample(), entitlement: .plusPreview())
    }

    func getSnapshot(in context: Context, completion: @escaping (HoloWidgetEntry<HoloWidgetAnniversarySnapshot>) -> Void) {
        completion(HoloWidgetEntry(
            date: Date(),
            value: .sample(),
            entitlement: widgetEntitlement(for: context)
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HoloWidgetEntry<HoloWidgetAnniversarySnapshot>>) -> Void) {
        let store = HoloWidgetSnapshotStore()
        let entitlement = store.readEntitlement() ?? .free()
        let snapshot = entitlement.isPlusActive ? (store.readAnniversary() ?? .sample()) : .sample()
        let entry = HoloWidgetEntry(date: Date(), value: snapshot, entitlement: entitlement)

        // 6 小时常规刷新；若有数据，叠加「跨天时刻」刷新点，保证天数翻转与当天变脸准时
        var refreshAt = Date().addingTimeInterval(60 * 60 * 6)
        if !snapshot.items.isEmpty {
            let calendar = Calendar.current
            if let nextMidnight = calendar.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 2), matchingPolicy: .nextTime) {
                refreshAt = min(refreshAt, nextMidnight)
            }
        }
        completion(Timeline(entries: [entry], policy: .after(refreshAt)))
    }
}

private struct HoloAnniversaryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: HoloWidgetEntry<HoloWidgetAnniversarySnapshot>

    private var items: [HoloWidgetAnniversaryItem] { entry.value.items }

    var body: some View {
        Group {
            if entry.entitlement.isPlusActive {
                switch family {
                case .accessoryCircular:
                    accessoryCircular
                        .containerBackground(for: .widget) { Color.clear }
                case .accessoryRectangular:
                    accessoryRectangular
                        .containerBackground(for: .widget) { Color.clear }
                default:
                    desktopContent
                }
            } else {
                HoloLockedWidgetView()
                    .holoWidgetBackground(colorScheme: colorScheme)
            }
        }
    }

    /// 桌面三尺寸：S 用主题色渐变整卡，M/L 用品牌壳（日光暖沙/暮色发光）
    @ViewBuilder
    private var desktopContent: some View {
        if family == .systemSmall {
            Link(destination: URL(string: "holo://anniversaries")!) {
                if items.isEmpty { emptyState } else { smallCard }
            }
            .containerBackground(for: .widget) { smallGradient }
        } else {
            Link(destination: URL(string: "holo://anniversaries")!) {
                if items.isEmpty {
                    emptyState
                } else if family == .systemLarge {
                    largeCard
                } else {
                    mediumCard
                }
            }
            .holoWidgetBackground(colorScheme: colorScheme)
        }
    }

    /// 小组件渐变底：主题色 → 加深；当天换庆祝金橙
    private var smallGradient: LinearGradient {
        if let first = items.first, first.isToday {
            return LinearGradient(
                colors: [Color(red: 0.98, green: 0.57, blue: 0.24), Color(red: 0.80, green: 0.26, blue: 0.05)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        let tint = themeColor(items.first)
        return LinearGradient(
            colors: [tint, tint.darkerInWidget(by: 0.42)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func themeColor(_ item: HoloWidgetAnniversaryItem?) -> Color {
        guard let hex = item?.themeColorHex else { return HoloWidgetBrand.primary(for: colorScheme) }
        return HoloWidgetBrand.color(fromHex: hex, colorScheme: colorScheme)
    }

    // MARK: - Small · 主题色倒数卡（当天变脸）

    private var smallCard: some View {
        let main = items[0]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                HoloWidgetIconText.icon(main.icon, size: 12)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.22)))
                Spacer()
                if main.isToday {
                    Text(String(localized: "🎉"))
                        .font(.system(size: 12))
                }
            }

            Spacer(minLength: 0)

            if main.isToday {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "就是今天"))
                        .font(.system(size: 19, weight: .heavy))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.6)
                    Text(main.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.88))
                        .lineLimit(1)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(main.displayDays)")
                        .font(.system(size: 46, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.55)
                    Text(String(localized: "天"))
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundColor(.white.opacity(0.9))
                }
            }

            Spacer(minLength: 0)

            HStack {
                Text(main.title)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                Text(main.isToday ? main.dayText : main.dateText)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .padding(13)
        .foregroundStyle(.white)
    }

    // MARK: - Medium · 主事件 + 预告

    private var mediumCard: some View {
        let main = items[0]
        return HStack(spacing: 14) {
            // 左：主事件
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(themeColor(main).opacity(0.16))
                        .frame(width: 26, height: 26)
                        .overlay(HoloWidgetIconText.icon(main.icon, size: 13))
                    Text(String(localized: "下一个"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(textSecondary)
                }

                Text(main.title + (main.subtitleText.map { " · \($0)" } ?? ""))
                    .font(.system(size: 12.5, weight: .heavy))
                    .foregroundStyle(textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 7)

                if main.isToday {
                    Text(String(localized: "🎉 就是今天"))
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(themeColor(main))
                        .padding(.top, 2)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(main.displayDays)")
                            .font(.system(size: 40, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(themeColor(main))
                            .minimumScaleFactor(0.6)
                        Text(String(localized: "天后"))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(textSecondary)
                    }
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)

                Text(main.dateText)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(hairlineTint)
                .frame(width: 0.8)

            // 右：接下来
            VStack(spacing: 0) {
                ForEach(items.dropFirst().prefix(2).indices, id: \.self) { index in
                    let next = items.dropFirst().prefix(2)[index]
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(themeColor(next).opacity(0.14))
                            .frame(width: 28, height: 28)
                            .overlay(HoloWidgetIconText.icon(next.icon, size: 13))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(next.title)
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(textPrimary)
                                .lineLimit(1)
                            Text(next.isToday ? String(localized: "就是今天 🎉") : next.dateText)
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(textSecondary)
                        }
                        Spacer(minLength: 2)
                        Text(next.isToday ? "🎉" : "\(next.displayDays)")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(themeColor(next))
                    }
                    if index == 0 { Spacer(minLength: 0) }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(14)
    }

    // MARK: - Large · 日期块时光轴

    private var largeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(HoloWidgetBrand.primary(for: colorScheme).opacity(0.15))
                        .frame(width: 24, height: 24)
                        .overlay(HoloWidgetIconText.icon("🗓️", size: 12))
                    Text(String(localized: "纪念日"))
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(textPrimary)
                }
                Spacer()
                Text(String(localized: "\(items.count) 个近期日子"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(textSecondary)
            }

            VStack(spacing: 9) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    timelineRow(item, highlighted: index == 0)
                }
            }
            .padding(.top, 12)

            Spacer(minLength: 0)

            HStack {
                Text(String(localized: "日子不多的月份，就翻翻过去的自己 ✦"))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(textSecondary)
                Spacer()
            }
            .padding(.top, 8)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(hairlineTint)
                    .frame(height: 0.8)
            }
        }
        .padding(16)
    }

    private func timelineRow(_ item: HoloWidgetAnniversaryItem, highlighted: Bool) -> some View {
        let tint = themeColor(item)
        return HStack(spacing: 11) {
            // 日期块
            VStack(spacing: 1) {
                Text(item.monthText)
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(highlighted ? Color.white.opacity(0.9) : textSecondary)
                Text(item.dayText)
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(highlighted ? Color.white : textPrimary)
            }
            .frame(width: 42, height: 42)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(highlighted ? AnyShapeStyle(tint) : AnyShapeStyle(cardTint)))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(highlighted ? Color.clear : hairlineTint, lineWidth: 0.8))

            HoloWidgetIconText.icon(item.icon, size: 15)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(textPrimary)
                    .lineLimit(1)
                if let subtitle = item.subtitleText {
                    Text(subtitle)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(textSecondary)
                }
            }

            Spacer(minLength: 4)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if item.isToday {
                    Text(String(localized: "就是今天 🎉"))
                        .font(.system(size: 10.5, weight: .heavy))
                        .foregroundStyle(tint)
                } else {
                    Text("\(item.displayDays)")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(highlighted ? tint : textPrimary)
                    Text(item.days > 0 ? String(localized: "天") : String(localized: "天·累计"))
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(textSecondary)
                }
            }
        }
    }

    // MARK: - 锁屏圆形配件

    private var accessoryCircular: some View {
        let main = items.first
        return ZStack {
            if let main, let progress = main.cycleProgress, !main.isToday {
                Circle()
                    .trim(from: 0, to: max(progress, 0.03))
                    .stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(3)
            }
            if let main {
                VStack(spacing: 0) {
                    if main.isToday {
                        Text("🎉")
                            .font(.system(size: 17))
                        Text(String(localized: "今天"))
                            .font(.system(size: 8.5, weight: .heavy))
                            .foregroundColor(.white.opacity(0.85))
                    } else {
                        Text("\(main.displayDays)")
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.white)
                            .minimumScaleFactor(0.5)
                        Text(main.days > 0 ? String(localized: "天后") : String(localized: "天"))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white.opacity(0.75))
                    }
                }
            } else {
                Image(systemName: "calendar.badge.heart")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetAccentable()
    }

    // MARK: - 锁屏矩形配件

    private var accessoryRectangular: some View {
        Group {
            if let main = items.first {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        HoloWidgetIconText.icon(main.icon, size: 11)
                        Text(main.title)
                            .font(.system(size: 12, weight: .heavy))
                            .lineLimit(1)
                    }
                    Text(main.isToday
                         ? String(localized: "就是今天 🎉 去送上祝福")
                         : String(localized: "还有 \(main.displayDays) 天 · \(main.dateText)"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(String(localized: "还没有纪念日"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .widgetAccentable()
    }

    // MARK: 空态

    private var emptyState: some View {
        VStack(spacing: 8) {
            HoloWidgetIconText.icon("🎂", size: 26)
            Text(String(localized: "还没有纪念日"))
                .font(.system(size: family == .systemSmall ? 12 : 14, weight: .bold))
                .foregroundStyle(family == .systemSmall ? Color.white : textPrimary)
            if family != .systemSmall {
                Text(String(localized: "去点亮一个重要的日子"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
    }

    private var cardTint: Color { HoloWidgetBrand.card(for: colorScheme) }
    private var hairlineTint: Color { HoloWidgetBrand.hairline(for: colorScheme) }
    private var textPrimary: Color { HoloWidgetBrand.textPrimary(for: colorScheme) }
    private var textSecondary: Color { HoloWidgetBrand.textSecondary(for: colorScheme) }
}

// MARK: - Widget 侧 Color 加深（S 卡渐变深色端）

private extension Color {
    func darkerInWidget(by ratio: Double) -> Color {
        let uiColor = UIColor(self)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        uiColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: min(saturation * 1.15, 1), brightness: max(brightness * (1 - ratio), 0.12), opacity: alpha)
    }
}
