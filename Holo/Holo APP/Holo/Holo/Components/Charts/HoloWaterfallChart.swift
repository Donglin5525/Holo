import SwiftUI

/// 瀑布图的一项：delta 是增减量（正=流入、负=流出），total 是锚点（期初/期末存量）。
struct HoloWaterfallItem: Identifiable {
    let id: String
    let label: String
    var delta: Double? = nil
    var total: Double? = nil
    var isAnchor: Bool { total != nil && delta == nil }
}

/// 现金流 · 横向瀑布（视觉 V4「纸本调性」，2026-11-15 东林拍板，原型
/// docs/design-prototypes/Holo图表视觉V4-纸本调性.html 第①节即契约）。
///
/// 旧版竖向瀑布的实锤病：期初/期末锚柱从 0 画到账户余额（7 万+），月度流水（千元级）只剩
/// 1–8% 柱高，柱端金额叠死、横轴中文名挤死。V4 规则：
/// - 存量与流量分开：期初水位当零线，柱子只画「钱的流动」；期初/期末存量写进顶部结论句；
/// - 标签永不相撞：分类名独占左列、金额独占右列，横向排布中文不旋转不截断；
/// - 先给结论再给图：顶部大数字 = 净流入/净流出，图下一句话点出最大去向。
struct HoloWaterfallChart: View {
    let items: [HoloWaterfallItem]
    var valueText: (Double) -> String = HoloChartFormat.number

    @State private var selectedID: String?
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 36
    @ScaledMetric(relativeTo: .subheadline) private var barHeight: CGFloat = 13
    @ScaledMetric(relativeTo: .subheadline) private var labelWidth: CGFloat = 72
    @ScaledMetric(relativeTo: .subheadline) private var amountWidth: CGFloat = 94

    /// 运行水位（纯函数，单测锁定）：每项 (from, to)；锚点项从 0 画到锚值
    static func levels(for items: [HoloWaterfallItem]) -> [(from: Double, to: Double)] {
        var run = 0.0
        return items.map { item in
            if let total = item.total {
                run = total
                return (0, total)
            }
            let from = run
            run += item.delta ?? 0
            return (from, run)
        }
    }

    /// 流量行（纯函数，单测锁定）：以期初水位为零线的相对水位；锚点不成行
    static func flowRows(for items: [HoloWaterfallItem]) -> [(item: HoloWaterfallItem, from: Double, to: Double)] {
        var run = 0.0
        return items.filter { !$0.isAnchor }.map { item in
            let from = run
            run += item.delta ?? 0
            return (item, from, run)
        }
    }

    private var rows: [(item: HoloWaterfallItem, from: Double, to: Double)] { Self.flowRows(for: items) }
    private var opening: Double? { items.first(where: \.isAnchor)?.total }
    private var closing: Double? { items.last(where: \.isAnchor)?.total }
    private var net: Double { rows.last?.to ?? 0 }
    private var inflow: Double { rows.compactMap(\.item.delta).filter { $0 > 0 }.reduce(0, +) }
    private var outflow: Double { -rows.compactMap(\.item.delta).filter { $0 < 0 }.reduce(0, +) }

    private var domain: (lo: Double, hi: Double) {
        let values: [Double] = rows.flatMap { [$0.from, $0.to] } + [0.0]
        let lo = values.min() ?? 0, hi = values.max() ?? 0
        let span = max(hi - lo, 1)
        return (lo - span * 0.04, hi + span * 0.04)
    }

