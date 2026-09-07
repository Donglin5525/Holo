//
//  TimelineAxisLayout.swift
//  Holo
//
//  「轴」档的分钟 ↔ 像素双向映射（独立于 View 的纯逻辑，供单测锁定）：
//  展开态全天线性；折叠态凌晨 0–7 压成一条摘要带（带内不渲染块），白天段正常比例。
//  所有块的落点/高度、拖拽换算、选区吸附共用这一套映射，保证「高度 = 时长」在白天段恒成立。
//

import CoreGraphics

struct TimelineAxisLayout {

    let collapseMorning: Bool

    /// 白天段每小时像素高度
    static let hourHeight: CGFloat = 56
    /// 刻度列宽
    static let gutterWidth: CGFloat = 46
    /// 凌晨折叠段终点（分钟）
    static let morningEndMinute: CGFloat = 7 * 60
    /// 凌晨折叠带高度
    static let morningBandHeight: CGFloat = 38

    // MARK: - 高度与映射

    /// 轴内容总高度
    var contentHeight: CGFloat {
        collapseMorning
            ? Self.morningBandHeight + (24 - 7) * Self.hourHeight
            : 24 * Self.hourHeight
    }

    /// 分钟 → y 坐标
    func y(minute: CGFloat) -> CGFloat {
        if !collapseMorning { return minute / 60 * Self.hourHeight }
        if minute <= Self.morningEndMinute {
            return minute / Self.morningEndMinute * Self.morningBandHeight
        }
        return Self.morningBandHeight + (minute - Self.morningEndMinute) / 60 * Self.hourHeight
    }

    /// y 坐标 → 分钟（拖拽换算逆映射）
    func minute(y: CGFloat) -> CGFloat {
        if !collapseMorning { return y / Self.hourHeight * 60 }
        if y <= Self.morningBandHeight {
            return y / Self.morningBandHeight * Self.morningEndMinute
        }
        return Self.morningEndMinute + (y - Self.morningBandHeight) / Self.hourHeight * 60
    }

    // MARK: - 交互换算

    /// 1 像素折合多少分钟（按锚点所在段：白天正常、折叠带内按压缩比）
    func minutesPerPoint(aroundMinute anchor: CGFloat) -> CGFloat {
        if !collapseMorning || anchor >= Self.morningEndMinute {
            return 60 / Self.hourHeight
        }
        return Self.morningEndMinute / Self.morningBandHeight
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
}
