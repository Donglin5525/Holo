//
//  HabitStatsInsightCard.swift
//  Holo
//
//  统计页洞察卡：系统主动总结最佳坚持、最需关注、整体环比
//  省去用户逐条对比的功夫
//

import SwiftUI

struct HabitStatsInsightCard: View {
    /// 本月展示的习惯项（用于推导最佳/最弱）
    let items: [HabitStatsDisplayItem]
    /// 本月整体平均完成率
    let completionRate: Double
    /// 上月整体平均完成率（环比）
    let previousRate: Double

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.holoPrimary)
                    .frame(width: 3.5, height: 13)
                Text("本月洞察")
                    .font(.holoCaption.weight(.semibold))
                    .foregroundColor(.holoTextPrimary)
            }
            .padding(.bottom, 2)

            VStack(spacing: 0) {
                if let best = bestHabit {
                    insightRow(
                        icon: "flame.fill",
                        color: .holoSuccess,
                        main: Text("\(best.name)是本月最佳，完成率 ").foregroundColor(.holoTextPrimary)
                            + Text("\(rateText(best.completionRate))%").bold().foregroundColor(.holoSuccess),
                        sub: "坚持得很稳，状态在线"
                    )
                    Divider().foregroundStyle(Color.holoDivider).padding(.vertical, 2)
                }

                if let weak = weakestHabit, weak.habitId != bestHabit?.habitId {
                    insightRow(
                        icon: "exclamationmark.triangle.fill",
                        color: .holoPrimary,
                        main: Text("\(weak.name)需要关注，完成率 ").foregroundColor(.holoTextPrimary)
                            + Text("\(rateText(weak.completionRate))%").bold().foregroundColor(.holoPrimary),
                        sub: "完成率最低，可以多投入一些"
                    )
                    Divider().foregroundStyle(Color.holoDivider).padding(.vertical, 2)
                }

                insightRow(
                    icon: trendIcon,
                    color: .holoInfo,
                    main: overallMainText,
                    sub: overallSubText
                )
            }
        }
        .padding(HoloSpacing.md)
        .holoCard()
    }

    // MARK: - 洞察推导

    /// 完成率最高的习惯
    private var bestHabit: HabitStatsDisplayItem? {
        items.max(by: { $0.completionRate < $1.completionRate })
    }

    /// 完成率最低的习惯（至少 2 个习惯才有"最弱"意义）
    private var weakestHabit: HabitStatsDisplayItem? {
        guard items.count >= 2 else { return nil }
        return items.min(by: { $0.completionRate < $1.completionRate })
    }

    private var rateDelta: Double? {
        guard previousRate > 0 else { return nil }
        return completionRate - previousRate
    }

    private var trendIcon: String {
        if let delta = rateDelta {
            return delta >= 0 ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis"
        }
        return "chart.bar.xaxis"
    }

    private var overallMainText: Text {
        let rate = rateText(completionRate)
        if let delta = rateDelta, abs(delta) > 0.5 {
            let isUp = delta > 0
            return Text("整体完成率 \(rate)%，比上月 ")
                .foregroundColor(.holoTextPrimary)
                + Text("\(isUp ? "↑" : "↓") \(rateText(abs(delta)))%")
                .bold()
                .foregroundColor(isUp ? .holoSuccess : .holoError)
        }
        return Text("整体完成率 \(rate)%，继续保持")
            .foregroundColor(.holoTextPrimary)
    }

    private var overallSubText: String {
        guard let delta = rateDelta, abs(delta) > 0.5 else { return "养成好节奏" }
        return delta > 0 ? "进步明显，再接再厉" : "略有回落，调整节奏"
    }

    /// 完成率显示值（四舍五入，避免出现 67.0%）
    private func rateText(_ value: Double) -> Int {
        Int(value.rounded())
    }

    // MARK: - 单条洞察行

    private func insightRow(icon: String, color: Color, main: Text, sub: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                main
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }
}

#Preview {
    let calendar = Calendar.current
    let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!

    func item(_ name: String, _ hex: String, _ rate: Double, _ id: String) -> HabitStatsDisplayItem {
        HabitStatsDisplayItem(
            habitId: UUID(uuidString: id) ?? UUID(), name: name, icon: "book.fill",
            isCustomIcon: false, habitColorHex: hex, type: .checkIn,
            summary: .checkIn(completedDays: 20, streak: HabitStreak(value: 20, unit: .day)),
            collapsedWeek: HabitStatsWeekSlice(weekStart: monthStart, days: []),
            allWeeks: [], month: HabitStatsMonthSection(monthStart: monthStart, weekdaySymbols: [], rows: []),
            dailyData: [], unitText: "", completionRate: rate
        )
    }

    return HabitStatsInsightCard(
        items: [item("阅读", "#10B981", 95, "00000000-0000-0000-0000-000000000001"),
                item("冥想", "#8B5CF6", 25, "00000000-0000-0000-0000-000000000002"),
                item("跑步", "#13A4EB", 60, "00000000-0000-0000-0000-000000000003")],
        completionRate: 68,
        previousRate: 56
    )
    .padding()
    .background(Color.holoBackground)
}
