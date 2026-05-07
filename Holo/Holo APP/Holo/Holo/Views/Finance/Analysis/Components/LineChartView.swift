//
//  LineChartView.swift
//  Holo
//
//  折线图组件（用于明细 Tab）
//  使用 Swift Charts 实现，支持点击交互
//

import SwiftUI
import Charts

// MARK: - LineChartView

/// 折线图视图
struct LineChartView: View {
    let dataPoints: [ChartDataPoint]
    let selectedDate: Date?
    let onSelectDate: (Date?) -> Void

    @State private var hoveredLabel: String? = nil
    @State private var touchGestureLock = HorizontalGestureLock()

    private var allValuesZero: Bool {
        dataPoints.allSatisfy { $0.expense == 0 && $0.income == 0 }
    }

    /// 稳定 Y 轴域：取数据最大值向上取整到「好看」的刻度，避免小幅数据变动导致轴抖动
    private var yAxisDomain: ClosedRange<Double> {
        let maxVal = dataPoints.flatMap {
            [Double(truncating: $0.expense as NSDecimalNumber),
             Double(truncating: $0.income as NSDecimalNumber)]
        }.map(abs).max() ?? 0
        return 0...niceCeil(maxVal)
    }

    /// 向上取整到整齐的刻度值（10, 20, 50, 100, 200, 500, 1000, 2000, 5000 ...）
    private func niceCeil(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        let fraction = value / magnitude
        let niceFraction: Double
        switch fraction {
        case ..<1.5:  niceFraction = 2
        case ..<3.5:  niceFraction = 5
        case ..<7.5:  niceFraction = 10
        default:      niceFraction = 10
        }
        return niceFraction * magnitude
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 图例
            chartLegend

            // 图表
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
        }
    }

    // MARK: - 图表内容

    private var chartContent: some View {
        Chart(dataPoints) { point in
            // 支出折线
            LineMark(
                x: .value("日期", point.label),
                y: .value("支出", Double(truncating: point.expense as NSDecimalNumber))
            )
            .foregroundStyle(Color.holoError)
            .interpolationMethod(.catmullRom)

            // 支出点
            PointMark(
                x: .value("日期", point.label),
                y: .value("支出", Double(truncating: point.expense as NSDecimalNumber))
            )
            .foregroundStyle(Color.holoError)
            .symbolSize(30)

            // 收入折线
            if point.income > 0 {
                LineMark(
                    x: .value("日期", point.label),
                    y: .value("收入", Double(truncating: point.income as NSDecimalNumber))
                )
                .foregroundStyle(Color.holoSuccess)
                .interpolationMethod(.catmullRom)

                // 收入点
                PointMark(
                    x: .value("日期", point.label),
                    y: .value("收入", Double(truncating: point.income as NSDecimalNumber))
                )
                .foregroundStyle(Color.holoSuccess)
                .symbolSize(30)
            }

            // 选中高亮
            if let selectedDate = selectedDate,
               Calendar.current.isDate(point.date, inSameDayAs: selectedDate) {
                let yEndValue = max(
                    Double(truncating: point.expense as NSDecimalNumber),
                    Double(truncating: point.income as NSDecimalNumber)
                ) * 1.1
                if yEndValue > 0 {
                    RectangleMark(
                        x: .value("日期", point.label),
                        yStart: .value("底部", 0),
                        yEnd: .value("顶部", yEndValue)
                    )
                    .foregroundStyle(Color.holoPrimary.opacity(0.15))
                }
            }
        }
        .chartYScale(domain: yAxisDomain)
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider)
                AxisValueLabel()
                    .foregroundStyle(Color.holoTextSecondary)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider)
                AxisValueLabel() {
                    if let val = value.as(Double.self) {
                        Text(formatAxisValue(val))
                            .font(.system(size: 10))
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let overlayFrame = geometry.frame(in: .local)
                let plotFrame = proxy.plotFrame.map { geometry[$0] }

                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let axis = touchGestureLock.update(translation: value.translation)
                                guard axis != .vertical else {
                                    hoveredLabel = nil
                                    return
                                }
                                guard axis == .horizontal || value.translation == .zero else { return }
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
                                    onSelectDate(point.date)
                                }
                            }
                            .onEnded { _ in
                                hoveredLabel = nil
                                touchGestureLock.reset()
                            }
                    )

                // 触摸金额标注
                if let label = hoveredLabel,
                   let point = dataPoints.first(where: { $0.label == label }),
                   let xPos = proxy.position(forX: label) {
                    let convertedX = (plotFrame?.minX ?? 0) + xPos

                    let expenseVal = Double(truncating: point.expense as NSDecimalNumber)
                    let incomeVal = Double(truncating: point.income as NSDecimalNumber)
                    let maxVal = max(expenseVal, incomeVal)

                    if let topY = proxy.position(forY: max(maxVal, 0.001)), let plotFrame {
                        let convertedY = plotFrame.minY + topY
                        let clampedX = min(max(convertedX, 60), overlayFrame.width - 60)
                        let clampedY = min(max(convertedY - 24, 16), overlayFrame.height - 16)
                        lineTooltip(point: point, x: clampedX, y: clampedY)
                    }
                }
            }
        }
        .frame(height: 160)
    }

    // MARK: - 触摸金额标注

    private func lineTooltip(point: ChartDataPoint, x: CGFloat, y: CGFloat) -> some View {
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

#Preview("Line Chart") {
    let sampleData = [
        ChartDataPoint(date: Date(), label: "周一", expense: 150, income: 0, transactionCount: 3),
        ChartDataPoint(date: Date().addingDays(1), label: "周二", expense: 80, income: 500, transactionCount: 2),
        ChartDataPoint(date: Date().addingDays(2), label: "周三", expense: 200, income: 0, transactionCount: 5),
        ChartDataPoint(date: Date().addingDays(3), label: "周四", expense: 50, income: 100, transactionCount: 2),
        ChartDataPoint(date: Date().addingDays(4), label: "周五", expense: 300, income: 0, transactionCount: 4),
    ]

    VStack {
        LineChartView(
            dataPoints: sampleData,
            selectedDate: nil
        ) { _ in }
        Spacer()
    }
    .padding()
    .background(Color.holoBackground)
}
