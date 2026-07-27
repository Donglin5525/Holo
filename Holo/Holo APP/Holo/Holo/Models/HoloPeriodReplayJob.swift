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

    var periodLabel: String {
        switch periodType {
        case .daily: return "今日"
        case .weekly: return "本周"
        case .monthly: return "本月"
        case .quarterly: return "本季度"
        case .custom: return "自定义周期"
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
