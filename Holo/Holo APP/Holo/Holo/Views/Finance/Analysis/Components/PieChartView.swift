//
//  PieChartView.swift
//  Holo
//
//  环形饼图组件（全项目标准通用件，2026-10-07 拍板）：输入通用扇区 PieChartSegment，
//  财务类别 Tab 经旧签名便捷入口映射使用；其他模块（任务/习惯…）直接传扇区。
//  使用 Canvas 自绘，支持选中扇区凸出效果
//  标签：名称在环内 + 引导线 + 占比在环外
//  点击负责选中，指针悬停/横向移动负责临时查看数值；纵向拖动交给页面滚动
//

import SwiftUI

// MARK: - 通用扇区输入

/// 通用环形图扇区：weight 为扇区权重（>0），valueText 为选中时中心文案（金额/件数…），
/// id 为稳定身份（去重合并键，也是选中态与回调的对账键）
struct PieChartSegment: Identifiable, Equatable {
    let id: String
    let name: String
    let weight: Double
    let valueText: String

    /// 引导线占比文案（与旧 formattedPercentage 同口径）
    func percentageText(total: Double) -> String {
        guard total > 0 else { return "0%" }
        return String(format: "%.1f%%", weight / total * 100)
    }
}

// MARK: - PieChartView

/// 环形饼图视图
struct PieChartView: View {
    var motion = HoloContinuousMotion()
    var segments: [PieChartSegment]
    var selectedSegmentID: String?
    /// 外部传入的颜色数组（与图例共享同一调色板，保证颜色一致）
    var colors: [Color]
    /// 未选中时中心汇总文案（如「¥1.2万」「23 件」）
    var centerIdleText: String = ""
    var emptyText: String = String(localized: "暂无数据，这就开始记一笔吧！")
    var onSelectSegment: ((PieChartSegment?) -> Void)?

    @State private var highlightedSegmentID: String?

    /// 出场扫开动画：nil = 停帧（播完/未播）。TimelineView 只在非 nil 的 0.5s 内逐帧驱动 Canvas，
    /// 播完置回 nil 恢复停帧，不引入常驻逐帧开销
    @State private var sweepStart: Date?

    /// 扇区扫开总时长（秒）
    private static let sweepDuration: Double = 0.45

    init(
        motion: HoloContinuousMotion = HoloContinuousMotion(),
        segments: [PieChartSegment],
        selectedSegmentID: String? = nil,
        colors: [Color],
        centerIdleText: String = "",
        emptyText: String = String(localized: "暂无数据，这就开始记一笔吧！"),
        onSelectSegment: ((PieChartSegment?) -> Void)? = nil
    ) {
        self.motion = motion
        self.segments = segments
        self.selectedSegmentID = selectedSegmentID
        self.colors = colors
        self.centerIdleText = centerIdleText
        self.emptyText = emptyText
        self.onSelectSegment = onSelectSegment
    }

    /// 财务旧签名便捷入口（类别 Tab 原调用零改动）：CategoryAggregation 映射为通用扇区
    init(
        aggregations: [CategoryAggregation],
        selectedCategory: Category?,
        colors: [Color],
        onSelectCategory: ((Category?) -> Void)?
    ) {
        let positive = aggregations.filter { $0.amount > 0 }
        self.init(
            segments: positive.map { agg in
                PieChartSegment(
                    id: agg.category.id.uuidString,
                    name: agg.category.name,
                    weight: Double(truncating: agg.amount as NSDecimalNumber),
                    valueText: agg.formattedCompactAmount
                )
            },
            selectedSegmentID: selectedCategory?.id.uuidString,
            colors: colors,
            centerIdleText: NumberFormatter.compactCurrency(positive.reduce(0) { $0 + $1.amount }),
            onSelectSegment: { segment in
                guard let segment else {
                    onSelectCategory?(nil)
                    return
                }
                onSelectCategory?(positive.first { $0.category.id.uuidString == segment.id }?.category)
            }
        )
    }

    // MARK: - 颜色分配

