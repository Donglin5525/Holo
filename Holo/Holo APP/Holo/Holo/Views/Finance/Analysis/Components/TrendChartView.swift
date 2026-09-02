//
//  TrendChartView.swift
//  Holo
//
//  总览 Tab 趋势卡（双轴同图·资产总览风格）：
//  - 下层：每日收支柱（红=支出、绿=收入）贴底，走左轴；当日最大支出日整柱高亮
//  - 上层：余额线（冷蓝，独立刻度）走右轴，两根轴都标刻度，明着双尺不误导
//  - 极淡横向网格只铺柱区；余额信息另外在卡头「较期初」与点按明细里可读
//  - 单日尖峰超过次高值 2 倍且有效天数 ≥5 时，柱轴上限压缩并对尖峰柱做「断口」截断
//  - 横向拖动/点按查看单日（柱后高亮带 + 明细），纵向手势交还页面滚动，点空白收起
//

import SwiftUI
import Charts

// MARK: - TrendChartView

/// 总览趋势卡（收支柱 + 余额线双轴同图）
struct TrendChartView: View {
    let dataPoints: [ChartDataPoint]

    @State private var hoveredIndex: Int? = nil

    // MARK: 画布几何（y 抽象单位，domain [0, plotUnitMax]，值越大越靠上）
    private let plotUnitMax: Double = 100
    private let barTopUnit: Double = 55          // 柱带：0...55（柱轴上限映射到 55）
    private let lineBandLow: Double = 62         // 线带：62...95（余额最小值→62，最大值→95）
    private let lineBandHigh: Double = 95
    private let breakZoneHeight: Double = 6      // 断口区：主柱顶与小帽之间的留白
    private let barOffsetUnits: Double = 0.29    // 支出/收入柱相对当天中线的偏移（x 单位）
    private let restBarOpacity: Double = 0.78    // 非峰值日柱子透明度（峰值日实色高亮）

    private var allValuesZero: Bool {
        dataPoints.allSatisfy { $0.expense == 0 && $0.income == 0 && $0.balance == 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            chartLegend

            if dataPoints.isEmpty || allValuesZero {
                emptyChartView
            } else {
                chartContent
            }
        }
        .padding(HoloSpacing.md)
        .holoCard()
    }

    // MARK: 图例（右侧：余额较期初变化）

