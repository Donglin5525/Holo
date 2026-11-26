import SwiftUI
import Charts
import UIKit

/// 构成趋势的一个层（如「餐饮」）；values 与桶同位，nil 按 0 层参与堆叠。
struct HoloStackedAreaSeries: Identifiable, Equatable {
    let id: String
    let title: String
    let color: Color
    let values: [Double?]
}

struct HoloStackedAreaBucket: Identifiable, Equatable {
    let id: String
    let label: String
    var detail: String? = nil
}

/// 构成趋势（支持月度堆叠柱状图 / 堆叠面积图）：多系列按桶堆叠，回答「构成怎么随时间变」。
/// 2026-11-26 改版：默认月度堆叠柱状图 + 2 列紧凑可点击图例（点击高亮单类走势）+ 横轴月份严格居中对齐柱中心。
struct HoloStackedAreaChart: View {
    enum StackedPresentation { case stackedBar, stackedArea }

    let buckets: [HoloStackedAreaBucket]
    let series: [HoloStackedAreaSeries]
    @Binding var selection: String?
    var height: CGFloat = 156
    /// idle 读数行小字（如「近 6 月」）；末桶合计拼在后面
    var summary: String = ""
    var presentation: StackedPresentation = .stackedBar
    var valueText: (Double) -> String = HoloChartFormat.number

    @State private var haptic = UISelectionFeedbackGenerator()
    @State private var focusedSeriesID: String? = nil
    @ScaledMetric(relativeTo: .caption2) private var axisSize: CGFloat = 11

    /// 堆叠累计水位（纯函数，单测锁定）：levels[i][b] = 到第 i 层的累计顶
    static func cumulativeLevels(series: [HoloStackedAreaSeries], bucketCount: Int) -> [[Double]] {
        var levels = Array(repeating: Array(repeating: 0.0, count: max(bucketCount, 0)), count: series.count)
        var running = Array(repeating: 0.0, count: max(bucketCount, 0))
        for (index, item) in series.enumerated() where bucketCount > 0 {
            for b in 0..<bucketCount {
                running[b] += item.values.indices.contains(b) ? (item.values[b] ?? 0) : 0
                levels[index][b] = running[b]
            }
        }
        return levels
    }

    private var levels: [[Double]] { HoloStackedAreaChart.cumulativeLevels(series: series, bucketCount: buckets.count) }
    private var totals: [Double] { buckets.indices.map { b in series.enumerated().map { $0.element.values.indices.contains(b) ? ($0.element.values[b] ?? 0) : 0 }.reduce(0, +) } }
    private var selected: HoloStackedAreaBucket? { buckets.first { $0.id == selection } }
    private var selectedIndex: Int? { buckets.firstIndex { $0.id == selection } }
    private var activeBucketIndex: Int { selectedIndex ?? max(buckets.count - 1, 0) }

