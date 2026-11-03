import SwiftUI
import Charts
import UIKit

struct HoloDonutSegment: Identifiable {
    let id: String
    let name: String
    let weight: Double
    let valueText: String
    let color: Color
}

struct HoloDonutChart: View {
    let segments: [HoloDonutSegment]
    let selectedID: String?
    var centerText = ""
    var showsList = true
    /// 环外引导线标注（名称/占比示意线）。2026-11-01 东林反馈找回：
    /// 10-17 组件化时旧自绘版「名称在环内 + 引导线 + 占比在环外」被原生 SectorMark 替换后遗失，
    /// 图例又被隐藏，颜色与内容失去对应。引导线与标注由本组件统一承担（图表规范：唯一实现）。
    var showsLeaderLabels = true
    var onSelect: ((String?) -> Void)? = nil
    @State private var inspectedID: String?
    private var focused: String? { selectedID ?? inspectedID }
    private var total: Double { segments.reduce(0) { $0 + $1.weight } }

    var body: some View {
        VStack(spacing: 12) {
            Chart(segments) { segment in
                SectorMark(angle: .value("占比", segment.weight), innerRadius: .ratio(0.68), angularInset: 1.5)
                    .cornerRadius(3)
                    .foregroundStyle(segment.color)
                    .annotation(position: .overlay) {
                        // 引导线模式下选中态由末端标签高亮表达，小圆点只在无标注时兜底
                        if focused == segment.id && !showsLeaderLabels {
                            Circle().fill(Color.holoToolSurface).frame(width: 7, height: 7)
                        }
                    }
                    .accessibilityLabel(segment.name)
                    .accessibilityValue("\(segment.valueText)，\(percentage(segment))")
            }
            .chartLegend(.hidden)
            .chartPlotStyle { plot in
                // 引导线模式压缩圆径、上下留出折线空间。
                // 不加水平 padding：plot 矩形加宽不会放大圆（圆径由高度决定且居中），
                // 标签列挂圆边缘（见 DonutLeaderLabelCanvas），两侧空白自然成为标签区
                plot.padding(.vertical, showsLeaderLabels ? 20 : 0)
            }
            .chartBackground { _ in
                VStack(spacing: 3) {
                    Text(segments.first { $0.id == focused }?.name ?? "合计")
                        .font(.caption).foregroundStyle(Color.holoToolTextSecondary)
                    Text(segments.first { $0.id == focused }?.valueText ?? centerText)
                        .font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(Color.holoToolText)
                }.padding(24).allowsHitTesting(false)
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let anchor = proxy.plotFrame {
                        let frame = geometry[anchor]
                        ZStack {
                            if showsLeaderLabels {
                                DonutLeaderLabelCanvas(segments: segments, focused: focused,
                                                       plotFrame: frame, canvasSize: geometry.size)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                            DirectionalChartGestureOverlay(onChanged: { select($0, frame: frame) }, onEnded: { _ in }, onCancelled: {},
                                                           onTap: { select($0, frame: frame) })
                        }
                    }
                }
            }
            .frame(height: 200)
            if showsList {
            ForEach(segments) { segment in
                Button { apply(segment.id) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(segment.color).frame(width: 8, height: 8)
                        Text(segment.name).foregroundStyle(Color.holoToolText)
                        Spacer(minLength: 4)
                        Text(segment.valueText).foregroundStyle(Color.holoToolText).monospacedDigit()
                        Text(percentage(segment)).foregroundStyle(Color.holoToolTextSecondary).monospacedDigit()
                    }
                    .font(.subheadline).padding(.horizontal, 8).frame(minHeight: 44)
                    .background(focused == segment.id ? Color.holoToolInset : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("holo.donut.segment.\(segment.id)")
            }
            }
        }
        .onChange(of: segments.map { "\($0.id):\($0.weight)" }) { _, _ in inspectedID = nil }
        .onChange(of: selectedID) { _, id in inspectedID = id }
    }

    private func percentage(_ segment: HoloDonutSegment) -> String {
        String(format: "%.1f%%", total > 0 ? segment.weight / total * 100 : 0)
    }

    private func select(_ point: CGPoint, frame: CGRect) {
        let dx = point.x - frame.midX, dy = point.y - frame.midY
        let radius = min(frame.width, frame.height) / 2
        let distance = hypot(dx, dy)
        guard distance >= radius * 0.68, distance <= radius, total > 0 else { return }
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += .pi * 2 }
        let weight = angle / (.pi * 2) * total
        var cumulative = 0.0
        for segment in segments {
            cumulative += segment.weight
            if weight <= cumulative { apply(segment.id); return }
        }
    }

    private func apply(_ id: String) {
        guard inspectedID != id else { return }
        inspectedID = id
        onSelect?(id)
    }
}

// MARK: - 引导线标注层

/// 环形图引导线：扇区外缘 → 折点 → 水平段 → 末端「名称+占比」。
/// 布线策略沿用 10-17 之前自绘版：跨度足够的扇区名称画进环带（末端只标占比），
/// 小扇区名称并入末端文本；末端标签按左右分列，列内按锚点 Y 排序防碰撞。
private struct DonutLeaderLabelCanvas: View {
    let segments: [HoloDonutSegment]
    let focused: String?
    /// 绘图区（含扇形圆）在画布坐标系中的位置
    let plotFrame: CGRect
    let canvasSize: CGSize

    /// 环带内名称的最小角跨度（弧度，约 36°）：低于它环带里放不下名字，名字并入末端文本
    private static let inRingNameSpan: Double = 0.62
    /// 列内末端标签的目标行距（11pt 文本的可读下限）
    private static let rowSpacing: CGFloat = 14
    /// 引导线折点距绘图区边缘的水平距离（标签列位置）
    private static let columnInset: CGFloat = 10
    /// 水平段长度
    private static let tailLength: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            let total = segments.reduce(0) { $0 + $1.weight }
            guard total > 0, plotFrame.width > 10, plotFrame.height > 10 else { return }
            let center = CGPoint(x: plotFrame.midX, y: plotFrame.midY)
            let radius = min(plotFrame.width, plotFrame.height) / 2
            let ringMid = radius * 0.84

            struct Item {
                let segment: HoloDonutSegment
                let mid: Double          // 中角，0=正上，顺时针
                let span: Double
                let anchor: CGPoint      // 扇区外缘锚点
                let side: Int            // +1 右列 / -1 左列
                let fraction: Double
                var nameInRing: Bool { span >= DonutLeaderLabelCanvas.inRingNameSpan && !segment.name.isEmpty }
            }

            var items: [Item] = []
            var cumulative = 0.0
            for segment in segments where segment.weight > 0 {
                let span = segment.weight / total * .pi * 2
                let mid = cumulative + span / 2
                items.append(Item(
                    segment: segment,
                    mid: mid,
                    span: span,
                    anchor: CGPoint(x: center.x + sin(mid) * radius, y: center.y - cos(mid) * radius),
                    side: sin(mid) >= 0 ? 1 : -1,
                    fraction: segment.weight / total
                ))
                cumulative += span
            }
            guard !items.isEmpty else { return }

            let colorScheme = context.environment.colorScheme

            // 1) 环带内名称（大扇区）
            for item in items where item.nameInRing {
                let point = CGPoint(x: center.x + sin(item.mid) * ringMid, y: center.y - cos(item.mid) * ringMid)
                let textColor: Color = Self.readableNameColor(on: item.segment.color, colorScheme: colorScheme)
                    .opacity(focused == item.segment.id ? 1 : 0.92)
                context.draw(
                    Text(item.segment.name)
                        .font(.system(size: 11, weight: focused == item.segment.id ? .semibold : .regular))
                        .foregroundColor(textColor),
                    at: point
                )
            }

