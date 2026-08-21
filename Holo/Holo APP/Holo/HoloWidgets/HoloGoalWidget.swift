//
//  HoloGoalWidget.swift
//  HoloWidgets
//
//  目标进度 · 招牌视觉「里程碑弧」
//

import SwiftUI
import WidgetKit

struct HoloGoalWidget: Widget {
    let kind = HoloWidgetKind.goal.rawValue

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HoloGoalProvider()) { entry in
            HoloGoalWidgetView(entry: entry)
        }
        .configurationDisplayName("目标进度")
        .description("最重要的那个目标，推进到哪了。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct HoloGoalProvider: TimelineProvider {
    func placeholder(in context: Context) -> HoloWidgetEntry<HoloWidgetGoalSnapshot> {
        HoloWidgetEntry(date: Date(), value: .sample(), entitlement: .plusPreview())
    }

    func getSnapshot(in context: Context, completion: @escaping (HoloWidgetEntry<HoloWidgetGoalSnapshot>) -> Void) {
        completion(HoloWidgetEntry(
            date: Date(),
            value: .sample(),
            entitlement: widgetEntitlement(for: context)
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HoloWidgetEntry<HoloWidgetGoalSnapshot>>) -> Void) {
        let store = HoloWidgetSnapshotStore()
        let entitlement = store.readEntitlement() ?? .free()
        let snapshot = entitlement.isPlusActive ? (store.readGoal() ?? .sample()) : .sample()
        let entry = HoloWidgetEntry(date: Date(), value: snapshot, entitlement: entitlement)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 60))))
    }
}

private struct HoloGoalWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: HoloWidgetEntry<HoloWidgetGoalSnapshot>

    var body: some View {
        Group {
            if entry.entitlement.isPlusActive {
                if let goal = entry.value.goal {
                    Link(destination: goal.detailDeepLink) {
                        if family == .systemMedium {
                            goalMedium(goal)
                        } else {
                            goalSmall(goal)
                        }
                    }
                } else {
                    emptyState
                }
            } else {
                HoloLockedWidgetView()
            }
        }
        .holoWidgetBackground(colorScheme: colorScheme)
    }

    // MARK: Small · 弧形仪表 + 大数字

    private func goalSmall(_ goal: HoloWidgetGoalItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("目标 · \(goal.title)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let progress = goal.progress {
                Text(goal.percentText ?? "\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 27, weight: .heavy))
                    .foregroundStyle(primaryTint)
                    .minimumScaleFactor(0.6)
                    .padding(.top, 4)
                if let currentTarget = currentTargetText(goal) {
                    Text(currentTarget)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.top, 4)
                }
            } else {
                // 过程型：无数字进度，展示说明行
                Text("行动中")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(primaryTint)
                    .padding(.top, 6)
                if let kindText = goal.kindText {
                    Text(kindText)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(textSecondary)
                        .lineLimit(2)
                        .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)

            HStack(alignment: .bottom) {
                if let forecast = goal.forecastText {
                    Text(forecast)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                gauge(goal, side: 62, lineWidth: 7)
                    .frame(width: 70, height: 46, alignment: .bottomTrailing)
            }
        }
        .padding(15)
    }

    // MARK: Medium · 里程碑弧 + 三行账

    private func goalMedium(_ goal: HoloWidgetGoalItem) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            ZStack(alignment: .bottom) {
                gauge(goal, side: 116, lineWidth: 9)
                    .frame(width: 126, height: 88)
                if let progress = goal.progress {
                    Text(goal.percentText ?? "\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 19, weight: .heavy))
                        .foregroundStyle(primaryTint)
                        .padding(.bottom, 10)
                } else {
                    HoloWidgetIconText.icon(goal.icon, size: 20)
                        .padding(.bottom, 12)
                }
            }
            .frame(width: 126)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    HoloWidgetIconText.icon(goal.icon, size: 15)
                    Text(goal.title)
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                if goal.progress != nil {
                    VStack(alignment: .leading, spacing: 7) {
                        if let current = goal.currentText {
                            kvRow("已推进", current, tint: textPrimary)
                        }
                        if let target = goal.targetText {
                            kvRow("目标", target, tint: textPrimary)
                        }
                        if let remaining = goal.remainingText {
                            kvRow("还差", remaining, tint: primaryTint)
                        }
                    }
                    .padding(.top, 9)
                } else if let kindText = goal.kindText {
                    Text(kindText)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(textSecondary)
                        .padding(.top, 8)
                }

                Spacer(minLength: 0)

                if let forecast = goal.forecastText {
                    Text(forecast)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(greenTint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.bottom, 2)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .padding(16)
    }

    // MARK: 零件

    private func gauge(_ goal: HoloWidgetGoalItem, side: CGFloat, lineWidth: CGFloat) -> some View {
        HoloWidgetSpeedometerGauge(
            progress: goal.progress ?? 0.04,
            lineWidth: lineWidth,
            trackColor: trackTint,
            progressColor: primaryTint
        )
        .frame(width: side, height: side)
    }

    private func currentTargetText(_ goal: HoloWidgetGoalItem) -> String? {
        guard let current = goal.currentText, let target = goal.targetText else { return nil }
        return "\(current) / \(target)"
    }

    private func kvRow(_ title: String, _ value: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(textSecondary)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 12.5, weight: .heavy))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            HoloWidgetIconText.icon("🎯", size: 26)
            Text("还没有进行中的目标")
                .font(.system(size: family == .systemSmall ? 12 : 14, weight: .bold))
                .foregroundStyle(textPrimary)
            Text("去 Holo 立一个想抵达的 flag")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
    }

    private var primaryTint: Color { HoloWidgetBrand.primary(for: colorScheme) }
    private var greenTint: Color { HoloWidgetBrand.success(for: colorScheme) }
    private var textPrimary: Color { HoloWidgetBrand.textPrimary(for: colorScheme) }
    private var textSecondary: Color { HoloWidgetBrand.textSecondary(for: colorScheme) }
    private var trackTint: Color { HoloWidgetBrand.progressTrack(for: colorScheme) }
}
