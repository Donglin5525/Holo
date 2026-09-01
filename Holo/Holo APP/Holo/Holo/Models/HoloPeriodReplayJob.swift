//
//  HoloPeriodReplayJob.swift
//  Holo
//
//  周期回放在聊天消息上的持久化任务状态。
//  直接复用 ChatMessage.extractedDataJSON，避免另建一份任务真相源。
//

import Foundation

nonisolated enum HoloPeriodReplayJobState: String, Sendable {
    case generating
    case waitingForNetwork
    case waitingForForeground
    case failed
    case completed

    var isRecoverable: Bool {
        switch self {
        case .generating, .waitingForNetwork, .waitingForForeground:
            return true
        case .failed, .completed:
            return false
        }
    }
}

nonisolated struct HoloPeriodReplayJob: Equatable, Sendable {
    static let payloadKind = "period_replay_job_v1"

    var periodType: MemoryInsightPeriodType
    var periodStart: Date
    var periodEnd: Date
    var state: HoloPeriodReplayJobState
    var attemptCount: Int
    var networkInterruptionCount: Int
    var backgroundExpirationCount: Int
    var resumeCount: Int
    var lastErrorCategory: String?
    var updatedAt: Date

    init(
        periodType: MemoryInsightPeriodType,
        periodStart: Date,
        periodEnd: Date,
        state: HoloPeriodReplayJobState = .generating,
        attemptCount: Int = 0,
        networkInterruptionCount: Int = 0,
        backgroundExpirationCount: Int = 0,
        resumeCount: Int = 0,
        lastErrorCategory: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.periodType = periodType
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.state = state
        self.attemptCount = attemptCount
        self.networkInterruptionCount = networkInterruptionCount
        self.backgroundExpirationCount = backgroundExpirationCount
        self.resumeCount = resumeCount
        self.lastErrorCategory = lastErrorCategory
        self.updatedAt = updatedAt
    }

    init?(json: String?) {
        guard let json,
              let data = json.data(using: .utf8),
              let dictionary = try? JSONDecoder().decode([String: String].self, from: data),
              dictionary["kind"] == Self.payloadKind,
              let periodTypeRaw = dictionary["periodType"],
              let periodType = MemoryInsightPeriodType(rawValue: periodTypeRaw),
              let periodStartRaw = dictionary["periodStart"],
              let periodStartTimestamp = TimeInterval(periodStartRaw),
              let periodEndRaw = dictionary["periodEnd"],
              let periodEndTimestamp = TimeInterval(periodEndRaw),
              let stateRaw = dictionary["state"],
              let state = HoloPeriodReplayJobState(rawValue: stateRaw) else {
            return nil
        }

        self.periodType = periodType
        self.periodStart = Date(timeIntervalSince1970: periodStartTimestamp)
        self.periodEnd = Date(timeIntervalSince1970: periodEndTimestamp)
        self.state = state
        self.attemptCount = Int(dictionary["attemptCount"] ?? "0") ?? 0
        self.networkInterruptionCount = Int(dictionary["networkInterruptionCount"] ?? "0") ?? 0
        self.backgroundExpirationCount = Int(dictionary["backgroundExpirationCount"] ?? "0") ?? 0
        self.resumeCount = Int(dictionary["resumeCount"] ?? "0") ?? 0
        self.lastErrorCategory = dictionary["lastErrorCategory"]
        self.updatedAt = Date(
            timeIntervalSince1970: TimeInterval(dictionary["updatedAt"] ?? "") ?? 0
        )
    }

    var json: String? {
        var dictionary: [String: String] = [
            "kind": Self.payloadKind,
            "periodType": periodType.rawValue,
            "periodStart": String(periodStart.timeIntervalSince1970),
            "periodEnd": String(periodEnd.timeIntervalSince1970),
            "state": state.rawValue,
            "attemptCount": String(attemptCount),
            "networkInterruptionCount": String(networkInterruptionCount),
            "backgroundExpirationCount": String(backgroundExpirationCount),
            "resumeCount": String(resumeCount),
            "updatedAt": String(updatedAt.timeIntervalSince1970)
        ]
        if let lastErrorCategory, !lastErrorCategory.isEmpty {
            dictionary["lastErrorCategory"] = lastErrorCategory
        }
        guard let data = try? JSONEncoder().encode(dictionary) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 聊天消息等处的周期称谓。按实际起止生成具体称谓（“8月”“8月24日-30日”“9月1日-2日”），
    /// 不用“本周/本月”：一是周期初智能回退后标签会与数据不符，二是消息持久化后相对词会过时。
    var periodLabel: String {
        Self.rangeLabel(start: periodStart, end: periodEnd, periodType: periodType)
    }

    /// 完整自然周期给整期称谓，其余（进行中/自定义）给日期区间。
    /// 跨年时末端补年份（只有自定义长周期才可能跨年）。
    static func rangeLabel(start: Date, end: Date, periodType: MemoryInsightPeriodType) -> String {
        if isFullNaturalPeriod(start: start, end: end, periodType: periodType) {
            let calendar = Calendar.current
            switch periodType {
            case .monthly:
                return "\(calendar.component(.month, from: start))月"
            case .quarterly:
                let fromMonth = calendar.component(.month, from: start)
                let toMonth = calendar.component(.month, from: end)
                return "\(fromMonth)月-\(toMonth)月"
            default:
                break
            }
        }
        return dateRangeLabel(start: start, end: end)
    }

    /// 日期区间称谓：同日“9月1日”；同月“9月1日-2日”；跨月“8月28日-9月1日”；跨年末端带年
    static func dateRangeLabel(start: Date, end: Date) -> String {
        let calendar = Calendar.current
        let sameDay = start.isSameDay(as: end)
        let sameMonth = start.isSameMonth(as: end)
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: end)
        if sameDay {
            return "\(calendar.component(.month, from: start))月\(calendar.component(.day, from: start))日"
        }
        let head = "\(calendar.component(.month, from: start))月\(calendar.component(.day, from: start))日"
        if sameMonth {
            return "\(head)-\(calendar.component(.day, from: end))日"
        }
        let tailMonth = "\(calendar.component(.month, from: end))月"
        let tail = sameYear
            ? "\(tailMonth)\(calendar.component(.day, from: end))日"
            : "\(calendar.component(.year, from: end))年\(tailMonth)\(calendar.component(.day, from: end))日"
        return "\(head)-\(tail)"
    }

    /// 是否恰好覆盖一个完整自然周期（周一到周日 / 月初到月末 / 季初到季末）
    static func isFullNaturalPeriod(start: Date, end: Date, periodType: MemoryInsightPeriodType) -> Bool {
        switch periodType {
        case .weekly:
            return start.startOfWeek == start.startOfDay
                && end.startOfDay == start.addingDays(6).startOfDay
        case .monthly:
            return start.startOfMonth == start.startOfDay
                && end.startOfDay == start.startOfMonth.addingDays(start.daysInMonth - 1).startOfDay
        case .quarterly:
            return start.startOfQuarter == start.startOfDay
                && end.startOfDay == start.startOfQuarter.addingMonths(3).addingDays(-1).startOfDay
        case .custom, .daily:
            return false
        }
    }

    var statusText: String {
        switch state {
        case .generating:
            return "正在回顾这段时间的记录…"
        case .waitingForNetwork:
            return "网络中断，已保留进度，将自动继续"
        case .waitingForForeground:
            return "系统暂停了后台生成，打开 Holo 后会继续"
        case .failed:
            return "这次生成没有完成，可以继续生成"
        case .completed:
            return ""
        }
    }
}

extension ChatMessageViewData {
    nonisolated var periodReplayJob: HoloPeriodReplayJob? {
        guard messageType == .periodReplay else { return nil }
        return HoloPeriodReplayJob(json: extractedDataJSON)
    }
}
