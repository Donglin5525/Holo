//
//  PieChartView.swift
//  Holo
//
//  环形饼图组件（用于类别 Tab）
//  使用 Canvas 自绘，支持选中扇区凸出效果
//  标签：名称在环内 + 引导线 + 占比在环外
//  点击负责选中，指针悬停/横向移动负责临时查看金额；纵向拖动交给页面滚动
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - PieChartView

/// 环形饼图视图
struct PieChartView: View {
    let aggregations: [CategoryAggregation]
    let selectedCategory: Category?
    /// 外部传入的颜色数组（与图例共享同一调色板，保证颜色一致）
    var colors: [Color]
    let onSelectCategory: ((Category?) -> Void)?

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
        // 过滤零值并按 category.id 去重，合并金额
        var merged: [UUID: CategoryAggregation] = [:]
        var order: [UUID] = []
        for agg in aggregations where agg.amount > 0 {
            if let existing = merged[agg.category.id] {
                merged[agg.category.id] = CategoryAggregation(
                    category: existing.category,
                    amount: existing.amount + agg.amount,
                    percentage: existing.percentage + agg.percentage,
                    transactionCount: existing.transactionCount + agg.transactionCount
                )
            } else {
                merged[agg.category.id] = agg
                order.append(agg.category.id)
            }
        }
        return order.compactMap { merged[$0] }
    }

    /// 当前视觉焦点类别
    private var effectiveCategory: Category? {
        highlightedCategory ?? selectedCategory
    }

    /// 焦点聚合数据，未选中时返回 nil
    private var focusedAggregation: CategoryAggregation? {
        guard let category = effectiveCategory else { return nil }
        return nonZeroAggregations.first { $0.category.id == category.id }
    }

    // 总金额
    private var totalAmount: Decimal {
        nonZeroAggregations.reduce(0) { $0 + $1.amount }
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
                GeometryReader { geo in
                    PieChartTouchOverlay(
                        onTap: { location in
                            let category = categoryAtPoint(location, canvasSize: geo.size)
                            onSelectCategory?(category)
                        },
                        onMove: { location in
                            let category = categoryAtPoint(location, canvasSize: geo.size)
                            withAnimation(.easeInOut(duration: 0.12)) {
                                highlightedCategory = category
                            }
                        },
                        onMoveEnded: {
                            highlightedCategory = nil
                        }
                    )
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let category = categoryAtPoint(location, canvasSize: geo.size)
                                withAnimation(.easeInOut(duration: 0.12)) {
                                    highlightedCategory = category
                                }
                            case .ended:
                                highlightedCategory = nil
                            }
                        }
                }
            }

            // 中心信息
            centerInfo
        }
        .onChange(of: aggregations.map(\.id)) { _, _ in
            highlightedCategory = nil
        }
    }

    // MARK: - 触摸位置 → 扇区映射

    /// 根据触摸点计算对应的分类（使用 SwiftUI 坐标系，与 Canvas 完全一致）
    private func categoryAtPoint(_ point: CGPoint, canvasSize: CGSize) -> Category? {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)

        let fullRadius = min(canvasSize.width, canvasSize.height) / 2 - explodeDistance
        let outerR = fullRadius * pieScaleFactor
        let innerR = outerR * 0.5

        // 触摸范围：环形区域 + 少量边距
        guard distance > innerR - 8 && distance < outerR + explodeDistance + 4 else { return nil }

        // ★ 触摸角度（atan2 约定：0°=右，正值=下方，与 addArc / cos-sin 坐标系一致）
        let touchAngle = atan2(dy, dx) * 180 / .pi

        let total = nonZeroAggregations.reduce(0.0) {
            $0 + Double(truncating: $1.amount as NSDecimalNumber)
        }
        guard total > 0 else { return nil }

        // 遍历扇区，用角距离判断命中
        for (index, agg) in nonZeroAggregations.enumerated() {
            let startDeg = Self.sectorStartAngle(
                index: index, aggregations: nonZeroAggregations, total: total
            )
            let spanDeg = Self.sectorSpan(
                index: index, aggregations: nonZeroAggregations, total: total
            )

            // 扇区在 addArc/atan2 坐标系中的中点角度 = -midDeg
            let midDeg = startDeg + spanDeg / 2
            let sectorMidAngle = -midDeg

            // 计算触摸角度与扇区中点的角距离（处理 -180°/180° 边界）
            var diff = touchAngle - sectorMidAngle
            while diff > 180 { diff -= 360 }
            while diff < -180 { diff += 360 }

            if abs(diff) <= spanDeg / 2 {
                return agg.category
            }
        }
        return nil
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
            // 使用 -midDeg 匹配 addArc 视觉坐标系（addArc 使用 -startDeg）
            let drawMidRad = -midDeg * .pi / 180

            let isFocused = effectiveCategory?.id == agg.category.id
            let hasFocusedCategory = effectiveCategory != nil

            // 选中扇区沿角平分线方向偏移（方向匹配视觉位置）
            let cosMid = CGFloat(cos(drawMidRad))
            let sinMid = CGFloat(sin(drawMidRad))

            let offset: CGPoint = isFocused
                ? CGPoint(x: cosMid * explodeDistance, y: sinMid * explodeDistance)
                : .zero
            let sectorCenter = CGPoint(x: center.x + offset.x, y: center.y + offset.y)
            let sectorInset = CGFloat(PieChartInteractionStyle.sectorInsetAngle(
                spanAngle: spanDeg,
                preferredInset: Double(insetAngle)
            ))

            let path = SectorPath(
                center: sectorCenter,
                innerRadius: innerRadius,
                outerRadius: outerRadius,
                startAngle: .degrees(-startDeg - sectorInset / 2),
                endAngle: .degrees(-(startDeg + spanDeg) + sectorInset / 2),
                clockwise: true
            )

            let color = sectorColors[index]
            context.fill(
                path,
                with: .color(color.opacity(PieChartInteractionStyle.sectorOpacity(
                    isFocused: isFocused,
                    hasFocusedCategory: hasFocusedCategory
                )))
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

    // MARK: - Canvas 绘制标签

    private func drawLabels(into context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let fullRadius = min(size.width, size.height) / 2 - explodeDistance
        let outerRadius = fullRadius * pieScaleFactor
        let innerRadius = outerRadius * 0.5

        let total = nonZeroAggregations.reduce(0.0) {
            $0 + Double(truncating: $1.amount as NSDecimalNumber)
        }
        guard total > 0 else { return }

        // MARK: Step 1 - 计算所有标签初始位置

        struct LabelLayout {
            let index: Int
            let agg: CategoryAggregation
            let lineStart: CGPoint
            var bendY: CGFloat          // var：可被碰撞调整修改
            let bendX: CGFloat
            let isRightSide: Bool
            let isSmallSector: Bool
            let labelOpacity: Double
            let namePoint: CGPoint?
            let nameFontSize: CGFloat
            let cosMid: CGFloat
        }

        var layouts: [LabelLayout] = []

        for (index, agg) in nonZeroAggregations.enumerated() {
            let startDeg = Self.sectorStartAngle(
                index: index, aggregations: nonZeroAggregations, total: total
            )
            let spanDeg = Self.sectorSpan(
                index: index, aggregations: nonZeroAggregations, total: total
            )
            let midDeg = startDeg + spanDeg / 2

            // ★ 核心修正：使用 -midDeg 匹配 addArc 视觉坐标系
            // addArc 绘制使用 -startDeg，所以扇区视觉中点在 -midDeg 方向
            let drawMidRad = -midDeg * .pi / 180
            let cosMid = CGFloat(cos(drawMidRad))
            let sinMid = CGFloat(sin(drawMidRad))

            let isFocused = effectiveCategory?.id == agg.category.id
            let labelOpacity = PieChartInteractionStyle.labelOpacity(
                isFocused: isFocused,
                hasFocusedCategory: effectiveCategory != nil
            )

            let isSmallSector = spanDeg < 30
            let isRightSide = cosMid >= 0

            // 选中扇区偏移（用于扇区内部名称定位）
            let offset: CGPoint = isFocused
                ? CGPoint(x: cosMid * explodeDistance, y: sinMid * explodeDistance)
                : .zero
            let sectorCenter = CGPoint(x: center.x + offset.x, y: center.y + offset.y)

            // 大扇区：名称在色块内部（跟随选中偏移）
            let namePoint: CGPoint? = isSmallSector ? nil : {
                let nameRadius = (innerRadius + outerRadius) / 2
                return CGPoint(
                    x: sectorCenter.x + cosMid * nameRadius,
                    y: sectorCenter.y + sinMid * nameRadius
                )
            }()
            let nameFontSize: CGFloat = spanDeg > 45 ? 11 : 9

            // 引导线起点：扇区外边缘（固定，不随选中移动）
            let lineStart = CGPoint(
                x: center.x + cosMid * (outerRadius + 1),
                y: center.y + sinMid * (outerRadius + 1)
            )

            // 引导线弯折点（X 固定，Y 可被碰撞调整）
            let bendX = center.x + cosMid * (outerRadius + labelRadialLength)
            let bendY = center.y + sinMid * (outerRadius + labelRadialLength)

            layouts.append(LabelLayout(
                index: index,
                agg: agg,
                lineStart: lineStart,
                bendY: bendY,
                bendX: bendX,
                isRightSide: isRightSide,
                isSmallSector: isSmallSector,
                labelOpacity: labelOpacity,
                namePoint: namePoint,
                nameFontSize: nameFontSize,
                cosMid: cosMid
            ))
        }

        // MARK: Step 2 - Y 轴防碰撞偏移

        let minLabelSpacing: CGFloat = 16

        func resolveCollisions(_ group: inout [LabelLayout]) {
            guard group.count > 1 else { return }
            group.sort { $0.bendY < $1.bendY }

            // 迭代推挤直到无碰撞（最多 10 轮防止死循环）
            for _ in 0..<10 {
                var adjusted = false
                for i in 1..<group.count {
                    let gap = group[i].bendY - group[i - 1].bendY
                    if gap < minLabelSpacing {
                        let push = (minLabelSpacing - gap) / 2
                        group[i - 1].bendY -= push
                        group[i].bendY += push
                        adjusted = true
                    }
                }
                if !adjusted { break }
            }
        }

        var rightGroup = layouts.filter { $0.isRightSide }
        var leftGroup = layouts.filter { !$0.isRightSide }
        resolveCollisions(&rightGroup)
        resolveCollisions(&leftGroup)

        // 合并回 layouts（按原 index 排序，保持颜色对应）
        layouts = (rightGroup + leftGroup).sorted { $0.index < $1.index }

        // MARK: Step 3 - 绘制所有标签

        for layout in layouts {
            let agg = layout.agg
            let isRightSide = layout.isRightSide
            let isSmallSector = layout.isSmallSector
            let labelOpacity = layout.labelOpacity

            // 大扇区：绘制内部名称
            if !isSmallSector, let namePoint = layout.namePoint {
                context.draw(
                    Text(agg.category.name)
                        .font(.system(size: layout.nameFontSize, weight: .medium))
                        .foregroundColor(.white.opacity(labelOpacity)),
                    at: namePoint
                )
            }

            // 引导线：扇区边缘 → 弯折点 → 水平延伸
            let bendPoint = CGPoint(x: layout.bendX, y: layout.bendY)
            let lineEndX = isRightSide
                ? bendPoint.x + labelHorizontalLength
                : bendPoint.x - labelHorizontalLength

            var linePath = Path()
            linePath.move(to: layout.lineStart)
            linePath.addLine(to: bendPoint)
            linePath.addLine(to: CGPoint(x: lineEndX, y: layout.bendY))
            context.stroke(
                linePath,
                with: .color(Color.holoTextSecondary.opacity(labelOpacity * 0.5)),
                lineWidth: 0.8
            )

            // 引导线末端标签
            let textPoint = CGPoint(
                x: isRightSide ? lineEndX + 3 : lineEndX - 3,
                y: layout.bendY
            )

            if isSmallSector {
                let combinedText = "\(agg.category.name) \(agg.formattedPercentage)"
                context.draw(
                    Text(combinedText)
                        .font(.system(size: 9))
                        .foregroundColor(Color.holoTextSecondary.opacity(labelOpacity)),
                    at: textPoint,
                    anchor: isRightSide ? .leading : .trailing
                )
            } else {
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
                Text(agg.formattedCompactAmount)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(focusedColor(for: agg.category) ?? agg.category.swiftUIColor)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Text(NumberFormatter.compactCurrency(totalAmount))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: effectiveCategory?.id)
    }

    private func focusedColor(for category: Category) -> Color? {
        guard let index = nonZeroAggregations.firstIndex(where: { $0.category.id == category.id }),
              sectorColors.indices.contains(index) else {
            return nil
        }
        return sectorColors[index]
    }

    // MARK: - 空状态

    private var emptyChartView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "chart.pie")
                .font(.system(size: 60, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))
            Text("暂无数据，这就开始记一笔吧！")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(height: 300)
        .frame(maxWidth: .infinity)
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

#if canImport(UIKit)
private struct PieChartTouchOverlay: UIViewRepresentable {
    let onTap: (CGPoint) -> Void
    let onMove: (CGPoint) -> Void
    let onMoveEnded: () -> Void

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.backgroundColor = .clear

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)

        return view
    }

    func updateUIView(_ uiView: TouchView, context: Context) {
        context.coordinator.overlay = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(overlay: self)
    }

    final class TouchView: UIView {
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            bounds.contains(point)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var overlay: PieChartTouchOverlay

        init(overlay: PieChartTouchOverlay) {
            self.overlay = overlay
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view, recognizer.state == .ended else { return }
            overlay.onTap(recognizer.location(in: view))
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began, .changed:
                overlay.onMove(recognizer.location(in: view))
            case .ended, .cancelled, .failed:
                overlay.onMoveEnded()
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else {
                return true
            }
            let translation = pan.translation(in: view)
            return PieChartInteractionStyle.shouldTrackHighlight(
                translation: CGSize(width: translation.x, height: translation.y)
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif
