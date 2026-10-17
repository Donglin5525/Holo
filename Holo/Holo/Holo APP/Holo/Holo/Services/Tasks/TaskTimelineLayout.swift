//
//  TaskTimelineLayout.swift
//  Holo
//
//  单日时间轴的重叠布局纯计算（多视图方案 §5.2-6/7/8）：
//  短块（真实时长不足最小可点高）按「视觉区间」参与冲突判断，触点不被遮住；
//  区间扫描分冲突组（结束等于下一开始不算冲突），组内最少列贪心分列等宽；
//  列数 ≥3 且块净宽 < 88pt 时整组聚合为「n项重叠」组块。不排序数据源、不落库。
//

import Foundation

nonisolated enum TaskTimelineLayout {

    /// 输入块（时间轴上的一个计划时段；id 为任务 UUID）
    struct Block: Equatable {
        let id: UUID
        let start: Date
        let end: Date
    }

    /// 单个块的落位
    struct Placement: Equatable {
        let block: Block
        /// 从 0 起的列号
        let lane: Int
        /// 冲突组总列数（等宽分列用）
        let laneCount: Int
        /// 真实区间与组内其他块相交（块内显示「时间重叠」）
        let overlapsAnother: Bool
    }

    /// 整组聚合（三列以上且过窄时替代逐块落位）
    struct MergedGroup: Equatable {
        let blocks: [Block]
        let start: Date
        /// 视觉区间结束（含短块最小高扩展）
        let visualEnd: Date
    }

    enum GroupLayout: Equatable {
        case placements([Placement])
        case merged(MergedGroup)
    }

    struct Output: Equatable {
        /// 冲突组序列（时间升序）
        let groups: [GroupLayout]
        var allPlacements: [Placement] {
            groups.flatMap { group -> [Placement] in
                if case .placements(let items) = group { return items }
                return []
            }
        }
    }

    // MARK: - 布局参数（§9.2 尺寸表；与视图共享同一来源）

    struct Metrics {
        /// 每小时高度（pt）
        var hourHeight: CGFloat = 64
        /// 块最小可点击高（pt）
        var minBlockHeight: CGFloat = 44
        /// 聚合线：块净宽低于该值不再逐块排（pt）
        var minUsableBlockWidth: CGFloat = 88
        /// 可用内容宽（时间列右侧，pt）
        var availableWidth: CGFloat

        /// 短块最小视觉持续时长（秒）
        var minVisualDuration: TimeInterval {
            minBlockHeight / hourHeight * 3600
        }
    }

    // MARK: - 计算

    static func layout(_ blocks: [Block], metrics: Metrics) -> Output {
        let sorted = blocks
            .filter { $0.end > $0.start }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                if lhs.end != rhs.end { return lhs.end < rhs.end }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        guard !sorted.isEmpty else { return Output(groups: []) }

        // 1. 视觉区间（短块撑到最小可点高的时长）
        func visualEnd(_ block: Block) -> Date {
            max(block.end, block.start.addingTimeInterval(metrics.minVisualDuration))
        }

        // 2. 区间扫描分冲突组：按开始排序，开始 ≥ 当前组最大视觉结束即断组
        //    （结束等于下一开始不算冲突，严格小于才同组）
        var conflictGroups: [[Block]] = []
        var current: [Block] = []
        var groupVisualEnd: Date? = nil
        for block in sorted {
            if let end = groupVisualEnd, block.start < end {
                current.append(block)
                groupVisualEnd = max(end, visualEnd(block))
            } else {
                if !current.isEmpty { conflictGroups.append(current) }
                current = [block]
                groupVisualEnd = visualEnd(block)
            }
        }
        if !current.isEmpty { conflictGroups.append(current) }

        // 3. 组内布局
        let groups: [GroupLayout] = conflictGroups.map { group in
            let lanesEnds = assignLanes(group, visualEnd: visualEnd)
            let laneCount = lanesEnds.count
            let perLaneWidth = metrics.availableWidth / CGFloat(max(laneCount, 1))
            if laneCount >= 3 && perLaneWidth < metrics.minUsableBlockWidth {
                return .merged(MergedGroup(
                    blocks: group,
                    start: group.map(\.start).min()!,
                    visualEnd: group.map(visualEnd).max()!
                ))
            }
            let placements = group.enumerated().map { index, block in
                Placement(
                    block: block,
                    lane: lanesEnds.laneByIndex[index] ?? 0,
                    laneCount: laneCount,
                    overlapsAnother: group.contains { other in
                        other.id != block.id
                            && other.start < block.end
                            && other.end > block.start
                    }
                )
            }
            return .placements(placements)
        }
        return Output(groups: groups)
    }

    /// 组内最少列贪心：找第一个已结束的列复用，否则开新列。
    /// 返回（各列当前结束时刻、块索引 → 列号）。
    private static func assignLanes(
        _ group: [Block],
        visualEnd: (Block) -> Date
    ) -> (laneEnds: [Date], laneByIndex: [Int: Int]) {
        var laneEnds: [Date] = []
        var laneByIndex: [Int: Int] = [:]
        for (index, block) in group.enumerated() {
            if let reusable = laneEnds.firstIndex(where: { $0 <= block.start }) {
                laneByIndex[index] = reusable
                laneEnds[reusable] = visualEnd(block)
            } else {
                laneByIndex[index] = laneEnds.count
                laneEnds.append(visualEnd(block))
            }
        }
        return (laneEnds, laneByIndex)
    }
}

// MARK: - 时间换算（时间轴绘制共用）

nonisolated enum TaskTimelineMath {

    /// 当天 0 点起过去的分钟数
    static func minutesSinceMidnight(_ date: Date, calendar: Calendar) -> CGFloat {
        let start = calendar.startOfDay(for: date)
        return CGFloat(calendar.dateComponents([.minute], from: start, to: date).minute ?? 0)
    }

    /// 分钟数 → 时间轴 y 偏移（pt）
    static func yOffset(minutes: CGFloat, hourHeight: CGFloat) -> CGFloat {
        minutes / 60 * hourHeight
    }

    /// 块渲染高度：真实时长换算，最小可点高兜底（§5.2-6）
    static func blockHeight(start: Date, end: Date, hourHeight: CGFloat, minBlockHeight: CGFloat, calendar: Calendar) -> CGFloat {
        let minutes = CGFloat(calendar.dateComponents([.minute], from: start, to: end).minute ?? 0)
        return max(minBlockHeight, yOffset(minutes: minutes, hourHeight: hourHeight))
    }
}
