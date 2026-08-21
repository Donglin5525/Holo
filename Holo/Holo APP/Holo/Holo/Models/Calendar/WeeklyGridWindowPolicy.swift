//
//  WeeklyGridWindowPolicy.swift
//  Holo
//
//  周网格三日窗口的纯状态规则：横向浏览只改变窗口，不把 ScrollView 物理位置
//  与未来日期限制写进同一个双向绑定，避免列错位和嵌套滚动手势互相锁死。
//

import Foundation

struct WeeklyGridWindowPolicy: Equatable {
    let totalDayCount: Int
    let visibleDayCount: Int
    /// 当前周传入今天的下标；历史周传 nil，允许浏览完整七天。
    let latestAllowedDayIndex: Int?

    init(totalDayCount: Int,
         visibleDayCount: Int = 3,
         latestAllowedDayIndex: Int? = nil) {
        self.totalDayCount = max(0, totalDayCount)
        self.visibleDayCount = max(1, visibleDayCount)
        self.latestAllowedDayIndex = latestAllowedDayIndex.map {
            min(max(0, $0), max(0, totalDayCount - 1))
        }
    }

    var maximumStartIndex: Int {
        let fullMaximum = max(0, totalDayCount - visibleDayCount)
        guard let latestAllowedDayIndex else { return fullMaximum }

        // 当前周最后一屏让今天尽量位于中列，并允许右侧自然露出未来日期；
        // 未来日期只负责说明时间还没发生，不成为可进入的新窗口。
        let centeredMaximum = max(0, latestAllowedDayIndex - visibleDayCount / 2)
        return min(fullMaximum, centeredMaximum)
    }

    func startIndex(focusedIndex: Int) -> Int {
        let centered = focusedIndex - visibleDayCount / 2
        return min(maximumStartIndex, max(0, centered))
    }

    func steppedStartIndex(from currentStart: Int, by delta: Int) -> Int {
        min(maximumStartIndex, max(0, currentStart + delta))
    }

    func focusIndex(forWindowStart start: Int) -> Int {
        guard totalDayCount > 0 else { return 0 }
        let boundedStart = min(maximumStartIndex, max(0, start))
        // 当前周已经来到最后一屏时，逻辑焦点必须落在今天。
        // 尤其周日没有更多右侧空间，今天会自然位于最右列，不能仍把周六当作聚焦日。
        if let latestAllowedDayIndex, boundedStart == maximumStartIndex {
            return latestAllowedDayIndex
        }

        let centered = boundedStart + visibleDayCount / 2
        let bounded = min(totalDayCount - 1, centered)
        guard let latestAllowedDayIndex else { return bounded }
        return min(latestAllowedDayIndex, bounded)
    }
}