    var body: some View {
        if buckets.isEmpty {
            Text("暂无可用数据").font(.caption).foregroundStyle(Color.holoToolTextSecondary)
                .frame(maxWidth: .infinity).frame(height: height)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                compactHeader
                compactLegendGrid
                chart
            }
        }
    }

    /// 顶部极简读数行：左侧显示当前（或最近一月）合计，右侧提示点图例高亮
    private var compactHeader: some View {
        let idx = activeBucketIndex
        let bucketLabel = buckets.indices.contains(idx) ? (buckets[idx].detail ?? buckets[idx].label) : ""
        let total = totals.indices.contains(idx) ? totals[idx] : 0
        return HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 4) {
                Text("\(bucketLabel)合计")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary)
                Text(valueText(total))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.holoToolText)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8)
            Text(focusedSeriesID == nil ? "点图例高亮单类" : "再点恢复全部")
                .font(.system(size: 11))
                .foregroundStyle(Color.holoToolTextSecondary.opacity(0.8))
        }
    }

    /// 2 列紧凑图例网格（替代原版 5 行竖排大字占半屏）
    private var compactLegendGrid: some View {
        let idx = activeBucketIndex
        let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(series) { item in
                let val = item.values.indices.contains(idx) ? (item.values[idx] ?? 0) : 0
                let isFocused = focusedSeriesID == item.id
                let isDimmed = focusedSeriesID != nil && !isFocused
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        focusedSeriesID = isFocused ? nil : item.id
                    }
                    haptic.selectionChanged()
                } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(item.color)
                            .frame(width: 7, height: 7)
                        Text(item.title)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.holoToolTextSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(valueText(val))
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.holoToolText)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isFocused ? Color.holoToolInset : Color.clear)
                    )
                    .opacity(isDimmed ? 0.32 : 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(series.indices, id: \.self) { s in
                let isDimmed = focusedSeriesID != nil && focusedSeriesID != series[s].id
                if presentation == .stackedBar {
                    ForEach(buckets.indices, id: \.self) { b in
                        let lower = s == 0 ? 0 : levels[s - 1][b]
                        let upper = levels[s][b]
                        let bucketDimmed = selectedIndex != nil && selectedIndex != b
                        if upper > lower {
                            BarMark(x: .value("时间", Double(b)),
                                    yStart: .value("底", lower),
                                    yEnd: .value("顶", upper),
                                    width: .fixed(22))
                                .foregroundStyle(by: .value("分类", series[s].title))
                                .opacity(isDimmed ? 0.18 : (bucketDimmed ? 0.45 : 0.92))
                                .cornerRadius(s == series.count - 1 ? 3 : 1)
                                .accessibilityLabel("\(buckets[b].label) \(series[s].title) \(valueText(series[s].values.indices.contains(b) ? (series[s].values[b] ?? 0) : 0))")
                        }
                    }
                } else {
                    ForEach(buckets.indices, id: \.self) { b in
                        let lower = s == 0 ? 0 : levels[s - 1][b]
                        let upper = levels[s][b]
                        AreaMark(x: .value("时间", Double(b)), yStart: .value("底", lower), yEnd: .value("顶", upper))
                            .foregroundStyle(by: .value("分类", series[s].title))
                            .opacity(isDimmed ? 0.15 : 0.55)
                            .interpolationMethod(.linear)
                            .accessibilityLabel("\(buckets[b].label) \(series[s].title) \(valueText(series[s].values.indices.contains(b) ? (series[s].values[b] ?? 0) : 0))")
                    }
                    ForEach(buckets.indices, id: \.self) { b in
                        LineMark(x: .value("时间", Double(b)), y: .value("层顶", levels[s][b]))
                            .foregroundStyle(by: .value("分类", series[s].title))
                            .opacity(isDimmed ? 0.2 : 1)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .interpolationMethod(.linear)
                            .accessibilityHidden(true)
                    }
                }
            }
            if let index = selectedIndex {
                RuleMark(x: .value("选中位置", Double(index)))
                    .foregroundStyle(Color.holoToolTextSecondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXScale(domain: -0.5...(Double(max(buckets.count - 1, 0)) + 0.5))
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .chartForegroundStyleScale(range: series.map(\.color))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.holoToolBorder.opacity(0.6))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(HoloChartFormat.axisNumber(number)).font(.system(size: axisSize))
                            .foregroundStyle(Color.holoToolTextSecondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let plot = geometry[anchor]
                    // 横轴月份标签严格居中对齐每根柱/点中心，彻底修复 Swift Charts 默认左对齐右偏半格的 Bug
                    ForEach(xTickValues, id: \.self) { index in
                        if buckets.indices.contains(index), let px = proxy.position(forX: Double(index)) {
                            let isHighlighted = (selectedIndex ?? buckets.count - 1) == index
                            Text(buckets[index].label)
                                .font(.system(size: axisSize, weight: isHighlighted ? .semibold : .regular))
                                .foregroundStyle(isHighlighted ? Color.holoToolText : Color.holoToolTextSecondary)
                                .lineLimit(1)
                                .position(x: plot.minX + px, y: plot.maxY + axisSize / 2 + 7)
                                .allowsHitTesting(false)
                        }
                    }
                    DirectionalChartGestureOverlay(
                        onChanged: { point in inspect(point, proxy: proxy, plot: plot, clamped: true) },
                        onEnded: { _ in }, onCancelled: {},
                        onTap: { point in inspect(point, proxy: proxy, plot: plot, clamped: false) }
                    )
                    .accessibilityElement()
                    .accessibilityLabel("构成趋势选中月份")
                    .accessibilityValue(selection ?? "未选中")
                    .frame(width: plot.width, height: plot.height)
                    .position(x: plot.midX, y: plot.midY)
                }
            }
        }
        .frame(height: height)
        .padding(.bottom, axisSize + 12)
    }

    /// x 轴刻度（桶下标）：≤8 桶全显（「N月」两三字全放得下，抽样反而缺月），
    /// 更密再走公共容量预算
    private var xTickValues: [Int] {
        buckets.count <= 8 ? Array(buckets.indices)
                           : HoloChartGeometry.tickIndices(count: buckets.count, width: 320)
    }

    private func inspect(_ point: CGPoint, proxy: ChartProxy, plot: CGRect, clamped: Bool) {
        guard clamped || (point.x >= 0 && point.x <= plot.width) else { return }
        let positions = buckets.indices.map { proxy.position(forX: Double($0)) ?? .infinity }
        guard let index = HoloChartGeometry.nearestIndex(x: min(max(point.x, 0), plot.width), positions: positions) else { return }
        let id = buckets[index].id
        guard selection != id else { return }
        selection = id
        haptic.selectionChanged()
    }
}
