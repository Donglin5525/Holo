//
//  HoloAnniversaryWidget.swift
//  HoloWidgets
//
//  纪念日倒数 · 招牌视觉「倒数数字 + 时光轴」
//

import SwiftUI
import WidgetKit

struct HoloAnniversaryWidget: Widget {
    let kind = HoloWidgetKind.anniversary.rawValue

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HoloAnniversaryProvider()) { entry in
            HoloAnniversaryWidgetView(entry: entry)
        }
        .configurationDisplayName("纪念日倒数")
        .description("重要的日子，提前看见它走来。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
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
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 60 * 6))))
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
                Link(destination: URL(string: "holo://anniversaries")!) {
                    if items.isEmpty {
                        emptyState
                    } else if family == .systemSmall {
                        anniversarySmall(items[0])
                    } else if family == .systemLarge {
                        anniversaryLarge
                    } else {
                        anniversaryMedium(items[0])
                    }
                }
            } else {
                HoloLockedWidgetView()
            }
        }
        .holoWidgetBackground(colorScheme: colorScheme)
    }

    // MARK: Small · 大倒数数字

    private func anniversarySmall(_ item: HoloWidgetAnniversaryItem) -> some View {
        VStack(spacing: 0) {
            HoloWidgetIconText.icon(item.icon, size: 17)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(cardTint))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(hairlineTint, lineWidth: 0.8)
                )

            VStack(spacing: 4) {
                Text(item.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                daysNumber(item, bigSize: 42)
            }
            .padding(.top, 8)

            Spacer(minLength: 0)

            Text(item.dateText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(textSecondary)
        }
        .padding(14)
    }

    // MARK: Medium · 主纪念日 + 下一个预告

    private func anniversaryMedium(_ item: HoloWidgetAnniversaryItem) -> some View {
        HStack(spacing: 15) {
            HoloWidgetIconText.icon(item.icon, size: 27)
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(cardTint))
                .overlay(
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .strokeBorder(hairlineTint, lineWidth: 0.8)
                )

            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(headlinePrefix(item))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(textSecondary)
                    Text("\(item.displayDays)")
                        .font(.system(size: 21, weight: .heavy))
                        .foregroundStyle(primaryTint)
                    Text("天")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(textSecondary)
                }
                .padding(.top, 5)

                Text(item.dateText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(textSecondary)
                    .padding(.top, 3)

                if let next = items.dropFirst().first {
                    HStack(spacing: 5) {
                        Text("接下来")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(textSecondary.opacity(0.8))
                        HoloWidgetIconText.icon(next.icon, size: 9)
                        Text("\(next.title) \(headlineCompact(next))")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.top, 6)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
    }

    // MARK: Large · 时光轴

    private var anniversaryLarge: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("接下来的日子")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(textPrimary)
                Spacer()
                Text("\(items.count) 个近期日子")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(textSecondary)
            }

            HStack(spacing: 13) {
                // 时光轴纵线
                Rectangle()
                    .fill(hairlineTint)
                    .frame(width: 1.5)
                    .padding(.vertical, 16)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        timelineRow(item)
                            .padding(.vertical, index == 0 ? 2 : 14)
                        if index < items.count - 1 {
                            Rectangle()
                                .fill(hairlineTint.opacity(0.5))
                                .frame(height: 0.8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.top, 10)

            HStack {
                Text("日子不多的月份，就翻翻过去的自己 ✦")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(textSecondary)
                Spacer()
            }
            .padding(.top, 8)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(HoloWidgetBrand.hairline(for: colorScheme))
                    .frame(height: 0.8)
            }
        }
        .padding(16)
    }

    private func timelineRow(_ item: HoloWidgetAnniversaryItem) -> some View {
        HStack(spacing: 11) {
            VStack(spacing: 1) {
                Text(item.monthText)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(textSecondary)
                Text(item.dayText)
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(textPrimary)
            }
            .frame(width: 42, height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(cardTint))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hairlineTint, lineWidth: 0.8)
            )

            HoloWidgetIconText.icon(item.icon, size: 15)
                .frame(width: 24)

            Text(item.title)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(textPrimary)
                .lineLimit(1)

            Spacer(minLength: 4)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(item.displayDays)")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(primaryTint)
                Text(headlineUnit(item))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(textSecondary)
            }
        }
    }

    // MARK: 文案

    private func daysNumber(_ item: HoloWidgetAnniversaryItem, bigSize: CGFloat) -> some View {
        if item.isToday {
            return AnyView(
                Text("就是今天")
                    .font(.system(size: bigSize * 0.5, weight: .heavy))
                    .foregroundStyle(primaryTint)
            )
        }
        return AnyView(
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(item.displayDays)")
                    .font(.system(size: bigSize, weight: .heavy))
                    .foregroundStyle(primaryTint)
                    .minimumScaleFactor(0.55)
                Text(headlineUnit(item))
                    .font(.system(size: bigSize * 0.3, weight: .semibold))
                    .foregroundStyle(textSecondary)
            }
        )
    }

    private func headlinePrefix(_ item: HoloWidgetAnniversaryItem) -> String {
        if item.isToday { return "就是今天" }
        return item.days > 0 ? "还有" : "已过"
    }

    private func headlineUnit(_ item: HoloWidgetAnniversaryItem) -> String {
        item.isToday ? "" : "天"
    }

    private func headlineCompact(_ item: HoloWidgetAnniversaryItem) -> String {
        if item.isToday { return "今天" }
        let prefix = item.days > 0 ? "还有" : "已过"
        return "\(prefix) \(item.displayDays) 天"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            HoloWidgetIconText.icon("🎂", size: 26)
            Text("还没有纪念日")
                .font(.system(size: family == .systemSmall ? 12 : 14, weight: .bold))
                .foregroundStyle(textPrimary)
            Text("去记一个重要的日子")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
    }

    private var primaryTint: Color { HoloWidgetBrand.primary(for: colorScheme) }
    private var cardTint: Color { HoloWidgetBrand.card(for: colorScheme) }
    private var hairlineTint: Color { HoloWidgetBrand.hairline(for: colorScheme) }
    private var textPrimary: Color { HoloWidgetBrand.textPrimary(for: colorScheme) }
    private var textSecondary: Color { HoloWidgetBrand.textSecondary(for: colorScheme) }
}
