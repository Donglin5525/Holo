import SwiftUI
import Charts

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

    func value(forSeries index: Int) -> Double? {
        guard !isFuture, !futureSeries.contains(index), values.indices.contains(index),
              let value = values[index], value.isFinite else { return nil }
        return value
    }
}

enum HoloChartFormat {
    private static let shortDate = formatter("Md")
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
struct HoloChartFrame<Content: View>: View {
    var title: String = ""
    var subtitle: String = ""
    var independent = false
    var state: HoloChartState = .ready
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
                Text(message).font(.subheadline).foregroundStyle(Color.holoToolTextSecondary)
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
    var onInspect: ((HoloChartBucket) -> Void)? = nil
    var onOpenDetail: ((HoloChartBucket) -> Void)? = nil

    var body: some View {
        HoloCartesianChart(buckets: buckets, series: series, selection: $selection, style: .line,
                           height: height, yDomain: yDomain, baseline: baseline, summary: summary,
                           summaryValues: summaryValues, valueText: valueText,
                           defaultSelectsLastBucket: defaultSelectsLastBucket, showsReadout: showsReadout,
                           hidesIdleValues: hidesIdleValues, alwaysShowPoints: alwaysShowPoints,
                           positionDomain: positionDomain, positionTicks: positionTicks,
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
    var showsReadout = true
    var hidesIdleValues = false
    /// 折线每个数据点恒显（测量记录点视图：点即数据）
    var alwaysShowPoints = false
    var positionDomain: ClosedRange<Double>? = nil
    var positionTicks: [HoloChartTick]? = nil
    var onInspect: ((HoloChartBucket) -> Void)?
    var onOpenDetail: ((HoloChartBucket) -> Void)?
    @State private var plotWidth: CGFloat = 300
    @ScaledMetric(relativeTo: .caption2) private var axisSize: CGFloat = 11

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
        yDomain ?? HoloChartGeometry.niceDomain(
            values: buckets.indices.flatMap { index in series.indices.compactMap { value(at: index, series: $0) } }
                + (baseline.map { [$0] } ?? []),
            includesZero: style == .bar)
    }
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
        summaryValues ?? series.indices.map { index in
            let values = buckets.indices.compactMap { value(at: $0, series: index) }
            guard !values.isEmpty else { return nil }
            return style == .bar ? values.reduce(0, +) : values.last
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsReadout {
                HoloChartReadout(bucket: selected, series: series, summary: summary,
                                 valueText: valueText, idleValues: idleValues,
                                 hidesIdleValues: hidesIdleValues, onOpenDetail: onOpenDetail)
            }
            if buckets.isEmpty {
                Text("暂无可用数据").font(.caption).foregroundStyle(Color.holoToolTextSecondary)
                    .frame(maxWidth: .infinity).frame(height: height)
            } else {
                chart
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
        .onChange(of: series.map(\.id)) { _, _ in selection = nil }
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
            ForEach(series.indices, id: \.self) { seriesIndex in
                if style == .bar {
                    ForEach(buckets.indices, id: \.self) { index in
                        if !buckets[index].isFuture, let value = value(at: index, series: seriesIndex) {
                            BarMark(x: .value("时间", x(index) + barXOffset(series: seriesIndex)),
                                    y: .value("数值", plotValue(value, series: seriesIndex)),
                                    width: .fixed(barWidth))
                                .foregroundStyle(series[seriesIndex].color)
                                .cornerRadius(3)
                                .accessibilityLabel(buckets[index].detail ?? buckets[index].label)
                                .accessibilityValue("\(series[seriesIndex].title) \(valueText(value))")
                        }
                    }
                } else {
                    ForEach(lineSegments(series: seriesIndex), id: \.self) { segment in
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
        select(index)
    }

    private func select(_ index: Int) {
        guard selection != buckets[index].id else { return }
        selection = buckets[index].id
        onInspect?(buckets[index])
    }

    private struct TickLabel: Identifiable {
        let id: Int
        let text: String
        let alignment: Alignment
        let anchorX: CGFloat
    }

    private func tickLabels(proxy: ChartProxy, plot: CGRect) -> some View {
        let labelWidth = HoloChartGeometry.tickLabelWidth(plotWidth: plot.width)
        if let slotTicks {
            let labels = slotTicks.compactMap { index -> TickLabel? in
                guard buckets.indices.contains(index) else { return nil }
                if slotTicks.count > 1 && index == slotTicks.first {
                    return TickLabel(id: index, text: buckets[index].label, alignment: .leading,
                                     anchorX: plot.minX + labelWidth / 2)
                }
                if slotTicks.count > 1 && index == slotTicks.last {
                    return TickLabel(id: index, text: buckets[index].label, alignment: .trailing,
                                     anchorX: plot.maxX - labelWidth / 2)
                }
                let center = buckets.indices.count > 1
                    ? plot.minX + plot.width * (CGFloat(index) + 0.5) / CGFloat(buckets.count)
                    : plot.midX
                return TickLabel(id: index, text: buckets[index].label, alignment: .center, anchorX: center)
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
        } else {
            picked = HoloChartGeometry.tickIndices(count: buckets.count, width: plot.width)
        }
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
            return TickLabel(id: index, text: buckets[index].label, alignment: alignment, anchorX: anchorX)
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

private struct HoloChartReadout: View {
    let bucket: HoloChartBucket?
    let series: [HoloChartSeries]
    let summary: String
    let valueText: (Double) -> String
    let idleValues: [Double?]
    var hidesIdleValues = false
    let onOpenDetail: ((HoloChartBucket) -> Void)?

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
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Circle().fill(series[index].color).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(series[index].title).font(.caption).foregroundStyle(Color.holoToolTextSecondary)
                Text(text(index)).font(series.count == 1 ? .title2.weight(.semibold) : .headline)
                    .foregroundStyle(Color.holoToolText).monospacedDigit()
            }
        }
    }

    private func text(_ index: Int) -> String {
        if bucket?.isFuture == true || bucket?.futureSeries.contains(index) == true { return "未到来" }
        let values = bucket?.values ?? idleValues
        guard values.indices.contains(index), let value = values[index], value.isFinite else { return "无记录" }
        return valueText(value)
    }
}
