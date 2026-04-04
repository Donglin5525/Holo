//
//  PieChartView.swift
//  Holo
//
//  环形饼图组件（用于类别 Tab）
//  所有标签位于饼图外侧，引导线连接文字与扇区
//  支持触摸高亮 + 松手后下钻（touch down = 高亮, touch up = 导航)
//

import SwiftUI
import Charts

// MARK: - PieChartView

/// 环形饼图视图
/// 标签全部位于饼图外侧，用引导线连接对应扇区
struct PieChartView: View {
    let aggregations: [CategoryAggregation]
    let selectedCategory: Category?
    let onSelectCategory: ((Category?) -> Void)?

    @State private var highlightedCategory: Category?

    // 图表颜色
    private let chartColors: [Color] = [
        .holoChart1, .holoChart2, .holoChart3, .holoChart4, .holoChart5
    ]

    private var nonZeroAggregations: [CategoryAggregation] {
        aggregations.filter { $0.amount > 0 }
    }

    /// 当前视觉焦点类别（高亮优先于选中）
    private var effectiveCategory: Category? {
        highlightedCategory ?? selectedCategory
    }

    // 焦点聚合数据（高亮或选中)
    private var focusedAggregation: CategoryAggregation? {
        guard let category = effectiveCategory else {
            return aggregations.first
        }
        return aggregations.first { $0.category.id == category.id }
    }

    // 总金额
    private var totalAmount: Decimal {
        aggregations.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        VStack(spacing: HoloSpacing.md) {
            if nonZeroAggregations.isEmpty {
                emptyChartView
            } else {
                pieChartContent
            }
        }
    }

    // MARK: - 饼图主体

