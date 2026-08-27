//
//  TrendChartView.swift
//  Holo
//
//  总览 Tab 趋势卡：支出 / 收入 / 余额 三线同图
//  收支走左轴；余额经 BalanceChartScale 缩放映射到同一视觉区间，
//  右轴不再标刻度（余额精确值在触摸 tooltip 里读）——规避双轴数字的认知负担。
//  曲线 catmullRom 平滑连接、不画逐日数据点。
//

import SwiftUI
import Charts

// MARK: - TrendChartView

/// 总览趋势卡（三线同图）
struct TrendChartView: View {
    let dataPoints: [ChartDataPoint]
    var balanceScale: BalanceChartScale? = nil

    @State private var hoveredLabel: String? = nil

    private var allValuesZero: Bool {
        dataPoints.allSatisfy { $0.expense == 0 && $0.income == 0 && $0.balance == 0 }
    }

    /// X 轴刻度标签：数据点多（>14）时稀疏展示（最多 6 个）
    private var axisMarkLabels: [String] {
        guard dataPoints.count > 14 else { return dataPoints.map(\.label) }
        let desiredCount = 6
        let lastIndex = dataPoints.count - 1
        let step = max(Double(lastIndex) / Double(desiredCount - 1), 1)
        return (0..<desiredCount).compactMap { index in
            let dataIndex = min(Int((Double(index) * step).rounded()), lastIndex)
            return dataPoints[dataIndex].label
        }
    }

