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

    static func tickIndices(count: Int, width: CGFloat, fontSize: CGFloat = 11) -> [Int] {
        guard count > 0 else { return [] }
        let capacity = max(2, Int(width / max(fontSize * 4, 44)))
        let ticks = min(count, capacity)
        guard ticks > 1 else { return [0] }
        return (0..<ticks).map { Int((Double($0) * Double(count - 1) / Double(ticks - 1)).rounded()) }
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