    private var pieChartContent: some View {
        ZStack {
            // 饼图
            Chart(nonZeroAggregations) { agg in
                let index = nonZeroAggregations.firstIndex(where: { $0.id == agg.id }) ?? 0
                SectorMark(
                    angle: .value("金额", Double(truncating: agg.amount as NSDecimalNumber)),
                    innerRadius: .ratio(0.45),
                    angularInset: 1.5
                )
                .cornerRadius(4)
                .foregroundStyle(colorForCategory(agg.category, at: index))
                .opacity(effectiveCategory == nil || effectiveCategory?.id == agg.category.id ? 1 : 0.3)
            }
            .frame(height: 220)
            .chartOverlay { _ in
                ZStack {
                    PieChartInteractionOverlay(
                        aggregations: nonZeroAggregations,
                        onHighlight: { category in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                highlightedCategory = category
                            }
                        },
                        onSelect: { category in
                            highlightedCategory = nil
                            onSelectCategory?(category)
                        }
                    )

                    labelsOverlay
                    highlightArcOverlay
                }
            }

            // 中心信息
            centerInfo
        }
        .frame(height: 300)
        .onChange(of: aggregations.map(\.id)) { _, _ in
            highlightedCategory = nil
        }
    }

    // MARK: - 高亮弧线覆盖层（触摸时的视觉反馈）

    @ViewBuilder
    private var highlightArcOverlay: some View {
        if let highlighted = highlightedCategory,
           let index = nonZeroAggregations.firstIndex(where: { $0.category.id == highlighted.id }) {
            GeometryReader { geometry in
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                let outerRadius = min(geometry.size.width, geometry.size.height) / 2

                let total = nonZeroAggregations.reduce(0.0) {
                    $0 + Double(truncating: $1.amount as NSDecimalNumber)
                }

                if total > 0 {
                    let startDeg = Self.sectorStartAngle(
                        index: index, aggregations: nonZeroAggregations, total: total
                    )
                    let spanDeg = Self.sectorSpan(
                        index: index, aggregations: nonZeroAggregations, total: total
                    )

                    Path { path in
                        path.addArc(
                            center: center,
                            radius: outerRadius + 2,
                            startAngle: .degrees(-startDeg),
                            endAngle: .degrees(-(startDeg + spanDeg)),
                            clockwise: true
                        )
                    }
                    .stroke(
                        Color.white.opacity(0.7),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .shadow(color: .white.opacity(0.3), radius: 3)
                }
            }
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.15), value: highlightedCategory?.id)
        }
    }

    // MARK: - 标签覆盖层（所有标签位于饼图外侧，引导线连接）

    @ViewBuilder
    private var labelsOverlay: some View {
        if !nonZeroAggregations.isEmpty {
            GeometryReader { geometry in
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                let outerRadius = min(geometry.size.width, geometry.size.height) / 2

                let total = nonZeroAggregations.reduce(0.0) {
                    $0 + Double(truncating: $1.amount as NSDecimalNumber)
                }

                if total > 0 {
                    let labels = computeOutsideLabelLayouts(
                        center: center,
                        outerRadius: outerRadius,
                        total: total
                    )

                    ForEach(labels, id: \.index) { label in
                        // 引导线：扇区边缘 → 水平线终点
                        Path { path in
                            path.move(to: label.sectorEdge)
                            path.addLine(to: CGPoint(x: label.lineEndX, y: label.labelY))
                        }
                        .stroke(Color.holoTextSecondary.opacity(0.4), lineWidth: 0.8)

                        // 标签文字
                        Text(label.text)
                            .font(.system(size: 9))
                            .foregroundColor(.holoTextSecondary)
                            .fixedSize()
                            .position(x: label.textCenterX, y: label.labelY)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - 外部标签布局计算

    /// 外部标签布局信息
    private struct OutsideLabelLayout {
        let index: Int
        let text: String
        let isRightSide: Bool
        let sectorEdge: CGPoint
        var lineEndX: CGFloat
        var labelY: CGFloat
        var textCenterX: CGFloat
        let textHeight: CGFloat
        var wasAdjusted: Bool
    }

    /// 计算所有外部标签的布局（含碰撞检测)
    private func computeOutsideLabelLayouts(
        center: CGPoint,
        outerRadius: CGFloat,
        total: Double
    ) -> [OutsideLabelLayout] {
        let labelFont = UIFont.systemFont(ofSize: 9)
        let bendDistance: CGFloat = 10
        let horizontalLine: CGFloat = 16

        var layouts: [OutsideLabelLayout] = []
        for (index, agg) in nonZeroAggregations.enumerated() {
            let midAngleDeg = Self.sectorMidAngle(
                index: index, aggregations: nonZeroAggregations, total: total
            )
            let radians = midAngleDeg * .pi / 180
            let isRightSide = cos(radians) >= 0
            // 扇区边缘点
            let edgeX = center.x + CGFloat(cos(radians)) * outerRadius
            let edgeY = center.y + CGFloat(sin(radians)) * outerRadius
            // 弯折点（沿径向稍外移)
            let bendX = center.x + CGFloat(cos(radians)) * (outerRadius + bendDistance)
            // 水平线终点
            let lineEndX = isRightSide
                ? bendX + horizontalLine
                : bendX - horizontalLine
            // 文本宽度(用 UIFont 精确测量)
            let text = "\(agg.category.name) \(agg.formattedPercentage)"
            let textWidth = (text as NSString).size(withAttributes: [.font: labelFont]).width
            // 文本中心 X
            let textCenterX = isRightSide
                ? lineEndX + textWidth / 2 + 2
                : lineEndX - textWidth / 2 - 2

            layouts.append(OutsideLabelLayout(
                index: index,
                text: text,
                isRightSide: isRightSide,
                sectorEdge: CGPoint(x: edgeX, y: edgeY),
                lineEndX: lineEndX,
                labelY: edgeY,
                textCenterX: textCenterX,
                textHeight: 14,
                wasAdjusted: false
            ))
        }
        return Self.resolveLabelCollisions(layouts, centerY: center.y)
    }

    /// 碰撞检测：按左右分组,组内强制最小垂直间距
    private static func resolveLabelCollisions(
        _ labels: [OutsideLabelLayout],
        centerY: CGFloat,
        minGap: CGFloat = 14
    ) -> [OutsideLabelLayout] {
        guard labels.count > 1 else { return labels }
        var rightLabels = labels.filter { $0.isRightSide }.sorted { $0.labelY < $1.labelY }
        var leftLabels = labels.filter { !$0.isRightSide }.sorted { $0.labelY < $1.labelY }
        func enforceSpacing(_ items: inout [OutsideLabelLayout]) {
            for i in 1..<items.count {
                let prevBottom = items[i - 1].labelY + items[i - 1].textHeight / 2
                let minCurrentY = prevBottom + minGap + items[i].textHeight / 2
                if items[i].labelY < minCurrentY {
                    items[i].labelY = minCurrentY
                    items[i].wasAdjusted = true
                }
            }
        }
        enforceSpacing(&rightLabels)
        enforceSpacing(&leftLabels)
        return (rightLabels + leftLabels).sorted { $0.index < $1.index }
    }

    /// 计算第 index 个扇区的中间角度(从正上方 -90° 开始顺时针)
    private static func sectorMidAngle(
        index: Int,
        aggregations: [CategoryAggregation],
        total: Double
    ) -> Double {
        var currentAngle = -90.0
        for i in 0..<index {
            let sectorAngle = (Double(truncating: aggregations[i].amount as NSDecimalNumber) / total) * 360
            currentAngle += sectorAngle
        }
        let sectorAngle = (Double(truncating: aggregations[index].amount as NSDecimalNumber) / total) * 360
        return currentAngle + sectorAngle / 2
    }

    /// 计算第 index 个扇区的起始角度
    private static func sectorStartAngle(
        index: Int,
        aggregations: [CategoryAggregation],
        total: Double
    ) -> Double {
        var angle = -90.0
        for i in 0..<index {
            angle += (Double(truncating: aggregations[i].amount as NSDecimalNumber) / total) * 360
        }
        return angle
    }

    /// 计算第 index 个扇区的跨度角度
    private static func sectorSpan(
        index: Int,
        aggregations: [CategoryAggregation],
        total: Double
    ) -> Double {
        (Double(truncating: aggregations[index].amount as NSDecimalNumber) / total) * 360
    }

    // MARK: - 中心信息

    private var centerInfo: some View {
        VStack(spacing: 2) {
            if let agg = focusedAggregation {
                Text(agg.category.name)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)
                    .transition(.opacity)
                Text(agg.formattedAmount)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(agg.category.swiftUIColor)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Text(NumberFormatter.currency.string(from: totalAmount as NSDecimalNumber) ?? "¥0")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
                Text("\(aggregations.count) 个分类")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: effectiveCategory?.id)
        .frame(width: outerCenterWidth)
    }

    /// 中心区域宽度
    private var outerCenterWidth: CGFloat { 100 }

    // MARK: - 空状态

    private var emptyChartView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "chart.pie")
                .font(.system(size: 60, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))
            Text("暂无数据")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 辅助方法

    private func colorForCategory(_ category: Category, at index: Int) -> Color {
        chartColors[index % chartColors.count]
    }
}

// MARK: - Pie Chart Interaction Overlay (UIViewRepresentable)

/// 饼图交互覆盖层
/// - 滑动手势:仅触发视觉高亮（不触发下钻)
/// - 点击手势:松手时触发实际选中/下钻
struct PieChartInteractionOverlay: UIViewRepresentable {
    let aggregations: [CategoryAggregation]
    let onHighlight: ((Category?) -> Void)?
    let onSelect: (Category?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.aggregations = aggregations

        let panGesture = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleGesture(_:))
        )
        panGesture.cancelsTouchesInView = false
        panGesture.delegate = context.coordinator
        view.addGestureRecognizer(panGesture)

        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleGesture(_:))
        )
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = context.coordinator
        view.addGestureRecognizer(tapGesture)

        return view
    }

    func updateUIView(_ uiView: InteractionView, context: Context) {
        uiView.aggregations = aggregations
        context.coordinator.parent = self
    }

    // MARK: - Interaction View

    class InteractionView: UIView {
        var aggregations: [CategoryAggregation] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = true
        }

        required init?(coder: NSCoder) { fatalError() }
        /// 只处理环形区域的触摸,其他区域放行给 ScrollView
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let dx = point.x - center.x
            let dy = point.y - center.y
            let distance = sqrt(dx * dx + dy * dy)
            let radius = min(bounds.width, bounds.height) / 2
            return distance > radius * 0.35 && distance < radius * 1.05
        }
        /// 根据触摸点计算对应的分类
        func categoryAtPoint(_ point: CGPoint) -> Category? {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let dx = point.x - center.x
            let dy = point.y - center.y
            let distance = sqrt(dx * dx + dy * dy)
            let radius = min(bounds.width, bounds.height) / 2
            guard distance > radius * 0.35 && distance < radius else { return nil }
            let rawAngle = atan2(dy, dx) * 180 / .pi
            var angle = rawAngle + 90
            if angle < 0 { angle += 360 }
            let total = aggregations.reduce(0.0) {
                $0 + Double(truncating: $1.amount as NSDecimalNumber)
            }
            guard total > 0 else { return nil }
            var currentAngle = 0.0
            for agg in aggregations {
                let sectorAngle = (Double(truncating: agg.amount as NSDecimalNumber) / total) * 360
                if angle >= currentAngle && angle < currentAngle + sectorAngle {
                    return agg.category
                }
                currentAngle += sectorAngle
            }
            return nil
        }
    }

    // MARK: - Coordinator
    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PieChartInteractionOverlay

        init(_ parent: PieChartInteractionOverlay) {
            self.parent = parent
        }

        @objc func handleGesture(_ gesture: UIGestureRecognizer) {
            guard let view = gesture.view as? InteractionView else { return }
            let location = gesture.location(in: view)
            let category = view.categoryAtPoint(location)
            if gesture is UITapGestureRecognizer {
                if gesture.state == .ended {
                    parent.onSelect(category)
                }
            } else if gesture is UIPanGestureRecognizer {
                switch gesture.state {
                case .began, .changed:
                    parent.onHighlight?(category)
                case .ended, .cancelled:
                    parent.onHighlight?(nil)
                default:
                    break
                }
            }
        }
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            return true
        }
    }
}
// MARK: - Preview
#Preview("Pie Chart") {
    VStack {
        PieChartView(
            aggregations: [],
            selectedCategory: nil
        ) { _ in }
        Spacer()
    }
    .padding()
    .background(Color.holoBackground)
}