    /// Y 轴域：锁定为 BalanceChartScale 的收支范围，确保余额折线映射精确
    private var yAxisDomain: ClosedRange<Double> {
        if let scale = balanceScale {
            return scale.amountAxisMin...scale.amountAxisMax
        }
        let maxVal = dataPoints.flatMap {
            [Double(truncating: $0.expense as NSDecimalNumber),
             Double(truncating: $0.income as NSDecimalNumber)]
        }.map(abs).max() ?? 0
        return 0...max(maxVal, 1)
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

    // MARK: 图例

    private var chartLegend: some View {
        HStack(spacing: HoloSpacing.lg) {
            LegendItem(color: .holoError, label: "支出")
            LegendItem(color: .holoSuccess, label: "收入")
            LegendItem(color: .holoPrimary, label: "余额")
        }
    }

    // MARK: 图表内容

    private var chartContent: some View {
        Chart(dataPoints) { point in
            let expenseVal = Double(truncating: point.expense as NSDecimalNumber)
            let incomeVal = Double(truncating: point.income as NSDecimalNumber)
            let balanceVal = Double(truncating: point.balance as NSDecimalNumber)
            let scaledBalance = balanceScale?.scaledBalance(balanceVal) ?? balanceVal

            // 余额渐变垫底：只做水位质感，不压过三线
            AreaMark(
                x: .value("日期", point.label),
                y: .value("余额", scaledBalance)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [Color.holoPrimary.opacity(0.10), Color.holoPrimary.opacity(0.0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.monotone)

            // 三线同图：余额（品牌橙）为主视觉，支出暖红、收入暖绿。
            // series 必须各自命名——否则 Charts 会把连续的同类型 Mark 串成一条线
            lineMark(label: point.label, value: scaledBalance, color: .holoPrimary, width: 2.5, series: "余额")
            lineMark(label: point.label, value: expenseVal, color: .holoError, width: 2.25, series: "支出")
            lineMark(label: point.label, value: incomeVal, color: .holoSuccess, width: 2.25, series: "收入")
        }
        // 给首尾数据点留出空间，避免曲线贴边被裁切
        .chartXScale(range: .plotDimension(padding: 18))
        .chartXAxis {
            AxisMarks(values: axisMarkLabels) { _ in
                AxisValueLabel()
                    .foregroundStyle(Color.holoTextSecondary)
            }
        }
        .chartYAxis {
            AxisMarks(
                position: .leading,
                values: FinanceChartAxisTicks.amountTicks(min: yAxisDomain.lowerBound, max: yAxisDomain.upperBound)
            ) { value in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider.opacity(0.5))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(formatAxisValue(amount))
                            .font(.system(size: 10))
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
        .chartYScale(domain: yAxisDomain)
        .chartPlotStyle { plotArea in
            plotArea
                .padding(.leading, 4)
                .padding(.trailing, 8)
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let overlayFrame = geometry.frame(in: .local)
                let plotFrame = proxy.plotFrame.map { geometry[$0] }

                // 触摸手势：横向拖动独占、纵向拖动在识别开始前交还页面滚动
                DirectionalChartGestureOverlay(
                    onChanged: { location in
                        guard !dataPoints.isEmpty, let plotFrame else { return }
                        let touchXInPlot = location.x - plotFrame.minX
                        let pointPositions = dataPoints.compactMap { proxy.position(forX: $0.label) }
                        guard pointPositions.count == dataPoints.count,
                              let index = ChartTouchSelection.nearestPointIndex(
                                touchXInPlot: touchXInPlot,
                                plotWidth: plotFrame.width,
                                pointXPositions: pointPositions
                              ) else { return }

                        let point = dataPoints[index]
                        if hoveredLabel != point.label {
                            hoveredLabel = point.label
                        }
                    },
                    onEnded: { _ in
                        hoveredLabel = nil
                    },
                    onCancelled: {
                        hoveredLabel = nil
                    }
                )

                // —— Tooltip ——
                if let label = hoveredLabel,
                   let point = dataPoints.first(where: { $0.label == label }),
                   let xPos = proxy.position(forX: label) {

                    let localX = (plotFrame?.minX ?? 0) + xPos
                    let expenseVal = Double(truncating: point.expense as NSDecimalNumber)
                    let incomeVal = Double(truncating: point.income as NSDecimalNumber)
                    let balanceScaled = balanceScale?
                        .scaledBalance(Double(truncating: point.balance as NSDecimalNumber)) ?? 0
                    let anchorY = max(max(expenseVal, incomeVal), balanceScaled)

                    // 垂直指示线
                    if let pf = plotFrame {
                        Capsule()
                            .fill(Color.holoPrimary.opacity(0.12))
                            .frame(width: 2, height: pf.height)
                            .position(x: localX, y: pf.midY)
                    }

                    if let topY = proxy.position(forY: max(anchorY, 0.001)), let pf = plotFrame {
                        let localY = pf.minY + topY
                        let clampedX = min(max(localX, 60), overlayFrame.width - 60)
                        let clampedY = min(max(localY - 24, 16), overlayFrame.height - 16)
                        amountTooltip(point: point, x: clampedX, y: clampedY)
                    }
                }
            }
        }
        .frame(height: 200)
    }

    /// 单条平滑曲线（不画逐日数据点）；series 隔离防止跨系列串线。
    /// monotone 单调插值：平台保持平、突变处圆滑，且不产生 catmullRom 的过冲
    /// （不会画出数据里不存在的峰谷）——金融曲线的标准插值
    private func lineMark(label: String, value: Double, color: Color, width: CGFloat, series: String) -> some ChartContent {
        LineMark(
            x: .value("日期", label),
            y: .value("金额", value),
            series: .value(series, series)
        )
        .foregroundStyle(color)
        .interpolationMethod(.monotone)
        .lineStyle(StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    // MARK: Tooltip

    private func amountTooltip(point: ChartDataPoint, x: CGFloat, y: CGFloat) -> some View {
        VStack(spacing: 2) {
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
                .foregroundColor(.holoPrimary)
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

    // MARK: 辅助方法

    private func formatAxisValue(_ value: Double) -> String {
        let absValue = abs(value)
        if absValue >= 100_000_000 {
            return String(format: "%.1f亿", value / 100_000_000)
        } else if absValue >= 10_000 {
            return String(format: "%.1f万", value / 10_000)
        } else if absValue >= 1 {
            return String(format: "%.0f", value)
        } else {
            return ""
        }
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
    let scale = BalanceChartScale(
        amountValues: sampleData.flatMap { [
            Double(truncating: $0.expense as NSDecimalNumber),
            Double(truncating: $0.income as NSDecimalNumber)
        ] },
        balanceValues: sampleData.map { Double(truncating: $0.balance as NSDecimalNumber) }
    )

    VStack {
        TrendChartView(dataPoints: sampleData, balanceScale: scale)
        Spacer()
    }
    .padding()
    .background(Color.holoBackground)
}
