//
//  LineChartView.swift
//  Holo
//
//  折线图组件（用于明细 Tab）
//  使用 Swift Charts 实现，支持点击交互
//

import SwiftUI
import Charts
import UIKit

// MARK: - LineChartView

/// 折线图视图
struct LineChartView: View {
    let dataPoints: [ChartDataPoint]
    let selectedDate: Date?
    var displayedType: TransactionType = .expense
    var displayedTypeSelection: Binding<TransactionType>? = nil
    var selectionDataPoints: [ChartDataPoint]? = nil
    var onScrubDate: ((Date) -> Void)? = nil
    let onSelectDate: (Date?) -> Void

    @State private var hoveredDate: Date? = nil

    private var selectablePoints: [ChartDataPoint] {
        (selectionDataPoints ?? dataPoints).filter(\.hasTransactions)
    }

    private var axisMarkDates: [Date] {
        guard dataPoints.count > 14 else { return dataPoints.map(\.date) }

        let desiredCount = 6
        let lastIndex = dataPoints.count - 1
        let step = max(Double(lastIndex) / Double(desiredCount - 1), 1)

        return (0..<desiredCount).compactMap { index in
            let dataIndex = min(Int((Double(index) * step).rounded()), lastIndex)
            return dataPoints[dataIndex].date
        }
    }

    /// 稳定 Y 轴域：取数据最大值向上取整到「好看」的刻度，避免小幅数据变动导致轴抖动
    private var yAxisDomain: ClosedRange<Double> {
        let maxVal = dataPoints
            .map { Double(truncating: amount(for: $0) as NSDecimalNumber) }
            .map(abs)
            .max() ?? 0
        return 0...niceCeil(maxVal)
    }

