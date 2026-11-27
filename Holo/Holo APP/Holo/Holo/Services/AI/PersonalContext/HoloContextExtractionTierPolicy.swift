//
//  HoloContextExtractionTierPolicy.swift
//  Holo
//
//  记忆萃取的会员分档（2026-11-27 东林拍板）：
//  - 免费：每个本地日最多一轮、每轮 1 页，只读最近 30 天的记录；
//  - Plus：现行节奏（30 分钟防抖、每轮 2 页），读全部历史。
//  免费升 Plus 时萃取游标需重置，否则游标已越过 30 天前的位置，更早的历史永远补不上。
//  方案：docs/_common/plans/2026-11-27-记忆萃取降本与免费开放方案.md §3
//

import Foundation

nonisolated enum HoloContextExtractionTierPolicy {
    /// 免费版可读的历史天数（含今天往前推）。
    static let freeHistoryDays = 30
    /// Plus 两轮之间的最小间隔。
    static let plusMinimumInterval: TimeInterval = 30 * 60
    /// 免费版每轮页数。
    static let freePackageLimit = 1
    /// 上次跑萃取时的档位（"free" / "plus"），用于识别升级并触发历史补萃。
    static let lastTierKey = "holo_personal_context_extraction_last_tier_v1"

    /// 历史下界：免费 = 今天零点往前 30 天；Plus = 无下界。
    static func historyFloor(isPlus: Bool, now: Date, calendar: Calendar = .current) -> Date? {
        guard !isPlus else { return nil }
        return calendar.date(byAdding: .day, value: -freeHistoryDays, to: calendar.startOfDay(for: now))
    }

    /// 本轮是否该跑。免费版的「每天一轮」不受冷启动跳防抖影响。
    static func isPassDue(
        isPlus: Bool,
        lastPassAt: Date?,
        now: Date,
        bypassDebounce: Bool,
        calendar: Calendar = .current
    ) -> Bool {
        guard let lastPassAt else { return true }
        if isPlus {
            return bypassDebounce || now.timeIntervalSince(lastPassAt) >= plusMinimumInterval
        }
        return !calendar.isDate(lastPassAt, inSameDayAs: now)
    }

    static func packageLimit(isPlus: Bool, requested: Int) -> Int {
        isPlus ? requested : min(requested, freePackageLimit)
    }

    /// 档位记录值。
    static func tierValue(isPlus: Bool) -> String { isPlus ? "plus" : "free" }

    /// 免费 → Plus：需要清空游标从头补萃全部历史。首次记录（无历史档位）不触发。
    static func needsHistoryBackfill(previousTier: String?, isPlus: Bool) -> Bool {
        previousTier == tierValue(isPlus: false) && isPlus
    }

    /// 学习基线与历史下界取较晚者（两者都是「不得早于」的下界）。
    static func effectiveBaseline(learningBaseline: Date?, historyFloor: Date?) -> Date? {
        switch (learningBaseline, historyFloor) {
        case let (lhs?, rhs?): return max(lhs, rhs)
        case let (lhs?, nil): return lhs
        case let (nil, rhs?): return rhs
        case (nil, nil): return nil
        }
    }
}
