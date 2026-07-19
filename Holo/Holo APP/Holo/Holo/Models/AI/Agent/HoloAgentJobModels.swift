//
//  HoloAgentJobModels.swift
//  Holo
//
//  HoloAI Agent V3.1 — Agent 任务与预算
//

import Foundation

nonisolated enum HoloAgentJobType: String, Codable, CaseIterable, Sendable {
    case deepAnalysis
    case memoryGallerySummary
    case observerInspection
    case memoryCuration
    case healthInsight
    case debugMock
}

nonisolated enum HoloAgentTrigger: String, Codable, CaseIterable, Sendable {
    case userQuestion
    case memoryGalleryRefresh
    case observerTier2
    case healthInsight
    case debug
}

nonisolated enum HoloAgentJobState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case waitingForLLM
    case retrying
    case waitingForForeground
    /// App 可以运行，但外部条件不满足（设备锁定/网络中断等，waitReason 区分）
    case waitingForCondition
    case paused
    case completed
    case failed
    case cancelled
    /// 输入已变化，被新任务取代；终态（§5.2）
    case superseded
}

nonisolated enum HoloAgentStep: String, Codable, CaseIterable, Sendable {
    case plan
    case executeTools
    case minePatterns
    case integrateResults
    case continueOrConclude
    case verifyClaims
    case critique
    case curateMemory
    case render
    case persistResult
}

// MARK: - 任务

nonisolated struct HoloAgentJob: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var type: HoloAgentJobType
    var userQuestion: String?
    var trigger: HoloAgentTrigger
    var state: HoloAgentJobState
    var currentStep: HoloAgentStep
    var createdAt: Date
    var updatedAt: Date
    var lastForegroundRunAt: Date?
    var timeRange: HoloAgentTimeRange?
    var budget: HoloAgentBudget
    var checkpointID: String?
    var resultID: String?
    var errorSummary: String?
    var deviceID: String?
    var sourceMessageID: UUID? = nil
    /// 证据参照时间（创建 job 时冻结 = createdAt；旧数据 nil，读取方回落 createdAt）。§5.1/§7.3
    var referenceDate: Date? = nil
    /// 数据快照截止（创建 job 时冻结 = createdAt；旧数据 nil，读取方回落 createdAt）。
    var snapshotCutoffAt: Date? = nil
    /// 执行代次（§6.1）：每次新执行前由 JobStore 原子递增；nil 视为 0（旧数据）。
    /// runLoop 写 checkpoint/evidence/result 前校验，过期抛 staleExecution 不得写回。
    var executionGeneration: Int? = nil
    /// 累计实际执行时长（active runtime，§5.2 P0-3）：锁屏/等待/暂停不计入；nil 视为 0。
    var consumedActiveRuntime: TimeInterval? = nil
    /// 当前执行段起点（runLoop 入口设置；暂停/等待/终态时结算进 consumedActiveRuntime 并清空）。
    var activeSegmentStartedAt: Date? = nil
    /// 绝对截止：防止无限等待的兜底（创建时 = createdAt + 上限）；超过后等待转 failed。
    var absoluteDeadline: Date? = nil
    /// 当前等待原因（waitingForForeground/waitingForCondition/paused 时非空，恢复执行时清空）。
    var waitReason: HoloAgentWaitReason? = nil
    /// 最近一次恢复/启动原因（诊断用）。
    var lastResumeReason: HoloAgentResumeReason? = nil
}

extension HoloAgentJob {
    /// 绝对截止上限（§5.2）：创建 job 时设 absoluteDeadline = createdAt + 该值。
    /// 取 30 分钟：远大于 active runtime 预算（normalDeep 120s），覆盖合理的锁屏/网络等待窗口。
    static let absoluteDeadlineInterval: TimeInterval = 1_800

    /// 截至 now 的累计实际执行时长：已结算段 + 当前开放段。
    func activeRuntimeSeconds(at now: Date = Date()) -> TimeInterval {
        var total = consumedActiveRuntime ?? 0
        if let segmentStart = activeSegmentStartedAt {
            total += now.timeIntervalSince(segmentStart)
        }
        return max(0, total)
    }

