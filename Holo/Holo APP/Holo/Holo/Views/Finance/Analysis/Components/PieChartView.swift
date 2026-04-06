//
//  PieChartView.swift
//  Holo
//
//  环形饼图组件（用于类别 Tab）
//  使用 Canvas 自绘，支持选中扇区凸出效果
//  标签：名称在环内 + 引导线 + 占比在环外
//  支持触摸高亮 + 松手后下钻（touch down = 高亮, touch up = 导航)
//

import SwiftUI

// MARK: - PieChartView

/// 环形饼图视图
struct PieChartView: View {
    let aggregations: [CategoryAggregation]
    let selectedCategory: Category?
    /// 外部传入的颜色数组（与图例共享同一调色板，保证颜色一致）
    var colors: [Color]
    let onSelectCategory: ((Category?) -> Void)?
    var onTouchActive: ((Bool) -> Void)?

    @State private var highlightedCategory: Category?

    // MARK: - 颜色分配

    /// 扇区颜色（使用外部传入的统一调色板）
    private var sectorColors: [Color] {
        let count = nonZeroAggregations.count
        guard count > 0 else { return [] }
        if colors.count >= count { return colors }
        // 防御：颜色不足时用黄金角度补充
        return colors + (colors.count..<count).map { i in
            let hue = (Double(i) * 137.508).truncatingRemainder(dividingBy: 360) / 360
            return Color(hue: hue, saturation: 0.7, brightness: 0.85)
        }
    }

    /// 扇区凸出距离
    private let explodeDistance: CGFloat = 8
    /// 饼图缩放比例（0.7 = 缩小 30%，留出标签空间）
    private let pieScaleFactor: CGFloat = 0.7
    /// 引导线径向延伸距离
    private let labelRadialLength: CGFloat = 20
    /// 引导线水平延伸距离
    private let labelHorizontalLength: CGFloat = 12

    private var nonZeroAggregations: [CategoryAggregation] {
        aggregations.filter { $0.amount > 0 }
    }

    /// 当前视觉焦点类别（高亮优先于选中）
    private var effectiveCategory: Category? {
        highlightedCategory ?? selectedCategory
    }

    /// 焦点聚合数据（高亮或选中)，未选中时返回 nil
    private var focusedAggregation: CategoryAggregation? {
        guard let category = effectiveCategory else { return nil }
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
            Canvas { context, size in
                drawPieSectors(into: &context, size: size)
                drawLabels(into: &context, size: size)
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay {
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
                    },
                    onTouchActive: { active in
                        onTouchActive?(active)
                    }
                )
            }