            // 2) 引导线 + 末端标签，左右分列
            for side in [1, -1] {
                let column = items.filter { $0.side == side }.sorted { $0.anchor.y < $1.anchor.y }
                guard !column.isEmpty else { continue }
                let ys = Self.resolvedLabelYs(anchors: column.map { $0.anchor.y },
                                              spacing: Self.rowSpacing,
                                              top: 6, bottom: size.height - 6)
                // 标签列挂「圆的边缘」而非 plot 矩形边缘：圆径由高度限制、居中于 plot，
                // 矩形与圆之间的空白是标签区的一部分，按矩形算会把可用宽度低估 ~26pt
                let columnX = side == 1 ? center.x + radius + Self.columnInset : center.x - radius - Self.columnInset
                let tailX = columnX + CGFloat(side) * Self.tailLength
                let textPointX = columnX + CGFloat(side) * (Self.tailLength + 3)

                for (index, item) in column.enumerated() {
                    let y = ys[index]
                    let isFocused = focused == item.segment.id
                    let lineColor = Color.holoToolTextSecondary.opacity(isFocused ? 0.9 : 0.45)

                    var path = Path()
                    path.move(to: item.anchor)
                    path.addLine(to: CGPoint(x: columnX, y: y))
                    path.addLine(to: CGPoint(x: tailX, y: y))
                    context.stroke(path, with: .color(lineColor), lineWidth: 1)

                    let percent = String(format: "%.1f%%", item.fraction * 100)
                    let weight: Font.Weight = isFocused ? .semibold : .regular
                    let textColor = isFocused ? Color.holoToolText : Color.holoToolTextSecondary
                    // 小扇区末端「名字(11pt) + 占比(小一号)」；大扇区名字在环内，末端只标占比
                    var text: Text
                    if item.nameInRing {
                        text = Text(percent).font(.system(size: 11, weight: weight)).monospacedDigit()
                    } else {
                        text = Text(item.segment.name).font(.system(size: 11, weight: weight))
                            + Text(" \(percent)").font(.system(size: 9.5, weight: weight)).monospacedDigit()
                    }
                    let styled = text.foregroundColor(textColor)
                    // 侧栏宽度兜底：标签放不下时保名字（颜色对应关系的刚需）、弃占比。
                    // measure 须传有限宽度（无限宽下返回值异常，会让兜底被全部误触发）
                    let measured = context.resolve(styled)
                        .measure(in: CGSize(width: 400, height: 20)).width
                    let available = side == 1 ? size.width - textPointX - 2 : textPointX - 2
                    if measured > available && !item.nameInRing && !item.segment.name.isEmpty {
                        context.draw(
                            Text(item.segment.name).font(.system(size: 11, weight: weight)).foregroundColor(textColor),
                            at: CGPoint(x: textPointX, y: y),
                            anchor: side == 1 ? .leading : .trailing
                        )
                    } else {
                        context.draw(styled, at: CGPoint(x: textPointX, y: y),
                                     anchor: side == 1 ? .leading : .trailing)
                    }
                }
            }
        }
    }

    /// 列内防碰撞：先按锚点自然 Y 正向压行距，若溢出画布则按可用高度均布重排
    private static func resolvedLabelYs(anchors: [CGFloat], spacing: CGFloat, top: CGFloat, bottom: CGFloat) -> [CGFloat] {
        guard !anchors.isEmpty else { return [] }
        var ys: [CGFloat] = []
        for anchorY in anchors {
            let natural = min(max(anchorY, top), bottom)
            ys.append(ys.last.map { max(natural, $0 + spacing) } ?? natural)
        }
        if let last = ys.last, last > bottom, ys.count > 1 {
            // 行距下限 12pt：低于它 11pt 文本会互相压字，宁可首行让位整体上提
            let compressed = max(12, (bottom - top) / CGFloat(ys.count - 1))
            ys = ys.enumerated().map { index, _ in top + CGFloat(index) * compressed }
        }
        return ys
    }

    /// 扇区名称在彩色底上的可读色：按底色亮度取深/浅
    private static func readableNameColor(on background: Color, colorScheme: ColorScheme) -> Color {
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        let uiColor = UIColor(background).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return luminance > 0.62 ? .black.opacity(0.78) : .white.opacity(0.95)
    }
}