    /// 运行预算是否耗尽：maxWallTimeSeconds 语义为 maxActiveRuntimeSeconds（§5.2，保留属性名避免大面积改名）。
    func isActiveRuntimeExhausted(at now: Date = Date()) -> Bool {
        activeRuntimeSeconds(at: now) >= TimeInterval(budget.maxWallTimeSeconds)
    }

    /// 是否已超过绝对截止（无限等待兜底）。
    func isPastAbsoluteDeadline(at now: Date = Date()) -> Bool {
        guard let absoluteDeadline else { return false }
        return now >= absoluteDeadline
    }

    /// 开始一个执行段（runLoop 入口/恢复时调用；已有开放段时保留原起点——
    /// 崩溃残留的开放段按保守语义继续累计，防止超时任务无限续跑）。
    mutating func beginActiveSegment(at now: Date) {
        if activeSegmentStartedAt == nil {
            activeSegmentStartedAt = now
        }
    }

    /// 关闭当前执行段并把时长累计进 consumedActiveRuntime（暂停/等待/终态时调用）。
    mutating func endActiveSegment(at now: Date) {
        if let segmentStart = activeSegmentStartedAt {
            consumedActiveRuntime = (consumedActiveRuntime ?? 0) + max(0, now.timeIntervalSince(segmentStart))
            activeSegmentStartedAt = nil
        }
    }
}

// MARK: - 预算

nonisolated struct HoloAgentBudget: Codable, Equatable, Sendable {
    var maxLLMRounds: Int
    var maxToolBatches: Int
    var maxInputTokens: Int
    var maxOutputTokens: Int
    /// 语义为 maxActiveRuntimeSeconds（§5.2 P0-3）：只累计实际执行时长，
    /// 锁屏/等待/暂停不计入；保留属性名避免大面积改名。
    var maxWallTimeSeconds: Int
    var consumedLLMRounds: Int
    var consumedToolBatches: Int
    var consumedInputTokens: Int
    var consumedOutputTokens: Int
    var startedAt: Date
    var updatedAt: Date

    /// 资源维度耗尽判断（轮数/token）；时间维度请用 `HoloAgentJob.isActiveRuntimeExhausted`。
    var isResourceExhausted: Bool {
        consumedLLMRounds >= maxLLMRounds ||
            consumedToolBatches >= maxToolBatches ||
            consumedInputTokens >= maxInputTokens ||
            consumedOutputTokens >= maxOutputTokens
    }

    var isExhausted: Bool {
        isResourceExhausted ||
            Date().timeIntervalSince(startedAt) >= TimeInterval(maxWallTimeSeconds)
    }
}

extension HoloAgentBudget {
    /// 标准深度分析预算
    static func normalDeep(now: Date = Date()) -> HoloAgentBudget {
        HoloAgentBudget(
            maxLLMRounds: 5, maxToolBatches: 5,
            maxInputTokens: 10_000, maxOutputTokens: 4_000,
            maxWallTimeSeconds: 120,
            consumedLLMRounds: 0, consumedToolBatches: 0,
            consumedInputTokens: 0, consumedOutputTokens: 0,
            startedAt: now, updatedAt: now
        )
    }

    /// 扩展深度分析预算（用户主动继续时）
    static func extendedDeep(now: Date = Date()) -> HoloAgentBudget {
        HoloAgentBudget(
            maxLLMRounds: 5, maxToolBatches: 5,
            maxInputTokens: 20_000, maxOutputTokens: 8_000,
            maxWallTimeSeconds: 300,
            consumedLLMRounds: 0, consumedToolBatches: 0,
            consumedInputTokens: 0, consumedOutputTokens: 0,
            startedAt: now, updatedAt: now
        )
    }

    /// Observer Tier2 跟进预算（更克制）
    static func observerFollowUp(now: Date = Date()) -> HoloAgentBudget {
        HoloAgentBudget(
            maxLLMRounds: 2, maxToolBatches: 2,
            maxInputTokens: 6_000, maxOutputTokens: 2_000,
            maxWallTimeSeconds: 60,
            consumedLLMRounds: 0, consumedToolBatches: 0,
            consumedInputTokens: 0, consumedOutputTokens: 0,
            startedAt: now, updatedAt: now
        )
    }
}