    /// 扇区颜色（使用外部传入的统一调色板）
    private var sectorColors: [Color] {
        let count = mergedSegments.count
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

    private var mergedSegments: [PieChartSegment] {
        // 过滤零值并按 id 去重，合并权重（延续旧 CategoryAggregation 合并行为）
        var merged: [String: PieChartSegment] = [:]
        var order: [String] = []
        for segment in segments where segment.weight > 0 {
            if let existing = merged[segment.id] {
                merged[segment.id] = PieChartSegment(
                    id: existing.id,
                    name: existing.name,
                    weight: existing.weight + segment.weight,
                    valueText: existing.valueText
                )
            } else {
                merged[segment.id] = segment
                order.append(segment.id)
            }
        }
        return order.compactMap { merged[$0] }
    }

    /// 当前视觉焦点扇区
    private var effectiveSegment: PieChartSegment? {
        let id = highlightedSegmentID ?? selectedSegmentID
        return mergedSegments.first { $0.id == id }
    }

    // 总权重
    private var totalWeight: Double {
        mergedSegments.reduce(0) { $0 + $1.weight }
    }

    var body: some View {
        VStack(spacing: HoloSpacing.md) {
            if mergedSegments.isEmpty {
                emptyChartView
            } else {
                pieChartContent
            }
        }
    }

    // MARK: - 饼图主体

    private var pieChartContent: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: nil, paused: sweepStart == nil || !motion.isActive)) { timeline in
                Canvas { context, size in
                    let sweep = sweepProgress(at: timeline.date)
                    drawPieSectors(into: &context, size: size, sweep: sweep)
                    drawLabels(into: &context, size: size, alpha: sweep)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    DirectionalChartGestureOverlay(
                        onChanged: { location in
                            let segment = segmentAtPoint(location, canvasSize: geo.size)
                            guard segment?.id != highlightedSegmentID else { return }
                            withAnimation(motion.isActive ? HoloAnimation.quick : nil) {
                                highlightedSegmentID = segment?.id
                            }
                        },
                        onEnded: { _ in
                            highlightedSegmentID = nil
                        },
                        onCancelled: {
                            highlightedSegmentID = nil
                        },
                        onTap: { location in
                            let segment = segmentAtPoint(location, canvasSize: geo.size)
                            onSelectSegment?(segment)
                        }
                    )
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let segment = segmentAtPoint(location, canvasSize: geo.size)
                                withAnimation(motion.isActive ? HoloAnimation.quick : nil) {
                                    highlightedSegmentID = segment?.id
                                }
                            case .ended:
                                highlightedSegmentID = nil
                            }
                        }
                }
            }

            // 中心信息
            centerInfo
        }
        .onAppear {
            replaySweep()
        }
        .onDisappear { sweepStart = nil }
        .onChange(of: motion.isActive) { _, active in
            if !active { sweepStart = nil }
        }
        // 切时间范围/期间等导致分布变化时重播扫开；纯交互（选中/悬停）不触发
        .onChange(of: weightSignature) { _, _ in
            replaySweep()
        }
        .onChange(of: segments.map(\.id)) { _, _ in
            highlightedSegmentID = nil
        }
    }

    // MARK: - 扫开动画

    /// 权重序列指纹：分布变化（非交互）才重播出场扫开
    private var weightSignature: [Double] {
        mergedSegments.map(\.weight)
    }

    private func replaySweep() {
        guard motion.isActive else { sweepStart = nil; return }
        let start = Date()
        sweepStart = start
        // 播完停帧：TimelineView paused 恢复 true；若期间又重播（start 已被替换）则由新任务接管
        Task {
            try? await Task.sleep(for: .seconds(Self.sweepDuration + 0.1))
            if sweepStart == start {
                sweepStart = nil
            }
        }
    }

    private func sweepProgress(at date: Date) -> Double {
        guard motion.isActive, let sweepStart else { return 1 }
        return min(1, max(0, date.timeIntervalSince(sweepStart) / Self.sweepDuration))
    }

    // MARK: - 触摸位置 → 扇区映射

    /// 根据触摸点计算对应的扇区（使用 SwiftUI 坐标系，与 Canvas 完全一致）
    private func segmentAtPoint(_ point: CGPoint, canvasSize: CGSize) -> PieChartSegment? {
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

        let total = totalWeight
        guard total > 0 else { return nil }

        // 遍历扇区，用角距离判断命中
        for (index, segment) in mergedSegments.enumerated() {
            let startDeg = Self.sectorStartAngle(
                index: index, segments: mergedSegments, total: total
            )
            let spanDeg = Self.sectorSpan(
                index: index, segments: mergedSegments, total: total
            )

            // 扇区在 addArc/atan2 坐标系中的中点角度 = -midDeg
            let midDeg = startDeg + spanDeg / 2
            let sectorMidAngle = -midDeg

            // 计算触摸角度与扇区中点的角距离（处理 -180°/180° 边界）
            var diff = touchAngle - sectorMidAngle
            while diff > 180 { diff -= 360 }
            while diff < -180 { diff += 360 }

            if abs(diff) <= spanDeg / 2 {
                return segment
            }
        }
        return nil
    }

    // MARK: - Canvas 绘制饼图扇区

    private func drawPieSectors(into context: inout GraphicsContext, size: CGSize, sweep: Double = 1) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let fullRadius = min(size.width, size.height) / 2 - explodeDistance
        let outerRadius = fullRadius * pieScaleFactor
        let innerRadius = outerRadius * 0.5
        let insetAngle: CGFloat = 1.5

        let total = totalWeight
        guard total > 0 else { return }

        for (index, segment) in mergedSegments.enumerated() {
            // 出场扫开：各扇区自 12 点方向按最终占比同步展开（sweep 0→1）
            let rawStart = Self.sectorStartAngle(
                index: index, segments: mergedSegments, total: total
            )
            let rawSpan = Self.sectorSpan(
                index: index, segments: mergedSegments, total: total
            )
            let startDeg = -90.0 + (rawStart + 90.0) * sweep
            let spanDeg = rawSpan * sweep
            let midDeg = startDeg + spanDeg / 2
            // 使用 -midDeg 匹配 addArc 视觉坐标系（addArc 使用 -startDeg）
            let drawMidRad = -midDeg * .pi / 180

            let isFocused = effectiveSegment?.id == segment.id
            let hasFocusedSegment = effectiveSegment != nil

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
                    hasFocusedCategory: hasFocusedSegment
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

    private func drawLabels(into context: inout GraphicsContext, size: CGSize, alpha: Double = 1) {
        // 出场扫开期间标签随进度整体渐显（GraphicsContext.opacity 对后续所有绘制生效）
        context.opacity = alpha
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let fullRadius = min(size.width, size.height) / 2 - explodeDistance
        let outerRadius = fullRadius * pieScaleFactor
        let innerRadius = outerRadius * 0.5

        let total = totalWeight
        guard total > 0 else { return }

        // MARK: Step 1 - 计算所有标签初始位置

        struct LabelLayout {
            let index: Int
            let segment: PieChartSegment
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

        for (index, segment) in mergedSegments.enumerated() {
            let startDeg = Self.sectorStartAngle(
                index: index, segments: mergedSegments, total: total
            )
            let spanDeg = Self.sectorSpan(
                index: index, segments: mergedSegments, total: total
            )
            let midDeg = startDeg + spanDeg / 2

            // ★ 核心修正：使用 -midDeg 匹配 addArc 视觉坐标系
            // addArc 绘制使用 -startDeg，所以扇区视觉中点在 -midDeg 方向
            let drawMidRad = -midDeg * .pi / 180
            let cosMid = CGFloat(cos(drawMidRad))
            let sinMid = CGFloat(sin(drawMidRad))

            let isFocused = effectiveSegment?.id == segment.id
            let labelOpacity = PieChartInteractionStyle.labelOpacity(
                isFocused: isFocused,
                hasFocusedCategory: effectiveSegment != nil
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
                segment: segment,
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
            let segment = layout.segment
            let isRightSide = layout.isRightSide
            let isSmallSector = layout.isSmallSector
            let labelOpacity = layout.labelOpacity

            // 大扇区：绘制内部名称
            if !isSmallSector, let namePoint = layout.namePoint {
                context.draw(
                    Text(segment.name)
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

            // 引导线末端标签（小扇区名字并入文本，大扇区只画百分比，名字在扇区内部）
            let textPoint = CGPoint(
                x: isRightSide ? lineEndX + 3 : lineEndX - 3,
                y: layout.bendY
            )

            let percentage = segment.percentageText(total: total)
            let label: Text = isSmallSector
                ? Text("\(segment.name) \(percentage)")
                    .font(.system(size: 9))
                    .foregroundColor(Color.holoToolTextSecondary.opacity(labelOpacity))
                : Text(percentage)
                    .font(.system(size: 9))
                    .foregroundColor(Color.holoToolTextSecondary.opacity(labelOpacity))

            // 标签完整可见钳制：正左/正右方向的弯折点离画布边缘不足一个文本宽时，
            // 锚点式绘制会把首（尾）字符画出画布被裁（实锤：「16.2%」被裁成「6.2%）。
            // 实测文本宽度，连同引导线水平段终点一起收回画布内。
            let textSize = context.resolve(label)
                .measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            var clampedTextX = textPoint.x
            var clampedLineEndX = lineEndX
            if isRightSide {
                // 左锚：文本右缘 = x + width，不得超出画布右缘
                let overflow = clampedTextX + textSize.width - size.width
                if overflow > 0 {
                    clampedTextX -= overflow
                    clampedLineEndX = max(bendPoint.x, clampedTextX - 3)
                }
            } else {
                // 右锚：文本左缘 = x - width，不得越出画布左缘
                let overflow = textSize.width - clampedTextX
                if overflow > 0 {
                    clampedTextX += overflow
                    clampedLineEndX = min(bendPoint.x, clampedTextX + 3)
                }
            }

            var linePath = Path()
            linePath.move(to: layout.lineStart)
            linePath.addLine(to: bendPoint)
            linePath.addLine(to: CGPoint(x: clampedLineEndX, y: layout.bendY))
            context.stroke(
                linePath,
                with: .color(Color.holoToolTextSecondary.opacity(labelOpacity * 0.5)),
                lineWidth: 0.8
            )

            context.draw(
                label,
                at: CGPoint(x: clampedTextX, y: layout.bendY),
                anchor: isRightSide ? .leading : .trailing
            )
        }
    }

    // MARK: - 角度计算

    private static func sectorStartAngle(
        index: Int,
        segments: [PieChartSegment],
        total: Double
    ) -> Double {
        var angle = -90.0
        for i in 0..<index {
            angle += (segments[i].weight / total) * 360
        }
        return angle
    }

    private static func sectorSpan(
        index: Int,
        segments: [PieChartSegment],
        total: Double
    ) -> Double {
        (segments[index].weight / total) * 360
    }

    // MARK: - 中心信息

    private var centerInfo: some View {
        VStack(spacing: 2) {
            if let segment = effectiveSegment {
                Text(segment.name)
                    .font(.holoCaption)
                    .foregroundColor(.holoToolText)
                    .lineLimit(1)
                    .transition(.opacity)
                Text(segment.valueText)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(focusedColor(for: segment) ?? .holoToolText)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Text(centerIdleText)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.holoToolText)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
        }
        .animation(HoloAnimation.smooth, value: effectiveSegment?.id)
    }

    private func focusedColor(for segment: PieChartSegment) -> Color? {
        guard let index = mergedSegments.firstIndex(where: { $0.id == segment.id }),
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
                .foregroundColor(.holoToolTextSecondary.opacity(0.5))
            Text(emptyText)
                .font(.holoCaption)
                .foregroundColor(.holoToolTextSecondary)
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
            segments: [
                PieChartSegment(id: "a", name: "工作", weight: 12, valueText: "12 件"),
                PieChartSegment(id: "b", name: "生活", weight: 6, valueText: "6 件"),
                PieChartSegment(id: "c", name: "学习", weight: 3, valueText: "3 件")
            ],
            selectedSegmentID: nil,
            colors: Color.holoChartColors(count: 3),
            centerIdleText: "23 件"
        )
        Spacer()
    }
    .padding()
    .background(Color.holoToolBackground)
}
