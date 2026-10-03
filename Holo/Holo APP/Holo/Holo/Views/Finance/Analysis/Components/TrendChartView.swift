//
//  TrendChartView.swift
//  Holo
//
//  总览 Tab 趋势卡（双轴同图·常规样式）：
//  - 每日收支柱（红=支出、绿=收入）贴底，走左轴，几乎全高；当日最大支出日整柱高亮
//  - 余额线（冷蓝，独立刻度）按右轴铺满整个绘图区、从柱间穿过，两根轴各自铺满，明着双尺不误导
//  - 极淡横向网格随左轴刻度铺满全高；余额信息另外在卡头「较期初」与点按明细里可读
//  - 单日尖峰超过次高值 2 倍且有效天数 ≥5 时，柱轴上限压缩并对尖峰柱做「断口」截断
//  - 横向拖动/点按查看单日（柱后高亮带 + 明细），纵向手势交还页面滚动，点空白收起
//

import SwiftUI
import Charts

// MARK: - TrendChartView

/// 总览趋势卡（收支柱 + 余额线双轴同图）
struct TrendChartView: View {
    let dataPoints: [ChartDataPoint]
    /// 是否画余额线与右轴余额刻度（项目维度下项目不是资金容器，无余额语义，整体隐藏）
    var showsBalanceLine: Bool = true

    @State private var hoveredIndex: Int? = nil

    // MARK: 画布几何（y 抽象单位，domain [0, plotUnitMax]，值越大越靠上）
    private let plotUnitMax: Double = 100
    private let barTopUnit: Double = 90          // 柱带：0...90（柱轴上限映射到 90，顶部留断口标注空间）
    private let lineBandLow: Double = 8          // 线带：8...94（余额最小值→8，最大值→94，铺满全高穿柱而过）
    private let lineBandHigh: Double = 94
    private let restBarOpacity: Double = 0.78    // 非峰值日柱子透明度（峰值日实色高亮）

    /// 整月无收支动作即视为空图（余额不为零也不画）：画出来只会是
    /// 「左轴缩到 0~1 元的假轴 + 走平余额线 + 三只同值右轴刻度」，不如直接出空态
    private var hasNoFlowActivity: Bool {
        dataPoints.allSatisfy { $0.expense == 0 && $0.income == 0 }
    }

    /// 图表动画触发值：ChartDataPoint 的 id 是每次构造的随机 UUID（不可作 diff 依据），
    /// 用支出/收入/余额数值序列当指纹，切时间范围/数据更新时柱与线平滑插值而非跳变
    private var animatedSignature: [Double] {
        dataPoints.flatMap {
            [Double(truncating: $0.expense as NSDecimalNumber),
             Double(truncating: $0.income as NSDecimalNumber),
             Double(truncating: $0.balance as NSDecimalNumber)]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            chartLegend

            if dataPoints.isEmpty || hasNoFlowActivity {
                emptyChartView
                    .transition(.opacity)
            } else {
                chartContent
                    .transition(.opacity)
            }
        }
        .animation(HoloAnimation.smooth, value: dataPoints.isEmpty || hasNoFlowActivity)
        .padding(HoloSpacing.md)
        .holoSurface()
    }

    // MARK: 图例（右侧：余额较期初变化）

    private var chartLegend: some View {
        HStack(spacing: HoloSpacing.lg) {
            LegendItem(color: .holoError, label: String(localized: "支出"))
            LegendItem(color: .holoSuccess, label: String(localized: "收入"))
            if showsBalanceLine {
                LegendItem(color: .holoChart1, label: String(localized: "余额"))
            }
            Spacer()
            if showsBalanceLine, let delta = balanceDelta {
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
        let balanceTicks = showsBalanceLine ? self.balanceTicks(range: range) : []
        let peakDay = peakDayIndex

        return trendChart(cap: plan.cap, clippedIndices: plan.clippedIndices,
                          peakDayIndex: peakDay, balanceTicks: balanceTicks)
            .animation(HoloAnimation.smooth, value: animatedSignature)
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
                            .fill(Color.holoToolText.opacity(0.05))
                            .frame(width: plotFrame.width / CGFloat(dataPoints.count), height: plotFrame.height)
                            .position(x: plotFrame.minX + slotXPos, y: plotFrame.midY)
                    }

                    // —— 断口截断标注 ——
                    if let plotFrame {
                        ForEach(plan.clippedIndices, id: \.self) { index in
                            if let capTopY = proxy.position(forY: barTopUnit),
                               let barXPos = proxy.position(forX: breakBarX(index)) {
                                // 标注默认画柱右侧；尖峰落在月末时右侧是右轴刻度区，
                                // 金额会叠在刻度上（2026-10-01 东林实测 9/30 挤成一团），越界即翻到柱左侧
                                let labelCenterX = plotFrame.minX + barXPos + barWidth / 2 + 24
                                let placeLabelLeft = labelCenterX + 20 > plotFrame.maxX - 2
                                clippedBreakAnnotations(
                                    capTopY: plotFrame.minY + capTopY,
                                    barXPos: plotFrame.minX + barXPos,
                                    amountLabel: Self.axisAmountLabel(clippedAmount(index)),
                                    placeLabelLeft: placeLabelLeft
                                )
                            }
                        }
                    }

                    // —— 末位日期自绘（原因见 axisLabelIndices 注释）：右对齐钉在绘图区右缘 ——
                    if let plotFrame, let lastPoint = dataPoints.last {
                        Text(lastPoint.label)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.holoToolTextSecondary)
                            .frame(width: plotFrame.width, alignment: .trailing)
                            .position(x: plotFrame.midX, y: plotFrame.maxY + 10)
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
            if showsBalanceLine {
                ForEach(dataPoints.indices, id: \.self) { index in
                    balanceLine(index, dataPoints[index])
                }
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
                            .foregroundStyle(Color.holoToolTextSecondary)
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
                // 截断柱画整根到量程顶，由 clippedBreakAnnotations 用卡片底色斜缝
                // 在柱身上切出断口（柱先留空隙再画缝会让缝隐身，2026-09-09 实测）
                BarMark(
                    x: .value("日期", x),
                    yStart: .value("起点", 0.0),
                    yEnd: .value("金额", barTopUnit),
                    width: .fixed(barWidth)
                )
                .cornerRadius(2)
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

    /// 余额线（冷蓝，独立刻度铺满全绘图区）
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

    /// 断口：柱身画整根，用两道卡片底色斜缝在柱顶下方切出断口（旧版白杠深色模式刺眼、
    /// 浅色模式不可见，且缝画在柱外空隙里等于隐身）+ 真实值标注（默认柱右侧；
    /// `placeLabelLeft` 时翻到柱左侧并右对齐，避免与右轴刻度叠印）
    @ViewBuilder
    private func clippedBreakAnnotations(capTopY: CGFloat, barXPos: CGFloat, amountLabel: String, placeLabelLeft: Bool) -> some View {
        ForEach(0..<2, id: \.self) { slashIndex in
            Capsule()
                .fill(Color.holoToolSurface)
                .frame(width: barWidth + 3, height: 1.6)
                .rotationEffect(.degrees(-24))
                .position(x: barXPos, y: capTopY + 6.5 + CGFloat(slashIndex) * 4.5)
        }

        Text(amountLabel)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.holoSuccessDark)
            .frame(width: 40, alignment: placeLabelLeft ? .trailing : .leading)
            .position(x: placeLabelLeft ? barXPos - barWidth / 2 - 24 : barXPos + barWidth / 2 + 24,
                      y: capTopY - 7)
    }

    // MARK: 数值换算

    /// 每日双柱几何：组内缝必须小于组间缝，否则前一天的收入柱和后一天的支出柱
    /// 贴成一团，读成「同一个时间点三根柱」（2026-10-03 东林实报 9/29+9/30 连续两天
    /// 有收支时穿帮）。月视图 30 天绘图区每分到约 10pt：柱宽 3.2 + 偏移 ±0.20 时
    /// 组内缝 ≈0.8pt、组间缝 ≈2.8pt；周视图等稀疏档（≤14 天）柱加宽，比例同样成立。
    private var barOffsetUnits: Double {
        dataPoints.count > 14 ? 0.20 : 0.18
    }

    private var barWidth: CGFloat {
        dataPoints.count > 14 ? 3.2 : 6
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

    /// 余额线映射到全绘图区（全幅极值归一化）
    private func lineY(_ balance: Double, range: ClosedRange<Double>) -> Double {
        guard range.upperBound > range.lowerBound else { return (lineBandLow + lineBandHigh) / 2 }
        let t = (balance - range.lowerBound) / (range.upperBound - range.lowerBound)
        return lineBandLow + t * (lineBandHigh - lineBandLow)
    }

    private func lineY(_ balance: Double) -> Double {
        lineY(balance, range: balanceValueRange)
    }

    /// 右轴余额刻度：最小 / 中位 / 最大 三档；三档标签重复（余额走平或波动远小于
    /// 刻度精度，如整月只差几元）时按标签去重，避免同值刻度竖排一列
    private func balanceTicks(range: ClosedRange<Double>) -> [(unit: Double, label: String)] {
        let candidates: [(unit: Double, label: String)]
        if range.upperBound - range.lowerBound < 0.01 {
            candidates = [(lineY(range.lowerBound, range: range), Self.axisAmountLabel(range.lowerBound))]
        } else {
            let values = [range.lowerBound, (range.lowerBound + range.upperBound) / 2, range.upperBound]
            candidates = values.map { (lineY($0, range: range), Self.axisAmountLabel($0)) }
        }
        var seenLabels = Set<String>()
        return candidates.filter { seenLabels.insert($0.label).inserted }
    }

    private func balanceTickLabel(_ axisValue: Double, ticks: [(unit: Double, label: String)]) -> String {
        ticks.first { abs($0.unit - axisValue) < 0.01 }?.label ?? ""
    }

    /// 数据点多（>14）时 X 轴稀疏展示（5 格 + 末位自绘）。
    /// 末位数据点不进刻度层：横轴刻度文字层的右缘被尾侧余额刻度轴截掉一段，
    /// 末位标签无论居中还是改锚点都会被钳位到边界上、与倒数第二格叠印——
    /// 改由 chartOverlay 在绘图区右下角右对齐自绘（与断口标注同一画法）。
    private var axisLabelIndices: [(index: Int, label: String)] {
        let count = dataPoints.count
        guard count > 1 else { return [] }
        guard count > 14 else { return (0..<(count - 1)).map { ($0, dataPoints[$0].label) } }
        let step = max(Double(count - 1) / 5, 1)
        return (0..<5).compactMap { stepIndex in
            let dataIndex = min(Int((Double(stepIndex) * step).rounded()), count - 2)
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

    /// 轴刻度金额紧凑口径：万 / 千 / 整数（实现收在 NumberFormatter.compactAxisAmount，可单测）
    private static func axisAmountLabel(_ value: Double) -> String {
        NumberFormatter.compactAxisAmount(value)
    }

    // MARK: Tooltip

    private func amountTooltip(point: ChartDataPoint, dateLabel: String, x: CGFloat, y: CGFloat) -> some View {
        VStack(spacing: 2) {
            Text(dateLabel)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.holoToolTextSecondary)
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
                        .foregroundColor(.holoToolTextSecondary)
                }
            }
            if showsBalanceLine {
                Text("余额 \(NumberFormatter.compactCurrency(point.balance))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.holoChart1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.holoToolSurface)
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
                .foregroundColor(.holoToolTextSecondary.opacity(0.5))

            Text("暂无数据，这就开始记一笔吧！")
                .font(.holoCaption)
                .foregroundColor(.holoToolTextSecondary)
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
    .background(Color.holoToolBackground)
}
