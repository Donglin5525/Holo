import SwiftUI
import Charts
import UIKit

/// 原生样板向界面测试报告实际绘图区；不使用截图或轴带估算定位。
struct HoloChartPlotFrameKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

struct HoloChartSeries: Identifiable {
    let id: String
    let title: String
    let color: Color
}

/// 柱状参考线：预算上限、均值这类「一眼知好坏」的水平线，恒显标签。
struct HoloChartRule {
    let value: Double
    let label: String
    var color: Color = .holoToolTextSecondary
}

/// 上期对照：淡影柱 + 闲置态合计环比徽标 + 选中桶「上期同期」小字。
/// 仅单系列柱状生效（对照语义给单一指标）。
struct HoloChartComparison {
    /// 与桶同位的上期值；nil 桶不画影
    let ghostValues: [Double?]
    var ghostLabel: String = "上期同期"
    var deltaLabel: String = "较上期"
    /// 涨=红（支出语义默认）；天数/完成率这类涨=好的传 false
    var risingIsBad = true
}

struct HoloChartBucket: Identifiable, Equatable {
    let id: String
    let label: String
    var detail: String? = nil
    var values: [Double?]
    var isFuture: Bool = false
    /// 同期对比可保留历史系列，同时单独标出本期尚未到来的系列。
    var futureSeries: Set<Int> = []
    /// nil 使用等宽自然桶；连续采样（如心率）传真实时间，保留时间比例。
    var position: Double? = nil
    /// 桶对应的自然日；横轴刻度走 .dayWithMonthAnchor 时用于月界锚定判断
    ///（2026-11-16 东林拍板「趋势图时间再缩短」），缺省不参与锚定逻辑。
    var date: Date? = nil

    func value(forSeries index: Int) -> Double? {
        guard !isFuture, !futureSeries.contains(index), values.indices.contains(index),
              let value = values[index], value.isFinite else { return nil }
        return value
    }
}

/// 横轴刻度标签口径：.bucketLabel=沿用调用方给的 label（默认，既有页面零变化）；
/// .dayWithMonthAnchor=日序列专用——被选刻度里首根或跨月时显「M.d」锚定月份，
/// 其余只显日数（11.1 / 8 / 16 / 23 / 30），触摸读数仍是全格式日期，信息零丢失。
enum HoloXAxisTickStyle {
    case bucketLabel
    case dayWithMonthAnchor
}

enum HoloChartFormat {
    private static let shortDate = formatter("Md")
    private static let dayOnly = formatter("d")
    private static let fullDate = formatter("yMMMd")
    private static let clock = formatter("HHmm")
    private static let month = formatter("M月")

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "zh_CN")))
    }

    static func date(_ date: Date, template: String = "Md") -> String {
        let format: DateFormatter
        switch template {
        case "Md": format = shortDate
        case "d": format = dayOnly
        case "yMMMd": format = fullDate
        case "HHmm": format = clock
        case "M月": format = month
        default: format = formatter(template)
        }
        return format.string(from: date)
    }

    static func axisNumber(_ value: Double) -> String {
        if abs(value) >= 100_000_000 { return number(value / 100_000_000) + "亿" }
        if abs(value) >= 10_000 { return number(value / 10_000) + "万" }
        return number(value)
    }

    /// 用自然日补齐展示范围；缺失值保持 nil，不伪造 0，也不跳选邻日。
    static func days(from start: Date, through end: Date, values: [(Date, Double)], calendar: Calendar = .current, step: Calendar.Component = .day) -> [HoloChartBucket] {
        let byDay = values.reduce(into: [Date: Double]()) { result, item in
            result[calendar.startOfDay(for: item.0)] = item.1
        }
        return HoloChartGeometry.dates(from: start, through: end, calendar: calendar, step: step).map { day in
            HoloChartBucket(id: String(day.timeIntervalSince1970), label: date(day),
                            detail: date(day, template: "yMMMd"), values: [byDay[day]])
        }
    }
}

enum HoloChartState {
    case ready
    case loading
    case empty(String)
    case failure(String)
}

