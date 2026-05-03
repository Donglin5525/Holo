//
//  BarChartView.swift
//  Holo
//
//  柱状图组件（用于总览 Tab）
//  支出/收入柱状图 + 余额折线（双 Y 轴）+ 触摸交互
//

import SwiftUI
import Charts

// MARK: - BarChartView

/// 柱状图视图（支出/收入对比 + 可选余额折线，双 Y 轴）
struct BarChartView: View {
    let dataPoints: [ChartDataPoint]
    var showBalance: Bool = false
    var balanceScale: BalanceChartScale? = nil
    var selectedDate: Date? = nil
    var onSelectDate: ((Date?) -> Void)? = nil

    @State private var hoveredLabel: String? = nil

    private var allValuesZero: Bool {
        if showBalance {
            return dataPoints.allSatisfy { $0.expense == 0 && $0.income == 0 && $0.balance == 0 }
        }
        return dataPoints.allSatisfy { $0.expense == 0 && $0.income == 0 }
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
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    // MARK: - 图例

    private var chartLegend: some View {
        HStack(spacing: HoloSpacing.lg) {
            LegendItem(color: .holoError, label: "支出")
            LegendItem(color: .holoSuccess, label: "收入")
            if showBalance {
                LegendItem(color: .holoInfo, label: "余额")
            }
        }
    }

    // MARK: - 图表内容

    private var chartContent: some View {
        Chart(dataPoints) { point in
            let expenseVal = Double(truncating: point.expense as NSDecimalNumber)
            let incomeVal = Double(truncating: point.income as NSDecimalNumber)

            // 支出柱 → 左 Y 轴 (yAxisIndex: 0)
            BarMark(
                x: .value("日期", point.label),
                y: .value("支出", expenseVal)
            )
            .foregroundStyle(Color.holoError)
            .position(by: .value("类型", "支出"))

            // 收入柱 → 左 Y 轴 (yAxisIndex: 0)
            BarMark(
                x: .value("日期", point.label),
                y: .value("收入", incomeVal)
            )
            .foregroundStyle(Color.holoSuccess)
            .position(by: .value("类型", "收入"))

            // 余额折线 → 右 Y 轴 (yAxisIndex: 1, 缩放后映射到左轴视觉范围)
            if showBalance {
                let balanceVal = Double(truncating: point.balance as NSDecimalNumber)
                let scaledVal = balanceScale?.scaledBalance(balanceVal) ?? balanceVal

                LineMark(
                    x: .value("日期", point.label),
                    y: .value("余额", scaledVal)
                )
                .foregroundStyle(Color.holoInfo)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))

                PointMark(
                    x: .value("日期", point.label),
                    y: .value("余额", scaledVal)
                )
                .foregroundStyle(Color.holoInfo)
                .symbolSize(20)
            }
        }
        // X 轴
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider)
                AxisValueLabel()
                    .foregroundStyle(Color.holoTextSecondary)
            }
        }
        // 左 Y 轴（收支）—— 保留网格线 + 默认刻度标签
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider)
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(formatAxisValue(amount))
                            .font(.system(size: 10))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
        }
        // 锁定 Y 轴域 = 收支范围，确保余额折线的缩放映射精确对齐
        .chartYScale(domain: yAxisDomain)
        // 给右侧 Y 轴标签预留空间
        .chartPlotStyle { plotArea in
            plotArea.padding(.trailing, showBalance ? 44 : 0)
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let overlayFrame = geometry.frame(in: .local)
                let plotFrame = proxy.plotFrame.map { geometry[$0] }

                // 触摸手势：统一换算到 plot area 坐标，避免 overlay/global 坐标混用导致错位
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard !dataPoints.isEmpty, let plotFrame else { return }
                                let touchXInPlot = value.location.x - plotFrame.minX
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
                                    onSelectDate?(point.date)
                                }
                            }
                            .onEnded { _ in
                                hoveredLabel = nil
                            }
                    )

                // —— Tooltip 区域 ——
                if let label = hoveredLabel,
                   let point = dataPoints.first(where: { $0.label == label }),
                   let xPos = proxy.position(forX: label) {

                    let localX = (plotFrame?.minX ?? 0) + xPos
                    let expenseVal = Double(truncating: point.expense as NSDecimalNumber)
                    let incomeVal = Double(truncating: point.income as NSDecimalNumber)
                    let maxBarVal = max(expenseVal, incomeVal)
                    let balanceScaled = showBalance
                        ? (balanceScale?.scaledBalance(Double(truncating: point.balance as NSDecimalNumber)) ?? 0)
                        : 0
                    let anchorY = max(maxBarVal, balanceScaled)

                    // 垂直指示线
                    if let pf = plotFrame {
                        Capsule()
                            .fill(Color.holoPrimary.opacity(0.12))
                            .frame(width: 2, height: pf.height)
                            .position(x: localX, y: pf.midY)
                    }

                    // 金额标注（悬浮于数据点正上方，边界约束防溢出）
                    if let topY = proxy.position(forY: max(anchorY, 0.001)), let pf = plotFrame {
                        let localY = pf.minY + topY
                        let chartWidth = overlayFrame.width
                        let clampedX = min(max(localX, 60), chartWidth - 60)
                        let clampedY = min(max(localY - 24, 16), overlayFrame.height - 16)
                        amountTooltip(point: point, x: clampedX, y: clampedY)
                    }
                }

                // —— 右侧 Y 轴（余额刻度，无网格线） ——
                if showBalance, let scale = balanceScale, let pf = plotFrame {
                    rightAxisLabels(
                        scale: scale,
                        proxy: proxy,
                        plotFrame: pf
                    )
                }
            }
        }
        .frame(height: showBalance ? 300 : 240)
    }

    // MARK: - 右侧余额轴（无网格线，独立刻度）

    @ViewBuilder
    private func rightAxisLabels(
        scale: BalanceChartScale,
        proxy: ChartProxy,
        plotFrame: CGRect
    ) -> some View {
        let tickCount = 5
        let balanceStep = (scale.balanceAxisMax - scale.balanceAxisMin) / Double(tickCount - 1)

        ForEach(0..<tickCount, id: \.self) { i in
            let tickBalance = scale.balanceAxisMin + balanceStep * Double(i)
            let scaledTickY = scale.scaledBalance(tickBalance)

            if let yPos = proxy.position(forY: scaledTickY) {
                let localY = plotFrame.minY + yPos

                Text(formatAxisValue(tickBalance))
                    .font(.system(size: 9))
                    .foregroundColor(.holoInfo.opacity(0.7))
                    .fixedSize()
                    .position(x: plotFrame.maxX + 22, y: localY)
            }
        }
    }

    // MARK: - Tooltip

    private func amountTooltip(point: ChartDataPoint, x: CGFloat, y: CGFloat) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
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
            }
            if showBalance && point.balance != 0 {
                Text("余额 \(NumberFormatter.compactCurrency(point.balance))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.holoInfo)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.holoCardBackground)
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
        )
        .fixedSize()
        .position(x: x, y: y)
    }

    // MARK: - 辅助方法

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

    // MARK: - 空状态

    private var emptyChartView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "chart.bar")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("暂无数据，这就开始记一笔吧！")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(height: 300)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Legend Item

/// 图例项
struct LegendItem: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: HoloSpacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
    }
}

// MARK: - Preview

#Preview("Bar Chart") {
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
        BarChartView(
            dataPoints: sampleData,
            showBalance: true,
            balanceScale: scale
        ) { _ in }
        Spacer()
    }
    .padding()
    .background(Color.holoBackground)
}
