//
//  HoloHabitWidget.swift
//  HoloWidgets
//
//  今日习惯 · 招牌视觉「今日圆环 + 节奏点阵」
//

import SwiftUI
import WidgetKit

struct HoloHabitWidget: Widget {
    let kind = HoloWidgetKind.habit.rawValue

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HoloHabitProvider()) { entry in
            HoloHabitWidgetView(entry: entry)
        }
        .configurationDisplayName("今日习惯")
        .description("今天的习惯完成度，一眼看完一周的坚持形状。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct HoloHabitProvider: TimelineProvider {
    func placeholder(in context: Context) -> HoloWidgetEntry<HoloWidgetHabitSnapshot> {
        HoloWidgetEntry(date: Date(), value: .sample(), entitlement: .plusPreview())
    }

    func getSnapshot(in context: Context, completion: @escaping (HoloWidgetEntry<HoloWidgetHabitSnapshot>) -> Void) {
        completion(HoloWidgetEntry(
            date: Date(),
            value: .sample(),
            entitlement: widgetEntitlement(for: context)
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HoloWidgetEntry<HoloWidgetHabitSnapshot>>) -> Void) {
        let store = HoloWidgetSnapshotStore()
        let entitlement = store.readEntitlement() ?? .free()
        let snapshot = entitlement.isPlusActive ? (store.readHabit() ?? .sample()) : .sample()
        let entry = HoloWidgetEntry(date: Date(), value: snapshot, entitlement: entitlement)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 30))))
    }
}