            // 中心信息
            centerInfo
        }
        .onChange(of: aggregations.map(\.id)) { _, _ in
            highlightedCategory = nil
        }
    }

    // MARK: - Canvas 绘制饼图扇区

    private func drawPieSectors(into context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let fullRadius = min(size.width, size.height) / 2 - explodeDistance
        let outerRadius = fullRadius * pieScaleFactor
        let innerRadius = outerRadius * 0.5
        let insetAngle: CGFloat = 1.5

        let total = nonZeroAggregations.reduce(0.0) {
            $0 + Double(truncating: $1.amount as NSDecimalNumber)
        }
        guard total > 0 else { return }

        for (index, agg) in nonZeroAggregations.enumerated() {
            let startDeg = Self.sectorStartAngle(
                index: index, aggregations: nonZeroAggregations, total: total
            )
            let spanDeg = Self.sectorSpan(
                index: index, aggregations: nonZeroAggregations, total: total
            )
            let midDeg = startDeg + spanDeg / 2
            let midRad = midDeg * .pi / 180

            let isFocused = effectiveCategory?.id == agg.category.id
            let isDimmed = effectiveCategory != nil && !isFocused

            // 选中扇区沿角平分线方向偏移
            let cosMid = CGFloat(cos(midRad))
            let sinMid = CGFloat(sin(midRad))

            let offset: CGPoint = isFocused
                ? CGPoint(x: cosMid * explodeDistance, y: sinMid * explodeDistance)
                : .zero
            let sectorCenter = CGPoint(x: center.x + offset.x, y: center.y + offset.y)

            let path = SectorPath(
                center: sectorCenter,
                innerRadius: innerRadius,
                outerRadius: outerRadius,
                startAngle: .degrees(-startDeg + insetAngle / 2),
                endAngle: .degrees(-(startDeg + spanDeg) - insetAngle / 2),
                clockwise: true
            )

            let color = sectorColors[index]
            context.fill(
                path,
                with: .color(color.opacity(isDimmed ? 0.3 : 1.0))
            )

            if isFocused {
                context.stroke(
                    path,
                    with: .color(Color.white.opacity(0.7)),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
            }
        }
    }

    // MARK: - Canvas 绘制标签（科目名称在环内 + 20px 径向线 + 水平延伸 + 占比数字）

    private func drawLabels(into context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let fullRadius = min(size.width, size.height) / 2 - explodeDistance
        let outerRadius = fullRadius * pieScaleFactor
        let innerRadius = outerRadius * 0.5

        let total = nonZeroAggregations.reduce(0.0) {
            $0 + Double(truncating: $1.amount as NSDecimalNumber)
        }
        guard total > 0 else { return }

        for (index, agg) in nonZeroAggregations.enumerated() {
            let startDeg = Self.sectorStartAngle(
                index: index, aggregations: nonZeroAggregations, total: total
            )
            let spanDeg = Self.sectorSpan(
                index: index, aggregations: nonZeroAggregations, total: total
            )
            let midDeg = startDeg + spanDeg / 2
            let midRad = midDeg * .pi / 180

            let isFocused = effectiveCategory?.id == agg.category.id
            let isDimmed = effectiveCategory != nil && !isFocused
            let labelOpacity: Double = isDimmed ? 0.2 : 1.0

            let cosMid = CGFloat(cos(midRad))
            let sinMid = CGFloat(sin(midRad))

            // 扇区凸出偏移
            let offset: CGPoint = isFocused
                ? CGPoint(x: cosMid * explodeDistance, y: sinMid * explodeDistance)
                : .zero
            let sectorCenter = CGPoint(x: center.x + offset.x, y: center.y + offset.y)

            // 1. 科目名称：大扇区在色块内部，小扇区在引导线末端
            let isSmallSector = spanDeg < 25  // 约 < 7% 的扇区
            let isRightSide = cosMid >= 0

            if !isSmallSector {
                // 大扇区：名称在色块内部
                let nameRadius = (innerRadius + outerRadius) / 2
                let namePoint = CGPoint(
                    x: sectorCenter.x + cosMid * nameRadius,
                    y: sectorCenter.y + sinMid * nameRadius
                )
                let nameFontSize: CGFloat = spanDeg > 40 ? 10 : 8
                context.draw(
                    Text(agg.category.name)
                        .font(.system(size: nameFontSize, weight: .medium))
                        .foregroundColor(.white.opacity(labelOpacity)),
                    at: namePoint
                )
            }

            // 2. 引导线：从外边缘沿径向延伸 20px
            let lineStart = CGPoint(
                x: center.x + cosMid * (outerRadius + 1),
                y: center.y + sinMid * (outerRadius + 1)
            )
            // 弯折点（径向 20px）
            let bendPoint = CGPoint(
                x: center.x + cosMid * (outerRadius + labelRadialLength),
                y: center.y + sinMid * (outerRadius + labelRadialLength)
            )

            // 3. 水平延伸
            let lineEndX = isRightSide
                ? bendPoint.x + labelHorizontalLength
                : bendPoint.x - labelHorizontalLength

            // 绘制引导线（两段：径向 + 水平）
            var linePath = Path()
            linePath.move(to: lineStart)
            linePath.addLine(to: bendPoint)
            linePath.addLine(to: CGPoint(x: lineEndX, y: bendPoint.y))
            context.stroke(
                linePath,
                with: .color(Color.holoTextSecondary.opacity(labelOpacity * 0.5)),
                lineWidth: 0.8
            )

            // 4. 占比数字（水平线末端）
            let textPoint = CGPoint(
                x: isRightSide ? lineEndX + 3 : lineEndX - 3,
                y: bendPoint.y
            )

            if isSmallSector {
                // 小扇区：名称 + 占比都在引导线末端
                let combinedText = "\(agg.category.name) \(agg.formattedPercentage)"
                context.draw(
                    Text(combinedText)
                        .font(.system(size: 9))
                        .foregroundColor(Color.holoTextSecondary.opacity(labelOpacity)),
                    at: textPoint,
                    anchor: isRightSide ? .leading : .trailing
                )
            } else {
                // 大扇区：只显示占比
                context.draw(
                    Text(agg.formattedPercentage)
                        .font(.system(size: 9))
                        .foregroundColor(Color.holoTextSecondary.opacity(labelOpacity)),
                    at: textPoint,
                    anchor: isRightSide ? .leading : .trailing
                )
            }
        }
    }

    // MARK: - 角度计算

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
            }
        }
        .animation(.easeInOut(duration: 0.25), value: effectiveCategory?.id)
    }

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
        sectorColors[index]
    }
}

// MARK: - Sector Path Helper

/// 绘制环形扇区的 Path
private func SectorPath(
    center: CGPoint,
    innerRadius: CGFloat,
    outerRadius: CGFloat,
    startAngle: Angle,
    endAngle: Angle,
    clockwise: Bool
) -> Path {
    Path { path in
        path.addArc(
            center: center,
            radius: outerRadius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: clockwise
        )
        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: endAngle,
            endAngle: startAngle,
            clockwise: !clockwise
        )
        path.closeSubpath()
    }
}

// MARK: - Pie Chart Interaction Overlay (UIViewRepresentable)

/// 饼图交互覆盖层
/// - 滑动手势:仅触发视觉高亮（不触发下钻)
/// - 点击手势:松手时触发实际选中/下钻
/// - onTouchActive: 通知外部是否正在触摸饼图（用于禁用 ScrollView)
struct PieChartInteractionOverlay: UIViewRepresentable {
    let aggregations: [CategoryAggregation]
    let onHighlight: ((Category?) -> Void)?
    let onSelect: (Category?) -> Void
    var onTouchActive: ((Bool) -> Void)?

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

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let dx = point.x - center.x
            let dy = point.y - center.y
            let distance = sqrt(dx * dx + dy * dy)
            let radius = min(bounds.width, bounds.height) / 2
            return distance > radius * 0.35 && distance < radius * 1.05
        }

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
                    parent.onTouchActive?(true)
                    parent.onHighlight?(category)
                case .ended, .cancelled:
                    parent.onTouchActive?(false)
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
            selectedCategory: nil,
            colors: []
        ) { _ in }
        Spacer()
    }
    .padding()
    .background(Color.holoBackground)
}
