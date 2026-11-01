import SwiftUI

struct MemoryHeatmapView: View {
    let data: [Date: Int]
    let selectedDate: Date?
    let onSelectDate: (Date) -> Void
    @Environment(\.holoContentWidth) private var contentWidth
    private var weeks: Int { HoloAdaptiveLayout.isExpandedWidth(contentWidth) ? 26 : 13 }
    private var days: [HoloHeatmapDay] {
        let today = Calendar.current.startOfDay(for: Date())
        let weekStart = today.startOfWeek
        let start = weekStart.addingWeeks(-(weeks - 1))
        return (0..<(weeks * 7)).map { offset in
            let date = start.addingDays(offset).startOfDay
            return HoloHeatmapDay(date: date, count: data[date] ?? 0, isFuture: date > today)
        }
    }
    var body: some View {
        // days 一次计算复用（原计算属性在 subtitle 与图表两处各重建一遍 91–182 个对象）
        let heatmapDays = days
        return HoloChartFrame(title: "活跃热力图", subtitle: "最近 \(weeks) 周 · \(heatmapDays.filter { $0.count > 0 && !$0.isFuture }.count) 天有记录", independent: true) {
            HoloHeatmap(days: heatmapDays, weekdayLabels: ["一", "", "三", "", "五", "", ""],
                        selectedDate: selectedDate, onSelect: { onSelectDate($0.date) })
            Text("记录数：0 · 1 · 2–3 · 4–5 · 6–9 · 10+")
                .font(.caption2).foregroundStyle(Color.holoToolTextSecondary)
        }
    }
}
