import Foundation

/// 绘制、刻度与命中共同使用的几何规则；不依赖视图，便于覆盖边界回归。
enum HoloChartGeometry {
    static func bucketIndex(x: CGFloat, width: CGFloat, count: Int, clamped: Bool = false) -> Int? {
        guard width > 0, count > 0, x.isFinite else { return nil }
        guard clamped || (x >= 0 && x <= width) else { return nil }
        return min(max(Int(floor(min(max(x / width, 0), 1) * CGFloat(count))), 0), count - 1)
    }

    static func nearestIndex(x: CGFloat, positions: [CGFloat]) -> Int? {
        positions.indices.filter { positions[$0].isFinite }.min { abs(positions[$0] - x) < abs(positions[$1] - x) }
    }

    static func barWidth(plotWidth: CGFloat, count: Int, seriesCount: Int = 1) -> CGFloat {
        guard count > 0, seriesCount > 0 else { return 1 }
        let slot = max(plotWidth, 1) / CGFloat(count)
        let available = slot * 0.7 / CGFloat(seriesCount)
        return min(available, seriesCount == 1 ? 18 : 10)
    }

    /// 多系列柱并排时第 seriesIndex 根相对槽位中心的偏移（pt）。
    /// Swift Charts 的 position(by:) 只在分类轴上分组，本组件 x 是数值轴，多系列同 x 的柱
    /// 会被默认堆叠成一根（支出+收入叠加后冲出图顶压住读数，2026-10-29 财务总览实锤），
    /// 并排必须由绘制方按此偏移自行错开 x。组内间隙随柱宽收缩，整组恒在 barWidth 预算的槽内。
    static func seriesOffset(seriesIndex: Int, seriesCount: Int, barWidth: CGFloat) -> CGFloat {
        guard seriesCount > 1 else { return 0 }
        let gap = min(2, barWidth / 4)
        return (CGFloat(seriesIndex) - CGFloat(seriesCount - 1) / 2) * (barWidth + gap)
    }

    /// 刻度标签的单个框宽：与 HoloCartesianChart.tickLabels 实际框宽必须是同一个数。
    /// 容量预算曾按每标签 44pt 另算，框（width/5，上限 80pt）比预算宽时排出的刻度
    /// 相邻框互相侵入，两端标签再被钳进图内就与邻居贴死（2026-10-26 习惯回顾
    /// 「3/184/24」实锤，财务同病根）
    static func tickLabelWidth(plotWidth: CGFloat) -> CGFloat {
        min(max(plotWidth / 5, 32), 80)
    }

    static func tickIndices(count: Int, width: CGFloat) -> [Int] {
        guard count > 0 else { return [] }
        let labelWidth = tickLabelWidth(plotWidth: width)
        let capacity = max(2, Int(width / max(labelWidth, 1)))
        let ticks = min(count, capacity)
        guard ticks > 1 else { return [0] }
        return (0..<ticks).map { Int((Double($0) * Double(count - 1) / Double(ticks - 1)).rounded()) }
    }

    /// 连续坐标桶（position 域，如测量记录点）的刻度选取：像素位置贪心按最小
    /// 间距保留，末桶必留（顶替上一保留项，保证末日可见）
    static func tickIndicesForPositions(pixelPositions: [CGFloat], minSpacing: CGFloat) -> [Int] {
        guard !pixelPositions.isEmpty else { return [] }
        var kept: [Int] = []
        for (index, x) in pixelPositions.enumerated() where x.isFinite {
            if kept.isEmpty || x - pixelPositions[kept[kept.count - 1]] >= minSpacing {
                kept.append(index)
            } else if index == pixelPositions.count - 1 {
                kept[kept.count - 1] = index
            }
        }
        return kept
    }

    static func countLevel(_ count: Int) -> Int {
        switch count {
        case ...0: return 0
        case 1: return 1
        case 2...3: return 2
        case 4...5: return 3
        case 6...9: return 4
        default: return 5
        }
    }

    static func heatmapIndex(point: CGPoint, size: CGSize, weeks: Int) -> Int? {
        guard size.height > 0, point.y >= 0, point.y <= size.height,
              let week = bucketIndex(x: point.x, width: size.width, count: weeks),
              let weekday = bucketIndex(x: point.y, width: size.height, count: 7) else { return nil }
        return week * 7 + weekday
    }

    static func niceDomain(values: [Double], includesZero: Bool) -> ClosedRange<Double> {
        let finite = values.filter(\.isFinite)
        var low = finite.min() ?? 0
        var high = finite.max() ?? 1
        if includesZero { low = min(low, 0); high = max(high, 0) }
        let pad = max((high - low) * 0.15, high == low ? max(abs(high) * 0.1, 1) : 0.001)
        if !includesZero || low < 0 { low -= pad }
        high += pad
        return low...max(high, low + 0.001)
    }

    /// 双轴系列的独立坐标域：零基线 + 整齐上限（0、半值、顶值三点都可直接作刻度），
    /// 上限留少量头部余量让最高柱不贴顶。系列没有正数（全空或全 0）时返回 nil，不参与分轴。
    static func dualAxisDomain(values: [Double]) -> ClosedRange<Double>? {
        guard let peak = values.filter({ $0.isFinite && $0 > 0 }).max() else { return nil }
        return 0...roundAxisUpper(peak * 1.05)
    }

    /// 不小于 value 的最小整齐上限（1 / 1.5 / 2 / 3 / 4 / 5 / 6 / 8 / 9 / 10 × 10^k）。
    /// 步进取值保证半值刻度压缩成万/亿后不超过一位小数（2.5 一档会让半值
    /// 出现 1.25 万这类与顶值对不上账的读数）。
    static func roundAxisUpper(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        for step in [1.0, 1.5, 2, 3, 4, 5, 6, 8, 9, 10] where step * magnitude >= value * 0.999 {
            return step * magnitude
        }
        return 10 * magnitude
    }

    /// 两个系列是否值得各立数值轴：最大值悬殊（小者不足大者的三分之一）时，共轴会把
    /// 小者压成看不出趋势的矮柱；量级接近时共轴保持同高直接可比，不拆。
    static func shouldSplitDualAxes(primary: [Double], secondary: [Double]) -> Bool {
        guard let primaryUpper = dualAxisDomain(values: primary)?.upperBound,
              let secondaryUpper = dualAxisDomain(values: secondary)?.upperBound else { return false }
        return min(primaryUpper, secondaryUpper) * 3 < max(primaryUpper, secondaryUpper)
    }

    static func contiguousSegments(valid: [Bool]) -> [[Int]] {
        var segments: [[Int]] = []
        var current: [Int] = []
        for index in valid.indices {
            if valid[index] { current.append(index) }
            else if !current.isEmpty { segments.append(current); current = [] }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    static func dates(from start: Date, through end: Date, calendar: Calendar = .current,
                      step: Calendar.Component = .day) -> [Date] {
        var day = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        var dates: [Date] = []
        while day <= last {
            dates.append(day)
            guard let next = calendar.date(byAdding: step, value: 1, to: day), next > day else { break }
            day = next
        }
        return dates
    }
}