    private var chartLegend: some View {
        HStack(spacing: HoloSpacing.lg) {
            LegendItem(color: .holoError, label: "支出")
            LegendItem(color: .holoSuccess, label: "收入")
            LegendItem(color: .holoChart1, label: "余额")
            Spacer()
            if let delta = balanceDelta {
                Text("余额较期初 \(delta > 0 ? "+" : "-")\(NumberFormatter.compactCurrency(abs(delta)))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(delta > 0 ? .holoSuccessDark : .holoError)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .fixedSize()
            }
        }
    }

    private var balanceDelta: Decimal? {
        guard dataPoints.count > 1, let first = dataPoints.first, let last = dataPoints.last else { return nil }
        let delta = last.balance - first.balance
        return delta == 0 ? nil : delta
    }

    // MARK: 图表组装

    private var chartContent: some View {
        let plan = barAxisPlan
        let range = balanceValueRange
        let balanceTicks = self.balanceTicks(range: range)
        let peakDay = peakDayIndex

        return trendChart(cap: plan.cap, clippedIndices: plan.clippedIndices,
                          peakDayIndex: peakDay, balanceTicks: balanceTicks)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    let overlayFrame = geometry.frame(in: .local)
                    let plotFrame = proxy.plotFrame.map { geometry[$0] }

                    // —— 触摸当日：柱后淡色高亮带 ——
                    // position(forX/Y:) 返回的是绘图区（plot area）内坐标，作为全图 overlay 坐标使用时必须补回 plotFrame 偏移，
                    // 否则高亮带/气泡整体左移一个 Y 轴刻度栏宽（≈3 天），看起来「不跟手、有错位」
                    if let index = hoveredIndex,
                       let slotXPos = proxy.position(forX: Double(index)), let plotFrame {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.holoTextPrimary.opacity(0.05))
                            .frame(width: plotFrame.width / CGFloat(dataPoints.count), height: plotFrame.height)
                            .position(x: plotFrame.minX + slotXPos, y: plotFrame.midY)
                    }

                    // —— 断口截断标注 ——
                    if let plotFrame {
                        ForEach(plan.clippedIndices, id: \.self) { index in
                            if let capTopY = proxy.position(forY: barTopUnit),
                               let barXPos = proxy.position(forX: breakBarX(index)) {
                                clippedBreakAnnotations(
                                    capTopY: plotFrame.minY + capTopY,
                                    barXPos: plotFrame.minX + barXPos,
                                    amountLabel: Self.axisAmountLabel(clippedAmount(index))
                                )
                            }
                        }
                    }

                    // —— 触摸手势：拖动/点按查看单日，纵向手势交还页面滚动 ——
                    DirectionalChartGestureOverlay(
                        onChanged: { location in
                            hoveredIndex = touchedIndex(location, proxy: proxy, plotFrame: plotFrame) ?? hoveredIndex
                        },
                        onEnded: { _ in
                            hoveredIndex = nil
                        },
                        onCancelled: {
                            hoveredIndex = nil
                        },
                        onTap: { location in
                            hoveredIndex = touchedIndex(location, proxy: proxy, plotFrame: plotFrame)
                        }
                    )

                    // —— 触摸态：明细 tooltip ——
                    if let index = hoveredIndex,
                       let anchorXPos = proxy.position(forX: Double(index)), let plotFrame {
                        amountTooltip(
                            point: dataPoints[index],
                            dateLabel: ChartTooltipDateLabel.string(for: dataPoints[index], points: dataPoints),
                            x: min(max(plotFrame.minX + anchorXPos, 60), overlayFrame.width - 60),
                            y: min(max(plotFrame.minY + plotFrame.height * 0.14, 16), overlayFrame.height - 16)
                        )
                    }
                }
            }
            .frame(height: 200)
    }

    private func trendChart(cap: Double, clippedIndices: [Int],
                            peakDayIndex: Int?, balanceTicks: [(unit: Double, label: String)]) -> some View {
        Chart {
            ForEach(dataPoints.indices, id: \.self) { index in
                flowBars(
                    index,
                    dataPoints[index],
                    cap: cap,
                    isPeakDay: index == peakDayIndex,
                    isClipped: clippedIndices.contains(index)
                )
            }
            ForEach(dataPoints.indices, id: \.self) { index in
                balanceLine(index, dataPoints[index])
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...plotUnitMax)
        .chartXAxis {
            AxisMarks(values: xAxisTickValues) { value in
                AxisValueLabel {
                    if let axisValue = value.as(Double.self) {
                        Text(tickLabel(axisValue))
                            .font(.system(size: 10))
                            .foregroundStyle(Color.holoTextSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            // 左轴：收支柱刻度（含 0 基线网格）
            AxisMarks(position: .leading, values: [0.0, barY(cap * 0.5, cap: cap), barY(cap, cap: cap)]) { value in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider.opacity(0.7))
                AxisValueLabel {
                    if let axisValue = value.as(Double.self) {
                        Text(Self.axisAmountLabel(axisValue / barTopUnit * cap))
                            .font(.system(size: 9))
                            .foregroundStyle(Color.holoTextPlaceholder)
                    }
                }
            }
            // 右轴：余额刻度（只标数值，不画线）
            AxisMarks(position: .trailing, values: balanceTicks.map { $0.unit }) { value in
                AxisValueLabel {
                    if let axisValue = value.as(Double.self) {
                        Text(balanceTickLabel(axisValue, ticks: balanceTicks))
                            .font(.system(size: 9))
                            .foregroundStyle(Color.holoChart1.opacity(0.75))
                    }
                }
            }
        }
        .chartPlotStyle { plotArea in
            plotArea
                .padding(.leading, 2)
                .padding(.trailing, 2)
        }
    }

    /// 某天的支出/收入成对柱；峰值日整柱实色高亮；截断柱画「断口」：主柱 + 留白 + 小帽
    @ChartContentBuilder
    private func flowBars(_ index: Int, _ point: ChartDataPoint, cap: Double, isPeakDay: Bool, isClipped: Bool) -> some ChartContent {
        let expenseVal = Double(truncating: point.expense as NSDecimalNumber)
        let incomeVal = Double(truncating: point.income as NSDecimalNumber)
        let opacity = isPeakDay ? 1.0 : restBarOpacity

        flowBar(x: Double(index) - barOffsetUnits, value: expenseVal, cap: cap,
                color: .holoError, opacity: opacity, isClipped: isClipped && expenseVal >= incomeVal)
        flowBar(x: Double(index) + barOffsetUnits, value: incomeVal, cap: cap,
                color: .holoSuccess, opacity: opacity, isClipped: isClipped && incomeVal > expenseVal)
    }

    @ChartContentBuilder
    private func flowBar(x: Double, value: Double, cap: Double, color: Color, opacity: Double, isClipped: Bool) -> some ChartContent {
        if value > 0 {
            if isClipped {
                BarMark(
                    x: .value("日期", x),
                    yStart: .value("起点", 0.0),
                    yEnd: .value("金额", barTopUnit - breakZoneHeight),
                    width: .fixed(barWidth)
                )
                .cornerRadius(2)
                .foregroundStyle(color.opacity(opacity))

                BarMark(
                    x: .value("日期", x),
                    yStart: .value("起点", barTopUnit - 3),
                    yEnd: .value("金额", barTopUnit),
                    width: .fixed(barWidth)
                )
                .cornerRadius(1.5)
                .foregroundStyle(color.opacity(opacity))
            } else {
                BarMark(
                    x: .value("日期", x),
                    yStart: .value("起点", 0.0),
                    yEnd: .value("金额", barY(value, cap: cap)),
                    width: .fixed(barWidth)
                )
                .cornerRadius(2)
                .foregroundStyle(color.opacity(opacity))
            }
        }
    }

    /// 余额线（冷蓝，独立刻度映射到上层条带）
    @ChartContentBuilder
    private func balanceLine(_ index: Int, _ point: ChartDataPoint) -> some ChartContent {
        let balanceVal = Double(truncating: point.balance as NSDecimalNumber)
        LineMark(
            x: .value("日期", Double(index)),
            y: .value("余额", lineY(balanceVal)),
            series: .value("余额", "余额")
        )
        .interpolationMethod(.monotone)
        .foregroundStyle(Color.holoChart1)
        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    // MARK: 断口标注（只接收坐标结果）

    /// 断口柱的 x 位置（x 单位）
    private func breakBarX(_ index: Int) -> Double {
        let point = dataPoints[index]
        let expenseVal = Double(truncating: point.expense as NSDecimalNumber)
        let incomeVal = Double(truncating: point.income as NSDecimalNumber)
        return Double(index) + (incomeVal > expenseVal ? barOffsetUnits : -barOffsetUnits)
    }

    /// 断口柱的真实金额
    private func clippedAmount(_ index: Int) -> Double {
        let point = dataPoints[index]
        return max(
            Double(truncating: point.expense as NSDecimalNumber),
            Double(truncating: point.income as NSDecimalNumber)
        )
    }

    /// 断口：白色斜杠两道 + 左侧真实值标注
    @ViewBuilder
    private func clippedBreakAnnotations(capTopY: CGFloat, barXPos: CGFloat, amountLabel: String) -> some View {
        ForEach(0..<2, id: \.self) { slashIndex in
            Capsule()
                .fill(Color.white)
                .frame(width: 9, height: 1.8)
                .rotationEffect(.degrees(-24))
                .position(x: barXPos, y: capTopY - breakZoneHeight / 2 + (slashIndex == 0 ? -1.8 : 1.8))
        }

        Text(amountLabel)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.holoSuccessDark)
            .frame(width: 44, alignment: .trailing)
            .position(x: barXPos - barWidth / 2 - 3, y: capTopY + 9)
    }

    // MARK: 数值换算

    private var barWidth: CGFloat {
        dataPoints.count > 14 ? 4.2 : 8
    }

    private var xDomain: ClosedRange<Double> {
        let upper = Double(max(dataPoints.count - 1, 0)) + 0.5
        return -0.5...upper
    }

    private var xAxisTickValues: [Double] {
        axisLabelIndices.map { Double($0.index) }
    }

    private func tickLabel(_ axisValue: Double) -> String {
        let dataIndex = Int(axisValue.rounded())
        guard dataIndex < dataPoints.count else { return "" }
        return dataPoints[dataIndex].label
    }

    private func balanceValue(_ point: ChartDataPoint) -> Double {
        Double(truncating: point.balance as NSDecimalNumber)
    }

    private var balanceValueRange: ClosedRange<Double> {
        let values = dataPoints.map(balanceValue)
        let lower = values.min() ?? 0
        return lower...max(values.max() ?? 1, lower + 1)
    }

    /// 余额线映射到上层条带（全幅极值归一化）
    private func lineY(_ balance: Double, range: ClosedRange<Double>) -> Double {
        guard range.upperBound > range.lowerBound else { return (lineBandLow + lineBandHigh) / 2 }
        let t = (balance - range.lowerBound) / (range.upperBound - range.lowerBound)
        return lineBandLow + t * (lineBandHigh - lineBandLow)
    }

    private func lineY(_ balance: Double) -> Double {
        lineY(balance, range: balanceValueRange)
    }

    /// 右轴余额刻度：最小 / 中位 / 最大 三档（走平时期合并为单档）
    private func balanceTicks(range: ClosedRange<Double>) -> [(unit: Double, label: String)] {
        if range.upperBound - range.lowerBound < 0.01 {
            return [(lineY(range.lowerBound, range: range), Self.axisAmountLabel(range.lowerBound))]
        }
        let values = [range.lowerBound, (range.lowerBound + range.upperBound) / 2, range.upperBound]
        return values.map { (lineY($0, range: range), Self.axisAmountLabel($0)) }
    }

    private func balanceTickLabel(_ axisValue: Double, ticks: [(unit: Double, label: String)]) -> String {
        ticks.first { abs($0.unit - axisValue) < 0.01 }?.label ?? ""
    }

    /// 数据点多（>14）时 X 轴稀疏展示（最多 6 个）
    private var axisLabelIndices: [(index: Int, label: String)] {
        let count = dataPoints.count
        guard count > 0 else { return [] }
        guard count > 14 else { return (0..<count).map { ($0, dataPoints[$0].label) } }
        let desiredCount = 6
        let lastIndex = count - 1
        let step = max(Double(lastIndex) / Double(desiredCount - 1), 1)
        return (0..<desiredCount).compactMap { stepIndex in
            let dataIndex = min(Int((Double(stepIndex) * step).rounded()), lastIndex)
            return (dataIndex, dataPoints[dataIndex].label)
        }
    }

    private func touchedIndex(_ location: CGPoint, proxy: ChartProxy, plotFrame: CGRect?) -> Int? {
        guard !dataPoints.isEmpty, let plotFrame else { return nil }
        let touchXInPlot = location.x - plotFrame.minX
        let pointPositions = dataPoints.indices.compactMap { proxy.position(forX: Double($0)) }
        return ChartTouchSelection.nearestPointIndex(
            touchXInPlot: touchXInPlot,
            plotWidth: plotFrame.width,
            pointXPositions: pointPositions
        )
    }

    /// 柱轴规划：单日尖峰超过次高值 2 倍时，轴上限压缩到次高值附近并截断尖峰，
    /// 避免一根针毁掉其余天数的纵向比例。
    /// 仅在数据足够密（有效天数 ≥5）时启用——稀疏月份截断最大的一天反而添乱；
    /// 次高值为 0（只有一天有量）时不截断。
    private var barAxisPlan: (cap: Double, clippedIndices: [Int]) {
        let dailyMax = dataPoints.map { point -> Double in
            max(
                Double(truncating: point.expense as NSDecimalNumber),
                Double(truncating: point.income as NSDecimalNumber)
            )
        }
        guard let maxAll = dailyMax.max(), maxAll > 0 else { return (1, []) }
        let secondMax = dailyMax.sorted(by: >).dropFirst().first ?? 0
        let activeDays = dailyMax.filter { $0 > 0 }.count

        let cap: Double
        if activeDays >= 5, secondMax > 0, maxAll > secondMax * 2 {
            cap = Self.niceCeil(secondMax * 1.25)
        } else {
            cap = Self.niceCeil(maxAll)
        }
        let clipped = dailyMax.enumerated().compactMap { $0.element > cap ? $0.offset : nil }
        return (cap, clipped)
    }

    /// 取「好看」的轴上限：1 / 1.2 / 1.5 / 2 / 2.5 / 3 / 4 / 5 / 6 / 8 / 10 × 10^n
    private static func niceCeil(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        for step in [1.0, 1.2, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0] {
            let candidate = step * magnitude
            if candidate >= value { return candidate }
        }
        return 10 * magnitude
    }

    private func barY(_ value: Double, cap: Double) -> Double {
        min(value, cap) / cap * barTopUnit
    }

    /// 单日双柱里金额更大的那天（峰值日高亮）
    private var peakDayIndex: Int? {
        var bestIndex: Int?
        var bestValue = 0.0
        for (index, point) in dataPoints.enumerated() {
            let dailyMax = max(
                Double(truncating: point.expense as NSDecimalNumber),
                Double(truncating: point.income as NSDecimalNumber)
            )
            if dailyMax > bestValue {
                bestValue = dailyMax
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// 轴刻度金额紧凑口径：万 / 千 / 整数
    private static func axisAmountLabel(_ value: Double) -> String {
        if abs(value) < 1 { return value == 0 ? "0" : "" }
        let absValue = abs(value)
        if absValue >= 10_000 {
            return String(format: "%.1f万", value / 10_000)
        } else if absValue >= 1_000 {
            return String(format: "%.1f千", value / 1_000)
        }
        return String(format: "%.0f", value)
    }

    // MARK: Tooltip

    private func amountTooltip(point: ChartDataPoint, dateLabel: String, x: CGFloat, y: CGFloat) -> some View {
        VStack(spacing: 2) {
            Text(dateLabel)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.holoTextSecondary)
            HStack(spacing: 6) {
                if point.expense > 0 {
                    Text("-\(NumberFormatter.compactCurrency(point.expense))")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.holoError)
                }
                if point.income > 0 {
                    Text("+\(NumberFormatter.compactCurrency(point.income))")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.holoSuccess)
                }
                if point.expense == 0 && point.income == 0 {
                    Text("无收支")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
            }
            Text("余额 \(NumberFormatter.compactCurrency(point.balance))")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.holoChart1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.holoCardBackground)
                .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
        )
        .fixedSize()
        .position(x: x, y: y)
    }

    // MARK: 空状态

    private var emptyChartView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("暂无数据，这就开始记一笔吧！")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(height: 160)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

#Preview("Trend Chart") {
    let sampleData = [
        ChartDataPoint(date: Date(), label: "周一", expense: 150, income: 0, transactionCount: 3, balance: -150),
        ChartDataPoint(date: Date().addingDays(1), label: "周二", expense: 80, income: 500, transactionCount: 2, balance: 270),
        ChartDataPoint(date: Date().addingDays(2), label: "周三", expense: 200, income: 0, transactionCount: 5, balance: 70),
        ChartDataPoint(date: Date().addingDays(3), label: "周四", expense: 50, income: 100, transactionCount: 2, balance: 120),
        ChartDataPoint(date: Date().addingDays(4), label: "周五", expense: 300, income: 0, transactionCount: 4, balance: -180),
    ]

    VStack {
        TrendChartView(dataPoints: sampleData)
        Spacer()
    }
    .padding()
    .background(Color.holoBackground)
}