    var body: some View {
        if rows.isEmpty {
            Text("这个期间还没有流水")
                .font(.caption).foregroundStyle(Color.holoToolTextSecondary)
                .frame(maxWidth: .infinity).frame(height: 120)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                hero
                waterline.padding(.top, 14)
                flowList
                Rectangle().fill(Color.holoToolBorder).frame(height: 0.5).padding(.vertical, 6)
                netRow
                footnote.padding(.top, 8)
            }
            .sensoryFeedback(.selection, trigger: selectedID)
        }
    }

    // MARK: 结论（2026-11-26 减法清爽版：2 行核心结论，不再重复复读流入/流出明细）

    private var hero: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(net >= 0 ? "+" : "−")\(valueText(abs(net)))")
                .font(.holoHeroNumber(size: 26)).monospacedDigit()
                .foregroundStyle(net >= 0 ? Color.holoChartInflow : Color.holoError)
                .lineLimit(1).minimumScaleFactor(0.75)
                .contentTransition(.numericText())
            if let opening, let closing {
                Text("\(net >= 0 ? "净流入" : "净流出") · 余额 \(NumberFormatter.compactCurrency(Decimal(opening))) → \(NumberFormatter.compactCurrency(Decimal(closing)))")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.holoToolTextSecondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            } else {
                Text(net >= 0 ? "净流入" : "净流出")
                    .font(.system(size: 12)).foregroundStyle(Color.holoToolTextSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 图

    /// 零线标题行：「期初水位」字样对准零线
    private var waterline: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelWidth)
            GeometryReader { geo in
                let x = xPosition(0, width: geo.size.width)
                Text("期初水位")
                    .font(.system(size: 10)).foregroundStyle(Color.holoToolTextSecondary.opacity(0.8))
                    .fixedSize()
                    .position(x: min(max(x, 24), geo.size.width - 24), y: 7)
            }
            .frame(height: 14)
            Color.clear.frame(width: amountWidth)
        }
        .accessibilityHidden(true)
    }

    private var flowList: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.item.id) { index, row in
                if index > 0, ((rows[index - 1].item.delta ?? 0) >= 0) != ((row.item.delta ?? 0) >= 0) {
                    groupGap(level: row.from)
                }
                flowRow(row, isFirst: index == 0, isLast: index == rows.count - 1)
            }
        }
    }

    private func flowRow(_ row: (item: HoloWaterfallItem, from: Double, to: Double), isFirst: Bool, isLast: Bool) -> some View {
        let delta = row.item.delta ?? 0
        let color: Color = delta >= 0 ? .holoChartInflow : .holoChartOutflow
        let dimmed = selectedID != nil && selectedID != row.item.id
        return HStack(spacing: 0) {
            Text(row.item.label)
                .font(.subheadline).foregroundStyle(Color.holoToolText)
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(width: labelWidth, alignment: .leading)
            track { width in
                let a = xPosition(min(row.from, row.to), width: width)
                let b = xPosition(max(row.from, row.to), width: width)
                let mid = rowHeight / 2
                // 水位连接：首行起点已在期初零线上、末行下方是结余分割线，不画悬空短线
                if !isFirst {
                    connector(x: xPosition(row.from, width: width), from: 0, to: mid - barHeight / 2)
                }
                if !isLast {
                    connector(x: xPosition(row.to, width: width), from: mid + barHeight / 2, to: rowHeight)
                }
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color)
                    .frame(width: max(2, b - a), height: barHeight)
                    .position(x: a + max(2, b - a) / 2, y: mid)
            }
            Text("\(delta >= 0 ? "+" : "−")\(valueText(abs(delta)))")
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Color.holoToolText)
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(width: amountWidth, alignment: .trailing)
        }
        .frame(height: rowHeight)
        .opacity(dimmed ? 0.32 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.18)) {
                selectedID = selectedID == row.item.id ? nil : row.item.id
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.item.label) \(delta >= 0 ? "流入" : "流出") \(valueText(abs(delta)))")
        .accessibilityAddTraits(selectedID == row.item.id ? [.isButton, .isSelected] : .isButton)
    }

    /// 流入 → 流出 分组间隙：零线与水位连接线贯穿
    private func groupGap(level: Double) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelWidth)
            track(height: 10) { width in
                connector(x: xPosition(level, width: width), from: 0, to: 10)
            }
            Color.clear.frame(width: amountWidth)
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    private var netRow: some View {
        let color: Color = net >= 0 ? .holoChartInflow : .holoChartOutflow
        return HStack(spacing: 0) {
            Text("结余变化")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Color.holoToolText)
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(width: labelWidth, alignment: .leading)
            track { width in
                let zero = xPosition(0, width: width)
                let end = xPosition(net, width: width)
                let a = min(zero, end), w = max(4, abs(end - zero))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color)
                    .frame(width: w, height: barHeight)
                    .position(x: a + w / 2, y: rowHeight / 2)
                // 「期末水位」仅在条右侧或左侧有充足空位（≥52pt）时绘制，避免压到实色条上
                let right = max(a + w, zero) + 6
                let left = min(a, zero) - 6
                if right + 52 <= width {
                    Text("期末水位")
                        .font(.system(size: 10.5)).foregroundStyle(Color.holoToolTextSecondary)
                        .fixedSize()
                        .position(x: right + 26, y: rowHeight / 2)
                } else if left >= 52 {
                    Text("期末水位")
                        .font(.system(size: 10.5)).foregroundStyle(Color.holoToolTextSecondary)
                        .fixedSize()
                        .position(x: left - 26, y: rowHeight / 2)
                }
            }
            Text("\(net >= 0 ? "+" : "−")\(valueText(abs(net)))")
                .font(.subheadline.weight(.bold)).monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: amountWidth, alignment: .trailing)
        }
        .frame(height: rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("结余变化 \(net >= 0 ? "增加" : "减少") \(valueText(abs(net)))")
    }

    /// 图下一句话：默认点出最大去向；点按某行后讲这一行的占比
    private var footnote: some View {
        Text(footnoteText)
            .font(.caption).foregroundStyle(Color.holoToolTextSecondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentTransition(.opacity)
    }

    private var footnoteText: String {
        func share(_ delta: Double) -> Int {
            let base = delta >= 0 ? inflow : outflow
            return base > 0 ? Int((abs(delta) / base * 100).rounded()) : 0
        }
        if let selectedID, let row = rows.first(where: { $0.item.id == selectedID }) {
            let delta = row.item.delta ?? 0
            return "\(row.item.label)占\(delta >= 0 ? "流入" : "流出") \(share(delta))%"
        }
        if let top = rows.filter({ ($0.item.delta ?? 0) < 0 }).max(by: { abs($0.item.delta ?? 0) < abs($1.item.delta ?? 0) }) {
            return "钱主要流向\(top.item.label)，占流出 \(share(top.item.delta ?? 0))%"
        }
        return ""
    }

    // MARK: 几何

    private func xPosition(_ value: Double, width: CGFloat) -> CGFloat {
        let (lo, hi) = domain
        return CGFloat((value - lo) / (hi - lo)) * width
    }

    /// 绘图轨道：零线虚线贯穿 + 业务内容；装饰不吃手势
    private func track<Content: View>(height: CGFloat? = nil,
                                      @ViewBuilder content: @escaping (CGFloat) -> Content) -> some View {
        GeometryReader { geo in
            let h = height ?? rowHeight
            ZStack(alignment: .topLeading) {
                Path { path in
                    let x = xPosition(0, width: geo.size.width)
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                }
                .stroke(Color.holoToolTextSecondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                content(geo.size.width)
            }
        }
        .frame(height: height ?? rowHeight)
        .padding(.horizontal, 6)
        .allowsHitTesting(false)
    }

    private func connector(x: CGFloat, from: CGFloat, to: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: x, y: from))
            path.addLine(to: CGPoint(x: x, y: to))
        }
        .stroke(Color.holoToolTextSecondary.opacity(0.5), lineWidth: 1)
    }
}
