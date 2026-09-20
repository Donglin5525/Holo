//
//  TimelineAxisLayout.swift
//  Holo
//
//  「轴」档的分钟 ↔ 像素双向映射（独立于 View 的纯逻辑，供单测锁定）：
//  展开态全天行序列；折叠态凌晨 0–7 压成一条摘要带（带内不渲染块）。
//  行高度按内容自适应：有条目覆盖的小时行保高，空档行压缩——条目稀疏的一天
//  也能一屏看全（2026-09-20「单任务日整页空旷」）。空白时段整段仍是可排区，
//  拖拽/吸附换算按锚点所在行的压缩比折算，块「高度 = 时长 × 所在行比例」恒成立。
//

import CoreGraphics

struct TimelineAxisLayout {

    let collapseMorning: Bool
    /// 有条目覆盖的小时行集合：行保高；集合外的行压缩为空档行
    let busyHours: Set<Int>

    /// 忙碌小时行像素高度
    static let hourHeight: CGFloat = 56
    /// 空档小时行像素高度（约为忙碌行的 1/3，把条目稀疏的一天收进一屏）
    static let idleHourHeight: CGFloat = 20
    /// 刻度列宽
    static let gutterWidth: CGFloat = 46
    /// 凌晨折叠段终点（分钟）
    static let morningEndMinute: CGFloat = 7 * 60
    /// 凌晨折叠带高度
    static let morningBandHeight: CGFloat = 38

    init(collapseMorning: Bool, busyHours: Set<Int> = []) {
        self.collapseMorning = collapseMorning
        self.busyHours = busyHours
    }

    /// 可滚动的小时行范围（折叠态凌晨收进摘要带，不参与行序列）
    private var hourRange: Range<Int> { collapseMorning ? 7..<24 : 0..<24 }

    /// 全天行保高（空态画布口径：轴上没有任何条目时不压缩，保留整屏拖拽建任务的区域）
    static func fullBusyHours(collapseMorning: Bool) -> Set<Int> {
        collapseMorning ? Set(7..<24) : Set(0..<24)
    }

    // MARK: - 行与映射

    /// 小时行高度：有条目保高，空档压缩
    func rowHeight(hour: Int) -> CGFloat {
        busyHours.contains(hour) ? Self.hourHeight : Self.idleHourHeight
    }

    /// 轴内容总高度
    var contentHeight: CGFloat {
        let rows = hourRange.reduce(0) { $0 + rowHeight(hour: $1) }
        return collapseMorning ? Self.morningBandHeight + rows : rows
    }

    /// 分钟 → y 坐标（行序列上前缀高度 + 行内线性）
    func y(minute: CGFloat) -> CGFloat {
        if collapseMorning, minute <= Self.morningEndMinute {
            return minute / Self.morningEndMinute * Self.morningBandHeight
        }
        let clamped = min(max(minute, 0), 24 * 60)
        let hour = min(Int(clamped) / 60, 23)
        var top: CGFloat = collapseMorning ? Self.morningBandHeight : 0
        for row in hourRange where row < hour { top += rowHeight(hour: row) }
        let inRow = (clamped - CGFloat(hour * 60)) / 60 * rowHeight(hour: hour)
        return top + inRow
    }

    /// y 坐标 → 分钟（拖拽换算逆映射；行序列反向扫，行内线性反解）
    func minute(y: CGFloat) -> CGFloat {
        if collapseMorning, y <= Self.morningBandHeight {
            return y / Self.morningBandHeight * Self.morningEndMinute
        }
        var remaining = y - (collapseMorning ? Self.morningBandHeight : 0)
        var hour = hourRange.lowerBound
        while hour < 23 {
            let height = rowHeight(hour: hour)
            if remaining <= height { break }
            remaining -= height
            hour += 1
        }
        let height = rowHeight(hour: hour)
        return CGFloat(hour * 60) + min(max(remaining / height, 0), 1) * 60
    }

    // MARK: - 交互换算

    /// 1 像素折合多少分钟（按锚点所在行：忙碌行、空档行、折叠带各按自身比例）
    func minutesPerPoint(aroundMinute anchor: CGFloat) -> CGFloat {
        if collapseMorning, anchor < Self.morningEndMinute {
            return Self.morningEndMinute / Self.morningBandHeight
        }
        let hour = min(Int(anchor) / 60, 23)
        return 60 / rowHeight(hour: hour)
    }

    /// 15 分钟吸附；折叠态凌晨不可排（与周档口径一致）：下限收到 7 点
    func snapMinute(_ raw: CGFloat, snap: CGFloat = 15) -> CGFloat {
        let snapped = (raw / snap).rounded() * snap
        let lowerBound: CGFloat = collapseMorning ? Self.morningEndMinute : 0
        return min(max(snapped, lowerBound), 24 * 60)
    }

    // MARK: - 块渲染口径

    /// 完全落在折叠段的块隐藏（计数进摘要带）
    func isMorningHidden(endMinute: CGFloat) -> Bool {
        Self.isMorningHidden(collapseMorning: collapseMorning, endMinute: endMinute)
    }

    /// 视图在「忙碌行判定」中过滤凌晨块必须走这个 static 版本：
    /// axisLayout 实例由忙碌行集合构造，而忙碌行集合又依赖可见块列表，
    /// 若过滤经由实例方法会形成 计算属性互相引用 的无限递归（栈溢出，2026-09-20 实锤）。
    static func isMorningHidden(collapseMorning: Bool, endMinute: CGFloat) -> Bool {
        collapseMorning && endMinute <= Self.morningEndMinute
    }

    /// 块顶落点：跨界块（如 6:30–8:30）折叠态从带底起画
    func laneYTop(startMinute: CGFloat) -> CGFloat {
        y(minute: max(startMinute, collapseMorning ? Self.morningEndMinute : 0))
    }

    // MARK: - 泳道分配（v2 宽屏多泳道展开）

    /// 贪心泳道分配：按开始时间排序，时间重叠的条目各占一条泳道；
    /// 泳道上一条结束时间 ≤ 当前开始即可复用。返回 id → 泳道序号 与 泳道数（空输入记 1，
    /// 让调用方的「按泳道数比例分配宽度」在无数据组上退化为对半，不除零）。
    static func assignLanes<ID: Hashable>(
        spans: [(id: ID, start: CGFloat, end: CGFloat)]
    ) -> (lanes: [ID: Int], laneCount: Int) {
        var lanes: [ID: Int] = [:]
        var laneEndMinutes: [CGFloat] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let reusableIndex = laneEndMinutes.firstIndex(where: { $0 <= span.start }) {
                laneEndMinutes[reusableIndex] = span.end
                lanes[span.id] = reusableIndex
            } else {
                laneEndMinutes.append(span.end)
                lanes[span.id] = laneEndMinutes.count - 1
            }
        }
        return (lanes, max(laneEndMinutes.count, 1))
    }

    /// 任务泳道区域的宽度分配：宽度跟着实际内容走——
    /// 一侧没有条目时不占位（另一侧独占全部可用宽），两侧都有才按泳道数比例分。
    /// 单任务独占时因此撑满全宽，而不是被空日程组按「对半兜底」砍掉一半。
    static func taskRegionWidth(
        available: CGFloat,
        taskItemCount: Int,
        scheduleItemCount: Int,
        taskLaneCount: Int,
        scheduleLaneCount: Int
    ) -> CGFloat {
        if taskItemCount == 0 { return 0 }
        if scheduleItemCount == 0 { return available }
        let total = CGFloat(taskLaneCount + scheduleLaneCount)
        guard total > 0 else { return available }
        return available * CGFloat(taskLaneCount) / total
    }
}
