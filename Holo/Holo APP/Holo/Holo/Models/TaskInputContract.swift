//
//  TaskInputContract.swift
//  Holo
//
//  任务输入统一验证契约（R05/R06，2026-10-04 体检）
//
//  AI 提案、导入、手动编辑等所有入口在任何对象写入之前共用同一套合法性判定；
//  非法输入抛可捕获错误（TaskInputError），禁止 precondition 断言（进程终止）
//  与截断钳制（悄悄改变计划）。
//

import Foundation

/// 任务输入非法（R05/R06）。调用方捕获后向用户说明原因；抛出点保证没有任何写入副作用。
enum TaskInputError: Error, Equatable {
    /// 计划时间段必须成对、同一天且开始早于结束
    case invalidPlannedRange
    case invalidRepeatInterval(Int)
    case invalidRepeatMonthDay(Int)
    case invalidRepeatWeekdays
    case invalidRepeatMonthOrdinal(Int)
    case invalidRepeatUntilCount(Int)
    /// 目标任务不存在或已删除（按 UUID 重新获取失败，方案 §8.2）
    case taskNotFound

    /// 用户可读原因（AI 回复与 UI 提示共用）
    var userMessage: String {
        switch self {
        case .invalidPlannedRange:
            return "计划时间段必须成对、在同一天内且开始早于结束"
        case .invalidRepeatInterval(let raw):
            return "重复间隔需要在 1…365 天内，收到的是 \(raw)"
        case .invalidRepeatMonthDay(let raw):
            return "每月的日期需要在 1…31 内，收到的是 \(raw)"
        case .invalidRepeatWeekdays:
            return "自定义每周重复至少要选一个星期几"
        case .invalidRepeatMonthOrdinal(let raw):
            return "「第几个星期几」需要在 1…5 内，收到的是 \(raw)"
        case .invalidRepeatUntilCount(let raw):
            return "重复次数需要在 1…999 内，收到的是 \(raw)"
        case .taskNotFound:
            return "任务不存在或已删除"
        }
    }
}

/// 重复规则参数契约（R05）。AI 输出不是可信常量：40000 级别的间隔曾在 Int16
/// 窄化时直接终止进程，且旧顺序先建任务后建规则会留下半成品。
enum RepeatRuleContract {
    /// 产品上限：单次间隔最长一年（1…365 天），2026-10-04 与东林定案
    static let intervalRange = 1...365
    static let monthDayRange = 1...31
    /// 「第几个星期几」：每月最多出现第 5 次
    static let monthWeekOrdinalRange = 1...5
    static let untilCountRange = 1...999

    static func validatedInterval(_ raw: Int) throws {
        guard intervalRange.contains(raw) else { throw TaskInputError.invalidRepeatInterval(raw) }
    }

    static func validatedMonthDay(_ raw: Int) throws {
        guard monthDayRange.contains(raw) else { throw TaskInputError.invalidRepeatMonthDay(raw) }
    }

    static func validatedMonthWeekOrdinal(_ raw: Int) throws {
        guard monthWeekOrdinalRange.contains(raw) else { throw TaskInputError.invalidRepeatMonthOrdinal(raw) }
    }

    static func validatedUntilCount(_ raw: Int) throws {
        guard untilCountRange.contains(raw) else { throw TaskInputError.invalidRepeatUntilCount(raw) }
    }

    static func validatedWeekdays(_ raw: [Weekday]) throws {
        guard !raw.isEmpty else { throw TaskInputError.invalidRepeatWeekdays }
    }
}

/// 计划时间段日界契约（R06）。日界由日历推进——夏令时切换日一天可能是 23 或 25
/// 小时，固定 24 小时会算到次日（洛杉矶 2026-03-08 实测：旧算法得到次日 00:59）。
enum PlannedRangeContract {
    /// 当天最后一分钟（23:59；夏令时日仍为当天 23:59）
    static func dayEnd(from day: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        return calendar.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-60)
    }

    /// 开始时刻上界：当天 23:45（与旧版固定 24h-15min 语义一致，日界按日历算）
    static func startUpperBound(from day: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        return calendar.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-15 * 60)
    }
}