    /// 向上取整到整齐的刻度值（10, 20, 50, 100, 200, 500, 1000, 2000, 5000 ...）
    private func niceCeil(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        let fraction = value / magnitude
        let niceFraction: Double
        switch fraction {
        case ...1: niceFraction = 1
        case ...2: niceFraction = 2
        case ...5: niceFraction = 5
        default: niceFraction = 10
        }
        return niceFraction * magnitude
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 图例
            chartHeader

            // 图表
            if dataPoints.isEmpty {
                emptyChartView
            } else {
                chartContent
            }
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 14)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoDivider.opacity(0.4), lineWidth: 0.5)
        }
        .shadow(color: Color.black.opacity(0.035), radius: 8, y: 3)
    }

    // MARK: - 图例

    private var chartHeader: some View {
        HStack(spacing: HoloSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("收支趋势")
                    .font(.holoLabel)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)

                Text("横向滑动，明细实时定位")
                    .font(.system(size: 10))
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer(minLength: HoloSpacing.sm)

            if let displayedTypeSelection {
                Picker("趋势类型", selection: displayedTypeSelection) {
                    Text("支出").tag(TransactionType.expense)
                    Text("收入").tag(TransactionType.income)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 136)
            } else {
                LegendItem(color: lineColor, label: displayedType.displayName)
            }
        }
    }

    // MARK: - 图表内容

    private var chartContent: some View {
        Chart(dataPoints) { point in
            AreaMark(
                x: .value("日期", point.date),
                yStart: .value("基线", 0),
                yEnd: .value(displayedType.displayName, Double(truncating: amount(for: point) as NSDecimalNumber))
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [lineColor.opacity(0.14), lineColor.opacity(0.005)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("日期", point.date),
                y: .value(displayedType.displayName, Double(truncating: amount(for: point) as NSDecimalNumber))
            )
            .foregroundStyle(lineColor)
            .lineStyle(StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.catmullRom)

            // 选中高亮
            if let focusedDate = hoveredDate ?? selectedDate,
               pointContains(focusedDate, in: point),
               amount(for: point) > 0 {
                RuleMark(x: .value("选中日期", point.date))
                    .foregroundStyle(lineColor.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                PointMark(
                    x: .value("选中日期", point.date),
                    y: .value("选中金额", Double(truncating: amount(for: point) as NSDecimalNumber))
                )
                .foregroundStyle(Color.holoCardBackground)
                .symbolSize(66)

                PointMark(
                    x: .value("选中日期", point.date),
                    y: .value("选中金额", Double(truncating: amount(for: point) as NSDecimalNumber))
                )
                .foregroundStyle(lineColor)
                .symbolSize(30)
            }
        }
        .chartXScale(
            range: .plotDimension(startPadding: 12, endPadding: 12)
        )
        .chartYScale(
            domain: yAxisDomain,
            range: .plotDimension(startPadding: 9, endPadding: 12)
        )
        .chartXAxis {
            AxisMarks(values: axisMarkDates) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self),
                       let label = labelForAxisDate(date) {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.holoTextSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider.opacity(0.32))
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

                DirectionalChartGestureOverlay(
                    onChanged: { location in
                        let date = selectableDate(
                            at: location,
                            proxy: proxy,
                            plotFrame: plotFrame
                        )
                        if let date,
                           hoveredDate.map({
                               !Calendar.current.isDate($0, inSameDayAs: date)
                           }) ?? true {
                            hoveredDate = date
                            onScrubDate?(date)
                        }
                    },
                    onEnded: { location in
                        let date = selectableDate(
                            at: location,
                            proxy: proxy,
                            plotFrame: plotFrame
                        ) ?? hoveredDate
                        hoveredDate = nil
                        if let date {
                            onSelectDate(date)
                        }
                    },
                    onCancelled: {
                        hoveredDate = nil
                    }
                )

                // 触摸金额标注
                if let hoveredDate,
                   let point = selectablePoints.first(where: { Calendar.current.isDate($0.date, inSameDayAs: hoveredDate) }),
                   let xPos = proxy.position(forX: point.date) {
                    let convertedX = (plotFrame?.minX ?? 0) + xPos

                    let pointValue = Double(truncating: amount(for: point) as NSDecimalNumber)

                    if let topY = proxy.position(forY: max(pointValue, 0.001)), let plotFrame {
                        let convertedY = plotFrame.minY + topY
                        let clampedX = min(max(convertedX, 60), overlayFrame.width - 60)
                        let clampedY = min(max(convertedY - 24, 16), overlayFrame.height - 16)
                        lineTooltip(point: point, x: clampedX, y: clampedY)
                    }
                }
            }
        }
        .chartPlotStyle { plotArea in
            plotArea.background(Color.clear)
        }
        .frame(height: 142)
    }

    // MARK: - 触摸金额标注

    private func lineTooltip(point: ChartDataPoint, x: CGFloat, y: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text("\(displayedType == .expense ? "-" : "+")\(NumberFormatter.compactCurrency(amount(for: point)))")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(lineColor)
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

    private var lineColor: Color {
        displayedType == .expense ? .holoError : .holoSuccess
    }

    private func amount(for point: ChartDataPoint) -> Decimal {
        switch displayedType {
        case .expense:
            return point.expense
        case .income:
            return point.income
        }
    }

    private func labelForAxisDate(_ date: Date) -> String? {
        dataPoints.first { Calendar.current.isDate($0.date, inSameDayAs: date) }?.label
    }

    private func pointContains(_ selectedDate: Date, in point: ChartDataPoint) -> Bool {
        guard !Calendar.current.isDate(point.date, inSameDayAs: selectedDate) else { return true }
        guard let index = dataPoints.firstIndex(where: { $0.id == point.id }) else { return false }
        guard dataPoints.indices.contains(index + 1) else { return selectedDate >= point.date }
        return selectedDate >= point.date && selectedDate < dataPoints[index + 1].date
    }

    private func nearestSelectablePointIndex(
        touchXInPlot: CGFloat,
        pointXPositions: [CGFloat]
    ) -> Int? {
        guard !pointXPositions.isEmpty else { return nil }

        return pointXPositions.enumerated()
            .min { abs(touchXInPlot - $0.element) < abs(touchXInPlot - $1.element) }?
            .offset
    }

    private func selectableDate(
        at location: CGPoint,
        proxy: ChartProxy,
        plotFrame: CGRect?
    ) -> Date? {
        guard !selectablePoints.isEmpty, let plotFrame else { return nil }

        let touchXInPlot = location.x - plotFrame.minX
        guard touchXInPlot >= 0, touchXInPlot <= plotFrame.width else { return nil }

        let pointPositions = selectablePoints.compactMap { proxy.position(forX: $0.date) }
        guard pointPositions.count == selectablePoints.count,
              let index = nearestSelectablePointIndex(
                touchXInPlot: touchXInPlot,
                pointXPositions: pointPositions
              ) else { return nil }

        return selectablePoints[index].date
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
        .frame(height: 142)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 图表方向手势

/// UIKit 的 pan delegate 能在识别开始前拒绝纵向拖动。
/// 这与“识别后不处理纵向值”不同：拒绝后父级 ScrollView 可直接接管，不会出现首帧卡顿。
private final class DirectionalChartGestureView: UIView {
    var onHierarchyReady: ((UIView) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            onHierarchyReady?(self)
        }
    }
}

private struct DirectionalChartGestureOverlay: UIViewRepresentable {
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    let onCancelled: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onChanged: onChanged,
            onEnded: onEnded,
            onCancelled: onCancelled
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = DirectionalChartGestureView()
        view.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = true
        context.coordinator.chartPanGesture = pan

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        tap.require(toFail: pan)

        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(tap)
        view.onHierarchyReady = { [weak coordinator = context.coordinator] view in
            coordinator?.prioritizeChartPan(overParentScrollViewFrom: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onCancelled = onCancelled
        DispatchQueue.main.async {
            context.coordinator.prioritizeChartPan(overParentScrollViewFrom: uiView)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: (CGPoint) -> Void
        var onEnded: (CGPoint) -> Void
        var onCancelled: () -> Void
        weak var chartPanGesture: UIPanGestureRecognizer?
        weak var prioritizedParentScrollView: UIScrollView?

        init(
            onChanged: @escaping (CGPoint) -> Void,
            onEnded: @escaping (CGPoint) -> Void,
            onCancelled: @escaping () -> Void
        ) {
            self.onChanged = onChanged
            self.onEnded = onEnded
            self.onCancelled = onCancelled
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let location = recognizer.location(in: view)

            switch recognizer.state {
            case .began, .changed:
                onChanged(location)
            case .ended:
                onEnded(location)
            case .cancelled, .failed:
                onCancelled()
            default:
                break
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            onEnded(recognizer.location(in: view))
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else {
                return true
            }

            return ChartGestureArbitration.shouldBeginHorizontalPan(
                velocity: pan.velocity(in: view)
            )
        }

        /// 父级滚动必须先等待图表判定方向：
        /// 横向时图表独占，纵向或模糊方向时图表失败并立即交还页面滚动。
        func prioritizeChartPan(overParentScrollViewFrom view: UIView) {
            guard let chartPanGesture else { return }

            var ancestor = view.superview
            while let current = ancestor {
                if let scrollView = current as? UIScrollView {
                    guard prioritizedParentScrollView !== scrollView else { return }
                    scrollView.panGestureRecognizer.require(toFail: chartPanGesture)
                    prioritizedParentScrollView = scrollView
                    return
                }
                ancestor = current.superview
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            ChartGestureArbitration.allowsSimultaneousRecognition
        }
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