/// 卡片与内嵌图共用的外壳；图表内部自己承担轴带与读数空间。
/// 空态引导（2026-11-15 拍板）：文案给盼头；动作按钮跟随数据源——有明确入口的模块传
/// emptyActionTitle + onEmptyAction（习惯→去打卡、记账→记一笔），来源不唯一的只传
/// emptyHint 指路，不硬塞按钮。
struct HoloChartFrame<Content: View>: View {
    var title: String = ""
    var subtitle: String = ""
    var independent = false
    var state: HoloChartState = .ready
    var emptyHint: String? = nil
    var emptyActionTitle: String? = nil
    var onEmptyAction: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty {
                Text(title).font(.headline).foregroundStyle(Color.holoToolText)
            }
            if !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(Color.holoToolTextSecondary)
            }
            switch state {
            case .ready: content()
            case .loading:
                ProgressView("正在读取数据…").frame(maxWidth: .infinity, minHeight: 120)
            case .empty(let message), .failure(let message):
                VStack(spacing: 8) {
                    Text(message).font(.subheadline).foregroundStyle(Color.holoToolTextSecondary)
                    if let emptyHint {
                        Text(emptyHint).font(.caption).foregroundStyle(Color.holoToolTextSecondary)
                            .multilineTextAlignment(.center)
                    }
                    if let emptyActionTitle, let onEmptyAction {
                        Button(emptyActionTitle, action: onEmptyAction)
                            .font(.subheadline.weight(.medium)).foregroundStyle(Color.holoToolAction)
                            .frame(minHeight: 44)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(independent ? 16 : 0)
        .holoSurface(independent ? .independent : .continuous)
    }
}

struct HoloBarChart: View {
    enum Orientation { case vertical, horizontal }
    let buckets: [HoloChartBucket]
    let series: [HoloChartSeries]
    var orientation: Orientation = .vertical
    @Binding var selection: String?
    var height: CGFloat = 160
    var yDomain: ClosedRange<Double>? = nil
    /// 双系列量级悬殊（最大值差三倍以上）时各立数值轴：右轴=第 0 系列、左轴=第 1 系列，
    /// 刻度随系列色；量级接近自动回落共用一轴。仅纵向柱状生效，且必须用于两种不同
    /// 指标（如支出/收入）；同一指标的同期对比（同比）量级悬殊也是真实差距，不许开启。
    var dualValueAxes = false
    var summary: String = "本期合计 · 点按或横滑查看"
    var summaryValues: [Double?]? = nil
    var valueText: (Double) -> String = HoloChartFormat.number
    /// 首次出现即选中最后一根（时间序列：最近一期先说话，避免空读数或无意义的合计）
    var defaultSelectsLastBucket = false
    /// 等宽槽位的指定刻度（桶下标；如按天图的每周一同列）。走公共摆放规则（贴边/等宽/预算），
    /// 不在此之上叠私有画法
    var slotTicks: [Int]? = nil
    /// 横轴刻度标签口径（默认沿用 bucket.label；日序列可换月界锚定，见 HoloXAxisTickStyle）
    var xAxisTickStyle: HoloXAxisTickStyle = .bucketLabel
    var rules: [HoloChartRule] = []
    var comparison: HoloChartComparison? = nil
    var legendToggle = false
    var onInspect: ((HoloChartBucket) -> Void)? = nil
    var onOpenDetail: ((HoloChartBucket) -> Void)? = nil

    var body: some View {
        if orientation == .horizontal {
            HoloHorizontalBarChart(buckets: buckets, series: series, selection: $selection,
                                   valueText: valueText, onOpenDetail: onOpenDetail, onInspect: onInspect)
        } else {
            HoloCartesianChart(buckets: buckets, series: series, selection: $selection, style: .bar,
                           height: height, yDomain: yDomain, dualValueAxes: dualValueAxes,
                           summary: summary, summaryValues: summaryValues, valueText: valueText,
                           defaultSelectsLastBucket: defaultSelectsLastBucket, slotTicks: slotTicks,
                           xAxisTickStyle: xAxisTickStyle,
                           rules: rules, comparison: comparison, legendToggle: legendToggle,
                           onInspect: onInspect, onOpenDetail: onOpenDetail)
        }
    }
}

private struct HoloHorizontalBarChart: View {
    let buckets: [HoloChartBucket]
    let series: [HoloChartSeries]
    @Binding var selection: String?
    let valueText: (Double) -> String
    let onOpenDetail: ((HoloChartBucket) -> Void)?
    let onInspect: ((HoloChartBucket) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HoloChartReadout(bucket: buckets.first { $0.id == selection }, series: series,
                             summary: "分类排名 · 点按查看", valueText: valueText,
                             idleValues: series.indices.map { index in
                                 let values = buckets.compactMap { $0.values.indices.contains(index) ? $0.values[index] : nil }
                                 return values.isEmpty ? nil : values.reduce(0, +)
                             }, onOpenDetail: onOpenDetail)
            Chart {
                ForEach(buckets) { bucket in
                    ForEach(series.indices, id: \.self) { index in
                        if let value = bucket.value(forSeries: index) {
                            BarMark(x: .value("数值", value), y: .value("分类", bucket.id), height: .fixed(12))
                                .position(by: .value("系列", series[index].id))
                                .foregroundStyle(series[index].color).cornerRadius(3)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .chartYScale(domain: Array(buckets.map(\.id).reversed()))
            .chartYAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let id = value.as(String.self), let bucket = buckets.first(where: { $0.id == id }) {
                            Text(bucket.label).font(.caption).foregroundStyle(Color.holoToolTextSecondary)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let anchor = proxy.plotFrame {
                        let plot = geometry[anchor]
                        Color.clear.contentShape(Rectangle()).onTapGesture { point in
                            guard plot.contains(point) else { return }
                            let positions = buckets.map { proxy.position(forY: $0.id) ?? .infinity }
                            guard let index = HoloChartGeometry.nearestIndex(x: point.y - plot.minY, positions: positions),
                                  !buckets[index].isFuture, selection != buckets[index].id else { return }
                            selection = buckets[index].id
                            onInspect?(buckets[index])
                        }
                    }
                }
            }
            .frame(height: CGFloat(max(buckets.count, 1)) * 44)
        }
        .onChange(of: buckets) { _, _ in selection = nil }
    }
}

/// 连续时间轴的指定刻度（position 坐标 + 文案）
struct HoloChartTick: Equatable {
    let position: Double
    let label: String
}

struct HoloLineChart: View {
    let buckets: [HoloChartBucket]
    let series: [HoloChartSeries]
    @Binding var selection: String?
    var height: CGFloat = 160
    var yDomain: ClosedRange<Double>? = nil
    var baseline: Double? = nil
    var summary: String = "最近记录 · 点按或横滑查看"
    var summaryValues: [Double?]? = nil
    var valueText: (Double) -> String = HoloChartFormat.number
    var defaultSelectsLastBucket = false
    var showsReadout = true
    /// 未选中时不显示伪读数（默认读数取末桶/合计，与实际选中日的数值无关），
    /// 由 summary 文案提示滑动查看；总览类图表（idle 读数即本期合计）保持 false 不变。
    var hidesIdleValues = false
    /// 折线每个数据点恒显（测量记录点视图：点即数据，不只孤立点/选中点显示）
    var alwaysShowPoints = false
    /// 连续时间轴的显式范围与刻度：横轴首尾 = 所选范围首尾，不随首末记录收缩（2026-11-02 轴即范围）
    var positionDomain: ClosedRange<Double>? = nil
    var positionTicks: [HoloChartTick]? = nil
    /// 峰/谷自动标注（测量类曲线；有效点不足 6 个不标）
    var annotateExtrema = false
    var extremaUnit = ""
    /// 正常区间带（健康测量）：浅色垫底 + 带缘标签，曲线在不在带内一眼可读
    var band: ClosedRange<Double>? = nil
    var legendToggle = false
    var onInspect: ((HoloChartBucket) -> Void)? = nil
    var onOpenDetail: ((HoloChartBucket) -> Void)? = nil

    var body: some View {
        HoloCartesianChart(buckets: buckets, series: series, selection: $selection, style: .line,
                           height: height, yDomain: yDomain, baseline: baseline, summary: summary,
                           summaryValues: summaryValues, valueText: valueText,
                           defaultSelectsLastBucket: defaultSelectsLastBucket, showsReadout: showsReadout,
                           hidesIdleValues: hidesIdleValues, alwaysShowPoints: alwaysShowPoints,
                           positionDomain: positionDomain, positionTicks: positionTicks,
                           annotateExtrema: annotateExtrema, extremaUnit: extremaUnit,
                           band: band, legendToggle: legendToggle,
                           onInspect: onInspect, onOpenDetail: onOpenDetail)
    }
}

private struct HoloCartesianChart: View {
    enum Style { case bar, line }
    let buckets: [HoloChartBucket]
    let series: [HoloChartSeries]
    @Binding var selection: String?
    let style: Style
    var height: CGFloat
    var yDomain: ClosedRange<Double>?
    var dualValueAxes = false
    var baseline: Double? = nil
    var summary: String
    var summaryValues: [Double?]? = nil
    var valueText: (Double) -> String
    var defaultSelectsLastBucket = false
    var slotTicks: [Int]? = nil
    var xAxisTickStyle: HoloXAxisTickStyle = .bucketLabel
    var showsReadout = true
    var hidesIdleValues = false
    /// 折线每个数据点恒显（测量记录点视图：点即数据）
    var alwaysShowPoints = false
    var positionDomain: ClosedRange<Double>? = nil
    var positionTicks: [HoloChartTick]? = nil
    var rules: [HoloChartRule] = []
    var comparison: HoloChartComparison? = nil
    var annotateExtrema = false
    var extremaUnit = ""
    var band: ClosedRange<Double>? = nil
    var legendToggle = false
    var onInspect: ((HoloChartBucket) -> Void)?
    var onOpenDetail: ((HoloChartBucket) -> Void)?
    @State private var plotWidth: CGFloat = 300
    @ScaledMetric(relativeTo: .caption2) private var axisSize: CGFloat = 11
    @State private var hiddenSeries: Set<Int> = []
    @State private var haptic = UISelectionFeedbackGenerator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selected: HoloChartBucket? { buckets.first { $0.id == selection } }
    private func x(_ index: Int) -> Double { buckets[index].position ?? Double(index) }
    private var xDomain: ClosedRange<Double> {
        guard !buckets.isEmpty else { return -0.5...0.5 }
        if let positionDomain { return positionDomain }
        if buckets[0].position != nil {
            let first = x(0), last = x(buckets.count - 1)
            let padding = max((last - first) * 0.015, 1)
            return (first - padding)...(last + padding)
        }
        return -0.5...(Double(buckets.count) - 0.5)
    }
    private var domain: ClosedRange<Double> {
        let plotted = buckets.indices.flatMap { index in series.indices.compactMap { value(at: index, series: $0) } }
        let extras = (baseline.map { [$0] } ?? [])
            + (comparison?.ghostValues.compactMap { $0 } ?? [])
            + rules.map { $0.value }
            + (band.map { [$0.lowerBound, $0.upperBound] } ?? [])
        return yDomain ?? HoloChartGeometry.niceDomain(values: plotted + extras, includesZero: style == .bar)
    }
    private var visibleSeriesIndices: [Int] { series.indices.filter { !hiddenSeries.contains($0) } }
    /// 双轴生效时两个系列的独立坐标域；nil = 未生效回落共轴（非柱状/非双系列/有系列无正数/量级接近）。
    private var splitDomains: [ClosedRange<Double>]? {
        guard dualValueAxes, style == .bar, series.count == 2, yDomain == nil else { return nil }
        let primary = buckets.indices.compactMap { value(at: $0, series: 0) }
        let secondary = buckets.indices.compactMap { value(at: $0, series: 1) }
        guard HoloChartGeometry.shouldSplitDualAxes(primary: primary, secondary: secondary),
              let first = HoloChartGeometry.dualAxisDomain(values: primary),
              let second = HoloChartGeometry.dualAxisDomain(values: secondary) else { return nil }
        return [first, second]
    }
    private var isSplitAxes: Bool { splitDomains != nil }
    private var plotDomain: ClosedRange<Double> { isSplitAxes ? 0...1 : domain }
    /// 绘图值：双轴生效时换算进本系列的 0…1 归一空间；共轴时原值直通。读数与无障碍值仍用真实值。
    private func plotValue(_ raw: Double, series seriesIndex: Int) -> Double {
        guard let domains = splitDomains, domains.indices.contains(seriesIndex) else { return raw }
        let domain = domains[seriesIndex]
        return (raw - domain.lowerBound) / (domain.upperBound - domain.lowerBound)
    }
    private var dataSignature: [HoloChartBucket] { buckets }
    private var idleValues: [Double?] {
        if let summaryValues { return summaryValues }
        return series.indices.map { index in
            guard !hiddenSeries.contains(index) else { return nil }
            let values = buckets.indices.compactMap { value(at: $0, series: index) }
            guard !values.isEmpty else { return nil }
            return style == .bar ? values.reduce(0, +) : values.last
        }
    }
    /// 闲置态合计环比徽标（选中具体桶后让位给桶内「上期同期」小字）
    private var idleBadge: (text: String, color: Color)? {
        guard style == .bar, let comparison, selected == nil else { return nil }
        let current = buckets.indices.compactMap { value(at: $0, series: 0) }.reduce(0, +)
        let previous = comparison.ghostValues.compactMap { $0 }.reduce(0, +)
        guard let pct = HoloChartGeometry.deltaPercent(current: current, previous: previous) else { return nil }
        let rising = pct >= 0
        let color: Color = (rising == comparison.risingIsBad) ? .holoChartOutflow : .holoChartInflow
        let arrow = rising ? "▲" : "▼"
        return ("\(arrow) \(String(format: "%.1f", abs(pct)))% · \(comparison.deltaLabel)", color)
    }
    private var selectedComparisonSub: String? {
        guard let comparison, let selectedID = selection,
              let index = buckets.firstIndex(where: { $0.id == selectedID }),
              comparison.ghostValues.indices.contains(index),
              let ghost = comparison.ghostValues[index], ghost.isFinite else { return nil }
        return "\(comparison.ghostLabel) \(valueText(ghost))"
    }
    /// 峰/谷标注位（首个系列；有效点不足 6 个、峰谷同点、或系列被图例藏起时不标）
    private var extremaAnnotations: [(index: Int, isMax: Bool)] {
        guard annotateExtrema, !hiddenSeries.contains(0) || series.count == 1,
              let pair = HoloChartGeometry.extremaIndices(values: buckets.indices.map { value(at: $0, series: 0) }),
              pair.max != pair.min else { return [] }
        return [(pair.max, true), (pair.min, false)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsReadout {
                HoloChartReadout(bucket: selected, series: series, summary: summary,
                                 valueText: valueText, idleValues: idleValues,
                                 hidesIdleValues: hidesIdleValues,
                                 badge: idleBadge, comparisonSub: selectedComparisonSub,
                                 hiddenSeries: hiddenSeries, onOpenDetail: onOpenDetail)
            }
            if buckets.isEmpty {
                Text("暂无可用数据").font(.caption).foregroundStyle(Color.holoToolTextSecondary)
                    .frame(maxWidth: .infinity).frame(height: height)
            } else {
                chart
                if legendToggle, series.count >= 2 {
                    legendRow
                }
            }
        }
        .onChange(of: dataSignature) { _, buckets in
            // 数据一换即重选：默认选中模式跟着新数据的最后一根（否则回到求和读数，
            // 完成率类会重现「百分比相加 >100%」——2026-11-03 真机判读实锤「全部」页 263.5%）
            if defaultSelectsLastBucket {
                let candidates = buckets.filter { !$0.isFuture }
                selection = (candidates.last(where: { $0.values.contains { $0 != nil } }) ?? candidates.last)?.id
            } else {
                selection = nil
            }
        }
        .onChange(of: series.map(\.id)) { _, _ in
            selection = nil
            hiddenSeries.removeAll()
        }
        .onAppear {
            guard defaultSelectsLastBucket, selection == nil else { return }
            let candidates = buckets.filter { !$0.isFuture }
            if let last = candidates.last(where: { $0.values.contains { $0 != nil } }) ?? candidates.last {
                selection = last.id
            }
        }
    }

    private var chart: some View {
        Chart {
            // 区间带垫底（线状）：先画，曲线压在带上
            if let band, style == .line {
                RectangleMark(xStart: .value("带起", xDomain.lowerBound), xEnd: .value("带止", xDomain.upperBound),
                              yStart: .value("带下", band.lowerBound), yEnd: .value("带上", band.upperBound))
                    .foregroundStyle(Color.holoChart1.opacity(0.08))
                    .accessibilityHidden(true)
            }
            // 上期淡影柱（柱状、单系列对照）：显式 yStart=0 并微错位，避免 Swift Charts 把主柱堆叠在淡影柱顶冲出坐标轴
            if style == .bar, let comparison, series.count == 1 {
                ForEach(buckets.indices, id: \.self) { index in
                    if !buckets[index].isFuture,
                       comparison.ghostValues.indices.contains(index),
                       let ghost = comparison.ghostValues[index], ghost.isFinite, ghost > 0 {
                        BarMark(x: .value("时间", x(index) - comparisonBarOffset),
                                yStart: .value("底", 0),
                                yEnd: .value("数值", ghost),
                                width: .fixed(max(barWidth * 0.72, 2)))
                            .foregroundStyle(Color.holoChartStone.opacity(0.38))
                            .cornerRadius(2.5)
                            .accessibilityHidden(true)
                    }
                }
            }
            ForEach(visibleSeriesIndices, id: \.self) { seriesIndex in
                if style == .bar {
                    ForEach(buckets.indices, id: \.self) { index in
                        if !buckets[index].isFuture, let value = value(at: index, series: seriesIndex) {
                            let dimmed = selection != nil && buckets[index].id != selection
                            let xShift = (comparison != nil && series.count == 1) ? comparisonBarOffset : barXOffset(series: seriesIndex)
                            BarMark(x: .value("时间", x(index) + xShift),
                                    yStart: .value("底", 0),
                                    yEnd: .value("数值", plotValue(value, series: seriesIndex)),
                                    width: .fixed(barWidth))
                                .foregroundStyle(series[seriesIndex].color.opacity(dimmed ? 0.42 : 1))
                                .cornerRadius(3)
                                .accessibilityLabel(buckets[index].detail ?? buckets[index].label)
                                .accessibilityValue("\(series[seriesIndex].title) \(valueText(value))")
                        }
                    }
                } else {
                    ForEach(lineSegments(series: seriesIndex), id: \.self) { segment in
                        if series.count == 1, band == nil, segment.count >= 2 {
                            ForEach(segment, id: \.self) { index in
                                if let value = value(at: index, series: seriesIndex) {
                                    AreaMark(x: .value("时间", x(index)),
                                             yStart: .value("底", plotDomain.lowerBound),
                                             yEnd: .value("数值", value),
                                             series: .value("面积分段", "\(seriesIndex)-\(segment[0])"))
                                        .foregroundStyle(
                                            .linearGradient(
                                                colors: [series[seriesIndex].color.opacity(0.14),
                                                         series[seriesIndex].color.opacity(0.0)],
                                                startPoint: .top, endPoint: .bottom
                                            )
                                        )
                                        .interpolationMethod(.linear)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        ForEach(segment, id: \.self) { index in
                            if let value = value(at: index, series: seriesIndex) {
                                LineMark(x: .value("时间", x(index)), y: .value("数值", value),
                                         series: .value("分段", "\(seriesIndex)-\(segment[0])"))
                                    .foregroundStyle(series[seriesIndex].color)
                                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .interpolationMethod(.linear)
                                if segment.count == 1 || buckets.count <= 7 || alwaysShowPoints || buckets[index].id == selection {
                                    PointMark(x: .value("时间", x(index)), y: .value("数值", value))
                                        .foregroundStyle(series[seriesIndex].color)
                                        .symbolSize(buckets[index].id == selection ? 42 : 18)
                                }
                            }
                        }
                    }
                }
            }
            // 峰/谷自动标注（线状、首个系列）：小点 + 带底标签，防网格线穿字
            ForEach(extremaAnnotations, id: \.index) { item in
                if let value = value(at: item.index, series: 0) {
                    PointMark(x: .value("时间", x(item.index)), y: .value("数值", value))
                        .foregroundStyle(series[0].color)
                        .annotation(position: item.isMax ? .top : .bottom, spacing: 4) {
                            Text("\(item.isMax ? "峰" : "谷") \(valueText(value))\(extremaUnit)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.holoToolText)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.holoToolSurface.opacity(0.92)))
                                .accessibilityHidden(true)
                        }
                        .accessibilityLabel("\(item.isMax ? "最高" : "最低") \(valueText(value))\(extremaUnit)")
                }
            }
            if let baseline {
                RuleMark(y: .value("参考值", baseline))
                    .foregroundStyle(Color.holoToolTextSecondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let index = buckets.firstIndex(where: { $0.id == selection }) {
                RuleMark(x: .value("选中位置", x(index)))
                    .foregroundStyle(Color.holoToolTextSecondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            // 柱状参考线（预算上限/均值）：恒显标签，带底色防压字
            if style == .bar {
                ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                    RuleMark(y: .value("参考线", rule.value))
                        .foregroundStyle(rule.color.opacity(0.9))
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        .annotation(position: .top, alignment: .trailing, spacing: 2) {
                            Text(rule.label)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(rule.color)
                                .padding(.horizontal, 4)
                                .background(Capsule().fill(Color.holoToolSurface.opacity(0.92)))
                                .accessibilityHidden(true)
                        }
                        .accessibilityLabel(rule.label)
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: plotDomain, range: .plotDimension(startPadding: 6, endPadding: 6))
        .chartXAxis(.hidden)
        .chartLegend(.hidden)
        .chartYAxis {
            // 双轴时刻度带由 dualAxisStrips 自绘（两条轴、各自换算），原生轴隐藏。
            if !isSplitAxes {
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
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let plot = geometry[anchor]
                    Color.clear.preference(key: HoloChartPlotFrameKey.self,
                        value: plot.offsetBy(dx: geometry.frame(in: .global).minX, dy: geometry.frame(in: .global).minY))
                        .allowsHitTesting(false)
                    // 装饰层不接收触摸；轴带的高度由本组件预留。
                    tickLabels(proxy: proxy, plot: plot).allowsHitTesting(false)
                    if let band, style == .line, let yTop = proxy.position(forY: band.upperBound) {
                        Text("正常区间 \(HoloChartFormat.number(band.lowerBound))–\(HoloChartFormat.number(band.upperBound))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.holoToolTextSecondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.holoToolSurface.opacity(0.88)))
                            .position(x: plot.maxX - 72, y: min(max(yTop + 12, plot.minY + 10), plot.maxY - 8))
                            .allowsHitTesting(false)
                    }
                    if isSplitAxes {
                        dualAxisStrips(plot: plot).allowsHitTesting(false)
                    }
                    DirectionalChartGestureOverlay(
                        onChanged: { point in inspect(point, proxy: proxy, plot: plot, clamped: true) },
                        onEnded: { _ in }, onCancelled: {},
                        onTap: { point in inspect(point, proxy: proxy, plot: plot, clamped: false) }
                    )
                    .accessibilityElement()
                    .accessibilityLabel("图表选中位置")
                    .accessibilityValue(selection ?? "未选中")
                    .accessibilityIdentifier("holo.chart.interaction")
                    .frame(width: plot.width, height: plot.height)
                    .position(x: plot.midX, y: plot.midY)
                    .onAppear { plotWidth = plot.width }
                    .onChange(of: plot.width) { _, width in plotWidth = width }
                }
            }
        }
        .frame(height: height)
        .padding(.horizontal, isSplitAxes ? 36 : 0)
        .padding(.bottom, axisSize + 12)
        .accessibilityIdentifier("holo.chart.plot")
        .accessibilityAdjustableAction { direction in
            let index = buckets.firstIndex { $0.id == selection } ?? -1
            let next = direction == .increment ? index + 1 : index - 1
            if buckets.indices.contains(next), !buckets[next].isFuture { select(next) }
        }
    }

    private func value(at index: Int, series: Int) -> Double? {
        buckets[index].value(forSeries: series)
    }

    private var barWidth: CGFloat {
        HoloChartGeometry.barWidth(plotWidth: plotWidth, count: buckets.count, seriesCount: series.count)
    }

    /// 单系列带上期淡影时，淡影与主柱各向左右错开约 1/3 柱宽，既不完全遮挡也不被 Swift Charts 当同 x 堆叠
    private var comparisonBarOffset: Double {
        let points = barWidth * 0.32
        return Double(points) * (xDomain.upperBound - xDomain.lowerBound) / Double(max(plotWidth, 1))
    }

    /// 多系列柱并排：组内 pt 偏移换算成 x 数据单位（x 轴无内边距，域宽 ÷ 绘图区宽即换算比）。
    /// position(by:) 在数值轴上不分组、退回堆叠，并排只能自行错开 x
    private func barXOffset(series seriesIndex: Int) -> Double {
        let points = HoloChartGeometry.seriesOffset(seriesIndex: seriesIndex, seriesCount: series.count, barWidth: barWidth)
        guard points != 0 else { return 0 }
        return Double(points) * (xDomain.upperBound - xDomain.lowerBound) / Double(max(plotWidth, 1))
    }

    private func lineSegments(series: Int) -> [[Int]] {
        HoloChartGeometry.contiguousSegments(valid: buckets.indices.map { value(at: $0, series: series) != nil })
    }

    private func inspect(_ point: CGPoint, proxy: ChartProxy, plot: CGRect, clamped: Bool) {
        // 覆盖层本身已限定在绘图区，回调坐标就是绘图区坐标，不再重复减轴带。
        guard clamped || (point.x >= 0 && point.x <= plot.width && point.y >= 0 && point.y <= plot.height) else { return }
        let positions = buckets.indices.map { proxy.position(forX: x($0)) ?? .infinity }
        guard let index = HoloChartGeometry.nearestIndex(x: min(max(point.x, 0), plot.width), positions: positions),
              !buckets[index].isFuture else { return }
        select(index, userDriven: true)
    }

    /// 选中身份一变轻嗒一次（仅用户驱动；程序性初始选中不出声）
    private func select(_ index: Int, userDriven: Bool = false) {
        guard selection != buckets[index].id else { return }
        selection = buckets[index].id
        if userDriven { haptic.selectionChanged() }
        onInspect?(buckets[index])
    }

    /// 图例开关胶囊：点选暂时藏起一个系列（至少留一个）
    private var legendRow: some View {
        HStack(spacing: 8) {
            ForEach(series.indices, id: \.self) { index in
                let hidden = hiddenSeries.contains(index)
                Button {
                    guard !(hidden && visibleSeriesIndices.count <= 1) else { return }
                    if hidden { hiddenSeries.remove(index) } else { hiddenSeries.insert(index) }
                    haptic.selectionChanged()
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(hidden ? Color.holoToolTextSecondary : series[index].color)
                            .frame(width: 8, height: 8)
                        Text(series[index].title).font(.caption)
                    }
                    .foregroundStyle(Color.holoToolText)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Color.holoToolInset).opacity(hidden ? 0.5 : 1))
                    .opacity(hidden ? 0.55 : 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(series[index].title)\(hidden ? "（已隐藏）" : "")")
                .accessibilityAddTraits(.isButton)
            }
        }
    }

    private struct TickLabel: Identifiable {
        let id: Int
        let text: String
        let alignment: Alignment
        let anchorX: CGFloat
    }

    /// 月界锚定标签（.dayWithMonthAnchor）：被选刻度里首根或与前一被选刻度跨月时显「M.d」，
    /// 其余只显日数。date 缺失的桶退回 bucket.label；非该口径返回空表，取值处 `?? label` 兜底。
    private func monthAnchoredLabels(for indices: [Int]) -> [Int: String] {
        guard xAxisTickStyle == .dayWithMonthAnchor else { return [:] }
        var result: [Int: String] = [:]
        var previousDate: Date?
        for index in indices where buckets.indices.contains(index) {
            guard let date = buckets[index].date else { continue }
            if let previousDate,
               Calendar.current.isDate(date, equalTo: previousDate, toGranularity: .month) {
                result[index] = HoloChartFormat.date(date, template: "d")
            } else {
                result[index] = HoloChartFormat.date(date, template: "Md")
            }
            previousDate = date
        }
        return result
    }

    private func tickLabels(proxy: ChartProxy, plot: CGRect) -> some View {
        let labelWidth = HoloChartGeometry.tickLabelWidth(plotWidth: plot.width)
        if let slotTicks {
            // 槽位标签一律对准柱中心；槽太窄导致首尾标签出血时才退回贴边
            let slotWidth = buckets.isEmpty ? plot.width : plot.width / CGFloat(buckets.count)
            let edgeSafe = slotWidth >= labelWidth
            let anchored = monthAnchoredLabels(for: slotTicks)
            let labels = slotTicks.compactMap { index -> TickLabel? in
                guard buckets.indices.contains(index) else { return nil }
                let center = buckets.count > 1
                    ? plot.minX + plot.width * (CGFloat(index) + 0.5) / CGFloat(buckets.count)
                    : plot.midX
                if !edgeSafe, slotTicks.count > 1, index == slotTicks.first {
                    return TickLabel(id: index, text: anchored[index] ?? buckets[index].label, alignment: .leading,
                                     anchorX: plot.minX + labelWidth / 2)
                }
                if !edgeSafe, slotTicks.count > 1, index == slotTicks.last {
                    return TickLabel(id: index, text: anchored[index] ?? buckets[index].label, alignment: .trailing,
                                     anchorX: plot.maxX - labelWidth / 2)
                }
                return TickLabel(id: index, text: anchored[index] ?? buckets[index].label, alignment: .center, anchorX: center)
            }
            return AnyView(ForEach(labels) { label in
                Text(label.text)
                    .font(.system(size: axisSize)).foregroundStyle(Color.holoToolTextSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: labelWidth, alignment: label.alignment)
                    .position(x: label.anchorX, y: plot.maxY + axisSize / 2 + 7)
            })
        }
        if let positionTicks {
            let labels = positionTicks.enumerated().compactMap { index, tick -> TickLabel? in
                guard let pixel = proxy.position(forX: tick.position) else { return nil }
                if positionTicks.count > 1 && index == 0 {
                    return TickLabel(id: index, text: tick.label, alignment: .leading, anchorX: plot.minX + labelWidth / 2)
                }
                if positionTicks.count > 1 && index == positionTicks.count - 1 {
                    return TickLabel(id: index, text: tick.label, alignment: .trailing, anchorX: plot.maxX - labelWidth / 2)
                }
                return TickLabel(id: index, text: tick.label, alignment: .center, anchorX: plot.minX + pixel)
            }
            return AnyView(ForEach(labels) { label in
                Text(label.text)
                    .font(.system(size: axisSize)).foregroundStyle(Color.holoToolTextSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: labelWidth, alignment: label.alignment)
                    .position(x: label.anchorX, y: plot.maxY + axisSize / 2 + 7)
            })
        }
        let pixelX = buckets.indices.map { proxy.position(forX: x($0)) ?? .infinity }
        // position 域（连续时间，如测量记录点）按像素最小间距选刻度；等宽槽位按预算等分
        let picked: [Int]
        if buckets.first?.position != nil {
            picked = HoloChartGeometry.tickIndicesForPositions(pixelPositions: pixelX, minSpacing: labelWidth)
        } else if buckets.count <= 8, plot.width >= CGFloat(buckets.count) * 36,
                  buckets.allSatisfy({ $0.label.count <= 3 }) {
            // ≤8 桶且全是「1日」「8月」这类短标签时全显，不抽掉中间日/月（修复画廊与周/半年视图缺 3日/8月）
            picked = Array(buckets.indices)
        } else {
            picked = HoloChartGeometry.tickIndices(count: buckets.count, width: plot.width)
        }
        let anchored = monthAnchoredLabels(for: picked)
        let labels = picked.compactMap { index -> TickLabel? in
            guard pixelX.indices.contains(index), pixelX[index].isFinite else { return nil }
            let alignment: Alignment
            let anchorX: CGFloat
            if index == picked.first {
                // 首尾贴边对齐：不再向图内钳位，端点标签不会压到邻居
                alignment = .leading
                anchorX = plot.minX + labelWidth / 2
            } else if index == picked.last {
                alignment = .trailing
                anchorX = plot.maxX - labelWidth / 2
            } else {
                alignment = .center
                anchorX = plot.minX + pixelX[index]
            }
            return TickLabel(id: index, text: anchored[index] ?? buckets[index].label, alignment: alignment, anchorX: anchorX)
        }
        return AnyView(ForEach(labels) { label in
            Text(label.text)
                .font(.system(size: axisSize)).foregroundStyle(Color.holoToolTextSecondary)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: labelWidth, alignment: label.alignment)
                .position(x: label.anchorX, y: plot.maxY + axisSize / 2 + 7)
        })
    }

    /// 双轴刻度带：右轴=第 0 系列、左轴=第 1 系列，各取 0 / 半值 / 顶值三档——两个系列的
    /// 这三档位于同一比例位置，网格线可共用；数值按各自坐标域换算，刻度颜色随系列色，
    /// 表达「哪根柱子看哪条轴」。标签画在绘图区两侧，空间由 horizontal padding 预留。
    private func dualAxisStrips(plot: CGRect) -> some View {
        let domains = splitDomains ?? []
        return ZStack {
            ForEach([0.0, 0.5, 1.0], id: \.self) { fraction in
                let y = plot.maxY - fraction * plot.height
                Rectangle()
                    .fill(Color.holoToolBorder.opacity(0.6))
                    .frame(width: plot.width, height: 0.5)
                    .position(x: plot.midX, y: y)
                dualAxisLabel(domainIndex: 0, fraction: fraction, domains: domains)
                    .frame(width: 32, alignment: .leading)
                    .position(x: plot.maxX + 20, y: y)
                dualAxisLabel(domainIndex: 1, fraction: fraction, domains: domains)
                    .frame(width: 32, alignment: .trailing)
                    .position(x: plot.minX - 20, y: y)
            }
        }
    }

    private func dualAxisLabel(domainIndex: Int, fraction: Double, domains: [ClosedRange<Double>]) -> some View {
        guard domains.indices.contains(domainIndex) else { return AnyView(EmptyView()) }
        let domain = domains[domainIndex]
        let value = domain.lowerBound + (domain.upperBound - domain.lowerBound) * fraction
        return AnyView(
            Text(HoloChartFormat.axisNumber(value))
                .font(.system(size: axisSize))
                .foregroundStyle(series[domainIndex].color)
                .lineLimit(1).minimumScaleFactor(0.8)
        )
    }
}

struct HoloChartReadout: View {
    let bucket: HoloChartBucket?
    let series: [HoloChartSeries]
    let summary: String
    let valueText: (Double) -> String
    let idleValues: [Double?]
    var hidesIdleValues = false
    var badge: (text: String, color: Color)? = nil
    var comparisonSub: String? = nil
    var hiddenSeries: Set<Int> = []
    let onOpenDetail: ((HoloChartBucket) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(bucket.map { $0.detail ?? $0.label } ?? summary)
                    .font(.caption).foregroundStyle(Color.holoToolTextSecondary)
                Spacer(minLength: 4)
                if let bucket, let onOpenDetail {
                    Button("查看明细") { onOpenDetail(bucket) }
                        .font(.caption).foregroundStyle(Color.holoToolAction).frame(minHeight: 44)
                }
            }.frame(minHeight: 44)
            if hidesIdleValues && bucket == nil {
                // 未选中时 idle 读数（末桶值/合计）与曲线不对应，不给伪读数，summary 文案承担提示
                EmptyView()
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) { values }
                    VStack(alignment: .leading, spacing: 4) { values }
                }
            }
        }
        .frame(minHeight: 56, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("holo.chart.readout")
    }

    @ViewBuilder private var values: some View {
        ForEach(series.indices, id: \.self) { index in
            if !hiddenSeries.contains(index) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Circle().fill(series[index].color).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(series[index].title).font(.caption).foregroundStyle(Color.holoToolTextSecondary)
                    Text(text(index)).font(series.count == 1 ? .title2.weight(.semibold) : .headline)
                        .foregroundStyle(Color.holoToolText).monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: text(index))
                    if index == 0, bucket != nil, let comparisonSub {
                        Text(comparisonSub).font(.caption2).foregroundStyle(Color.holoToolTextSecondary)
                    }
                }
            }
        }
        if bucket == nil, let badge {
            Text(badge.text)
                .font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(badge.color)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 6).fill(badge.color.opacity(0.10)))
        }
    }

    private func text(_ index: Int) -> String {
        if bucket?.isFuture == true || bucket?.futureSeries.contains(index) == true { return "未到来" }
        let values = bucket?.values ?? idleValues
        guard values.indices.contains(index), let value = values[index], value.isFinite else { return "无记录" }
        return valueText(value)
    }
}
