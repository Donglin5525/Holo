//
//  TaskQuadrantResolver.swift
//  Holo
//
//  四象限纯规则解析器（方案 §3）：注入 now 与本地 Gregorian 日历，
//  重要性 × 紧急程度 → 象限。2026-10-07 P 档体系：紧急度按日期折算成
//  P1/P2/P3（手动锁定优先），并派生「紧急分」＝重要×2＋紧急（3–9 分）。
//

import Foundation

nonisolated enum TaskQuadrantResolver {

    /// 自动折算 P1 线：今天 00:00 起日历加三天 = 大后天 00:00。
    /// 有效截止早于该时刻（含逾期、今天、明天、后天到期）折算 P1（方案 §3.2/R13）。
    static func urgentBoundary(now: Date, calendar: Calendar) -> Date {
        let todayStart = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 3, to: todayStart) ?? todayStart
    }

    /// 自动折算 P2 线：今天 00:00 起日历加八天（第七天结束）。
    /// P1 线与 P2 线之间（三天后～七天内到期）折算 P2；更远或无截止折算 P3。
    static func moderateBoundary(now: Date, calendar: Calendar) -> Date {
        let todayStart = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 8, to: todayStart) ?? todayStart
    }

    /// auto 模式的日期折算档位（2026-10-07 三档）；手动模式直接返回锁定的档。
    static func urgencyLevel(
        mode: TaskUrgencyMode,
        effectiveDue: Date?,
        now: Date,
        calendar: Calendar
    ) -> TaskUrgencyMode {
        switch mode {
        case .p1, .p2, .p3:
            return mode
        case .auto:
            guard let effectiveDue else { return .p3 }
            if effectiveDue < urgentBoundary(now: now, calendar: calendar) { return .p1 }
            if effectiveDue < moderateBoundary(now: now, calendar: calendar) { return .p2 }
            return .p3
        }
    }

    /// 解析「当前是否紧急」＝折算档位为 P1（象限二分语义保持）。
    static func isUrgent(
        mode: TaskUrgencyMode,
        effectiveDue: Date?,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        urgencyLevel(mode: mode, effectiveDue: effectiveDue, now: now, calendar: calendar) == .p1
    }

    /// 象限解析（2026-10-07 拍板分组口径）：P1 归重要侧（优先处理/留出时间），
    /// P2/P3 归另一侧（集中处理/稍后再看）——「重要」保持稀缺，组内次序交给紧急分。
    /// 重要性未判断时恒为待整理（即使已逾期，方案 §3.2 末段）。
    static func quadrant(
        importance: TaskImportance,
        mode: TaskUrgencyMode,
        effectiveDue: Date?,
        now: Date,
        calendar: Calendar
    ) -> TaskQuadrant {
        switch importance {
        case .unknown:
            return .unclassified
        case .p1:
            return isUrgent(mode: mode, effectiveDue: effectiveDue, now: now, calendar: calendar)
                ? .doFirst
                : .scheduleTime
        case .p2, .p3:
            return isUrgent(mode: mode, effectiveDue: effectiveDue, now: now, calendar: calendar)
                ? .batchHandle
                : .reviewLater
        }
    }

    /// 紧急分（2026-10-07 东林拍板）：重要×2＋紧急，3–9 分；重要性未判断无分（待整理）。
    /// 分数不落库，排序/展示时实时算。
    static func urgencyScore(
        importance: TaskImportance,
        mode: TaskUrgencyMode,
        effectiveDue: Date?,
        now: Date,
        calendar: Calendar
    ) -> Int? {
        guard let impValue = importance.scoreValue else { return nil }
        let urgValue: Int
        switch urgencyLevel(mode: mode, effectiveDue: effectiveDue, now: now, calendar: calendar) {
        case .auto: urgValue = 1 // 不可达：urgencyLevel 不返回 auto；保守按最低档
        case .p3: urgValue = 1
        case .p2: urgValue = 2
        case .p1: urgValue = 3
        }
        return impValue * 2 + urgValue
    }

    /// 一行解释当前判断依据（新增页预览/详情/整理页共用，方案 §5.3）。
    static func urgencyExplanation(
        mode: TaskUrgencyMode,
        effectiveDue: Date?,
        now: Date,
        calendar: Calendar
    ) -> String {
        switch mode {
        case .p1:
            return String(localized: "紧急度已手动锁定为 P1")
        case .p2:
            return String(localized: "紧急度已手动锁定为 P2")
        case .p3:
            return String(localized: "紧急度已手动锁定为 P3")
        case .auto:
            guard let effectiveDue else {
                return String(localized: "未设截止日期，暂按 P3 判断")
            }
            if effectiveDue < now {
                return String(localized: "截止日期已经逾期，按 P1")
            }
            if effectiveDue < urgentBoundary(now: now, calendar: calendar) {
                return String(localized: "三天内到期，按日期折算 P1")
            }
            if effectiveDue < moderateBoundary(now: now, calendar: calendar) {
                return String(localized: "一周内到期，按日期折算 P2")
            }
            return String(localized: "截止日期还远，按日期折算 P3")
        }
    }
}