private struct HoloHabitWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: HoloWidgetEntry<HoloWidgetHabitSnapshot>

    private var value: HoloWidgetHabitSnapshot { entry.value }

    var body: some View {
        Group {
            if entry.entitlement.isPlusActive {
                Link(destination: URL(string: "holo://habits")!) {
                    if value.totalToday == 0 {
                        emptyState
                    } else if family == .systemSmall {
                        habitSmall
                    } else if family == .systemLarge {
                        habitLarge
                    } else {
                        habitMedium
                    }
                }
            } else {
                HoloLockedWidgetView()
            }
        }
        .holoWidgetBackground(colorScheme: colorScheme)
    }

    // MARK: Small · 完成环 + emoji 点

    private var habitSmall: some View {
        VStack(spacing: 8) {
            Text("今日习惯")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(textSecondary)
            ZStack {
                HoloWidgetRingGauge(
                    progress: totalToday > 0 ? Double(completedToday) / Double(totalToday) : 0,
                    lineWidth: 8.5,
                    trackColor: trackTint,
                    progressColor: primaryTint
                )
                Text("\(completedToday)/\(totalToday)")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(textPrimary)
                    .minimumScaleFactor(0.6)
            }
            .frame(width: 64, height: 64)

            HStack(spacing: 4) {
                ForEach(value.habits.prefix(5)) { habit in
                    HoloWidgetIconText.icon(habit.icon, size: 10)
                        .frame(width: 19, height: 19)
                        .background(
                            Circle().fill(habit.isCompletedToday ? primarySubtle : cardTint)
                        )
                        .overlay(
                            Circle().strokeBorder(
                                habit.isCompletedToday
                                    ? primaryTint.opacity(0.4)
                                    : hairlineTint,
                                lineWidth: 0.8
                            )
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }

    // MARK: Medium · 圆环 + 前 3 个习惯

    private var habitMedium: some View {
        HStack(spacing: 14) {
            VStack(spacing: 9) {
                ZStack {
                    HoloWidgetRingGauge(
                        progress: totalToday > 0 ? Double(completedToday) / Double(totalToday) : 0,
                        lineWidth: 8.5,
                        trackColor: trackTint,
                        progressColor: primaryTint
                    )
                    VStack(spacing: 1) {
                        Text("\(completedToday)/\(totalToday)")
                            .font(.system(size: 17, weight: .heavy))
                            .foregroundStyle(textPrimary)
                            .minimumScaleFactor(0.6)
                        Text("今日完成")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(textSecondary)
                    }
                }
                .frame(width: 82, height: 82)

                Text(remainingText)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(primaryTint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(primarySubtle)
                    .clipShape(Capsule())
            }
            .frame(width: 108)

            VStack(spacing: 8) {
                ForEach(value.habits.prefix(3)) { habit in
                    habitRow(habit, showsWeekPattern: false)
                }
            }
        }
        .padding(15)
    }

    // MARK: Large · 5 习惯 × 7 天节奏点阵

    private var habitLarge: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("今日习惯 · ")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(textPrimary)
                +
                Text("\(completedToday)/\(totalToday)")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(primaryTint)
                Spacer()
                if !value.longestStreakText.isEmpty {
                    Text("🔥 最长连续 \(value.longestStreakText)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(primaryTint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(primarySubtle)
                        .clipShape(Capsule())
                }
            }

            VStack(spacing: 0) {
                ForEach(value.habits.prefix(5)) { habit in
                    habitRow(habit, showsWeekPattern: true)
                        .padding(.vertical, 7)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.top, 4)
        }
        .padding(16)
    }

    // MARK: 零件

    private func habitRow(_ habit: HoloWidgetHabitItem, showsWeekPattern: Bool) -> some View {
        HStack(spacing: 9) {
            HoloWidgetIconText.icon(habit.icon, size: 13)
                .frame(width: 25, height: 25)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(cardTint))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(hairlineTint, lineWidth: 0.8)
                )

            Text(habit.name)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(textPrimary)
                .lineLimit(1)

            if showsWeekPattern {
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    ForEach(Array(habit.weekPattern.enumerated()), id: \.offset) { offset, done in
                        let isLast = offset == habit.weekPattern.count - 1
                        Circle()
                            .fill(done ? primaryTint : trackTint)
                            .frame(width: 6.5, height: 6.5)
                            .overlay(
                                Circle().strokeBorder(
                                    isLast ? primaryTint.opacity(0.85) : .clear,
                                    lineWidth: 1.2
                                )
                                .padding(-2.4)
                            )
                    }
                }
            } else {
                Spacer(minLength: 6)
            }

            if !habit.streakText.isEmpty {
                Text("🔥 \(habit.streakText)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(textSecondary)
                    .lineLimit(1)
            }

            ZStack {
                if habit.isCompletedToday {
                    Circle().fill(primaryTint)
                    Image(systemName: "checkmark")
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundStyle(Color.white)
                } else {
                    Circle().strokeBorder(trackTint, lineWidth: 1.6)
                }
            }
            .frame(width: 18, height: 18)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(cardTint))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(hairlineTint, lineWidth: 0.8)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            HoloWidgetIconText.icon("🌱", size: 26)
            Text("还没有进行中的习惯")
                .font(.system(size: family == .systemSmall ? 12 : 14, weight: .bold))
                .foregroundStyle(textPrimary)
            Text("去 Holo 种下第一个习惯")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
    }

    private var completedToday: Int { value.completedToday }
    private var totalToday: Int { value.totalToday }

    private var remainingText: String {
        let remaining = value.remainingCount
        if remaining == 0 { return "今日已齐 ✓" }
        return "还差 \(remaining) 个"
    }

    private var primaryTint: Color { HoloWidgetBrand.primary(for: colorScheme) }
    private var primarySubtle: Color { HoloWidgetBrand.primarySubtle(for: colorScheme) }
    private var cardTint: Color { HoloWidgetBrand.card(for: colorScheme) }
    private var hairlineTint: Color { HoloWidgetBrand.hairline(for: colorScheme) }
    private var textPrimary: Color { HoloWidgetBrand.textPrimary(for: colorScheme) }
    private var textSecondary: Color { HoloWidgetBrand.textSecondary(for: colorScheme) }
    private var trackTint: Color { HoloWidgetBrand.progressTrack(for: colorScheme) }
}
