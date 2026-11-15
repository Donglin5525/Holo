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

/// 构成趋势（堆叠面积）：多系列按桶堆叠，回答「构成怎么随时间变」。
/// 读数/横滑/数字过渡与柱线图同一语言：固定读数区逐系列出值，idle 显示末桶。
struct HoloStackedAreaChart: View {
    let buckets: [HoloStackedAreaBucket]
    let series: [HoloStackedAreaSeries]
    @Binding var selection: String?
    var height: CGFloat = 170
    /// idle 读数行小字（如「近 6 月 · 点按或横滑查看」）；末桶合计拼在后面
    var summary: String = ""
    var valueText: (Double) -> String = HoloChartFormat.number

    @State private var haptic = UISelectionFeedbackGenerator()
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

    var body: some View {
        if buckets.isEmpty {
            Text("暂无可用数据").font(.caption).foregroundStyle(Color.holoToolTextSecondary)
                .frame(maxWidth: .infinity).frame(height: height)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                readout
                chart
            }
        }
    }

    private var readout: some View {
        let index = selectedIndex
        // 复用公共读数件：选中桶把逐层值摊进 values 数组；idle = 末桶逐层值
        let lastValues: [Double?] = series.map { item in
            guard let last = buckets.indices.last, item.values.indices.contains(last) else { return nil }
            return item.values[last]
        }
        return HoloChartReadout(
            bucket: index.map { i in
                HoloChartBucket(id: buckets[i].id, label: buckets[i].label, detail: buckets[i].detail,
                                values: series.map { item in
                                    item.values.indices.contains(i) ? item.values[i] : nil
                                })
            },
            series: series.map { HoloChartSeries(id: $0.id, title: $0.title, color: $0.color) },
            summary: "\(summary)\(summary.isEmpty ? "" : " · ")\(buckets.last?.label ?? "")合计 \(valueText(totals.last ?? 0))",
            valueText: valueText,
            idleValues: lastValues,
            onOpenDetail: nil
        )
    }

    private var chart: some View {
        Chart {
            ForEach(series.indices, id: \.self) { s in
                ForEach(buckets.indices, id: \.self) { b in
                    let lower = s == 0 ? 0 : levels[s - 1][b]
                    let upper = levels[s][b]
                    // 多系列必须走分类通道（by: + 前景样式量表）：逐 mark 字面色在
                    // 同型堆叠 AreaMark 上会被 coerce 成单一色系（2026-11-15 真机实锤全蓝）
                    AreaMark(x: .value("时间", Double(b)), yStart: .value("底", lower), yEnd: .value("顶", upper))
                        .foregroundStyle(by: .value("分类", series[s].title))
                        .opacity(0.55)
                        .interpolationMethod(.linear)
                        .accessibilityLabel("\(buckets[b].label) \(series[s].title) \(valueText(series[s].values.indices.contains(b) ? (series[s].values[b] ?? 0) : 0))")
                }
                ForEach(buckets.indices, id: \.self) { b in
                    LineMark(x: .value("时间", Double(b)), y: .value("层顶", levels[s][b]))
                        .foregroundStyle(by: .value("分类", series[s].title))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .interpolationMethod(.linear)
                        .accessibilityHidden(true)
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
        .chartForegroundStyleScale(range: series.map(\.color))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.holoToolBorder.opacity(0.6))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(HoloChartFormat.axisNumber(number)).font(.system(size: axisSize))
                            .foregroundStyle(Color.holoToolTextSecondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: xTickValues) { value in
                AxisValueLabel {
                    if let index = value.as(Int.self), buckets.indices.contains(index) {
                        Text(buckets[index].label).font(.system(size: axisSize))
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .foregroundStyle(Color.holoToolTextSecondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let plot = geometry[anchor]
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
