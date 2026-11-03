import SwiftUI

struct PieChartSegment: Identifiable, Equatable {
    let id: String
    let name: String
    let weight: Double
    let valueText: String
    func percentageText(total: Double) -> String { String(format: "%.1f%%", total > 0 ? weight / total * 100 : 0) }
}

/// 业务兼容入口；原生环形图、列表选择和读数由公共组件承担。
struct PieChartView: View {
    var motion = HoloContinuousMotion()
    var segments: [PieChartSegment]
    var selectedSegmentID: String?
    var colors: [Color]
    var centerIdleText = ""
    var emptyText = String(localized: "暂无数据，这就开始记一笔吧！")
    var onSelectSegment: ((PieChartSegment?) -> Void)?
    init(
        motion: HoloContinuousMotion = HoloContinuousMotion(),
        segments: [PieChartSegment],
        selectedSegmentID: String? = nil,
        colors: [Color],
        centerIdleText: String = "",
        emptyText: String = String(localized: "暂无数据，这就开始记一笔吧！"),
        onSelectSegment: ((PieChartSegment?) -> Void)? = nil
    ) {
        self.motion = motion
        self.segments = segments
        self.selectedSegmentID = selectedSegmentID
        self.colors = colors
        self.centerIdleText = centerIdleText
        self.emptyText = emptyText
        self.onSelectSegment = onSelectSegment
    }

    /// 财务旧签名便捷入口（类别 Tab 原调用零改动）：CategoryAggregation 映射为通用扇区
    init(
        aggregations: [CategoryAggregation],
        selectedCategory: Category?,
        colors: [Color],
        onSelectCategory: ((Category?) -> Void)?
    ) {
        let positive = aggregations.filter { $0.amount > 0 }
        self.init(
            segments: positive.map { agg in
                PieChartSegment(
                    id: agg.category.id.uuidString,
                    name: agg.category.name,
                    weight: Double(truncating: agg.amount as NSDecimalNumber),
                    valueText: agg.formattedCompactAmount
                )
            },
            selectedSegmentID: selectedCategory?.id.uuidString,
            colors: colors,
            centerIdleText: NumberFormatter.compactCurrency(positive.reduce(0) { $0 + $1.amount }),
            onSelectSegment: { segment in
                guard let segment else {
                    onSelectCategory?(nil)
                    return
                }
                onSelectCategory?(positive.first { $0.category.id.uuidString == segment.id }?.category)
            }
        )
    }


    private var merged: [PieChartSegment] {
        var result: [PieChartSegment] = []
        for segment in segments where segment.weight > 0 {
            if let index = result.firstIndex(where: { $0.id == segment.id }) {
                let existing = result[index]
                result[index] = PieChartSegment(id: existing.id, name: existing.name,
                                                weight: existing.weight + segment.weight, valueText: existing.valueText)
            } else { result.append(segment) }
        }
        return result
    }
    var body: some View {
        if merged.isEmpty {
            Text(emptyText).font(.caption).foregroundStyle(Color.holoToolTextSecondary)
                .frame(maxWidth: .infinity).frame(minHeight: 160)
        } else {
            HoloDonutChart(segments: merged.enumerated().map { index, segment in
                HoloDonutSegment(id: segment.id, name: segment.name, weight: segment.weight, valueText: segment.valueText,
                                 color: colors.indices.contains(index) ? colors[index] : Color.holoChartColors(count: merged.count)[index])
            }, selectedID: selectedSegmentID, centerText: centerIdleText, showsList: false,
               onSelect: { id in onSelectSegment?(merged.first { $0.id == id }) })
        }
    }
}
