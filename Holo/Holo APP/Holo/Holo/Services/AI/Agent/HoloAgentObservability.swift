//
//  HoloAgentObservability.swift
//  Holo
//
//  Holo Agent 稳定执行 — Phase 7：无敏感内容的结构化事件与本地可靠性指标。
//  事件只允许写入技术状态，不得携带用户问题、消息正文、工具结果或证据摘要。
//

import Foundation
import os.log

nonisolated enum HoloAgentEventName: String, Codable, CaseIterable, Sendable {
    case jobCreated = "agent_job_created"
    case executionAcquired = "agent_execution_acquired"
    case executionAttached = "agent_execution_attached"
    case executionStaleRejected = "agent_execution_stale_rejected"
    case checkpointCommitted = "agent_checkpoint_committed"
    case waitingForCondition = "agent_waiting_for_condition"
    case executionExpired = "agent_execution_expired"
    case resumeStarted = "agent_resume_started"
    case stepIdempotencyHit = "agent_step_idempotency_hit"
    case resultReconciled = "agent_result_reconciled"
    case jobCompleted = "agent_job_completed"
    case jobFailed = "agent_job_failed"
    case jobCancelled = "agent_job_cancelled"
    case leaseChanged = "agent_lease_changed"
}

/// 单条结构化事件。字段保持封闭，避免调用方把任意业务文本塞进诊断日志。
nonisolated struct HoloAgentTelemetryEvent: Codable, Equatable, Sendable {
    var id: String
    var name: HoloAgentEventName
    var timestamp: Date
    var jobID: String?
    var jobType: HoloAgentJobType?
    var trigger: HoloAgentTrigger?
    var state: HoloAgentJobState?
    var waitReason: HoloAgentWaitReason?
    var generation: Int?
    var checkpointRevision: Int?
    var leaseKind: HoloAgentExecutionLeaseKind?
    var round: Int?
    var durationMilliseconds: Int?
    /// 只允许稳定错误代码，不得放 localizedDescription/errorSummary。
    var errorCode: String?
    /// 仅 stepID / 网关 request id 等技术标识，不得放 requestHash 或请求正文。
    var requestID: String?

    init(
        name: HoloAgentEventName,
        timestamp: Date = Date(),
        job: HoloAgentJob? = nil,
        generation: Int? = nil,
        checkpointRevision: Int? = nil,
        leaseKind: HoloAgentExecutionLeaseKind? = nil,
        durationMilliseconds: Int? = nil,
        errorCode: String? = nil,
        requestID: String? = nil
    ) {
        self.id = UUID().uuidString
        self.name = name
        self.timestamp = timestamp
        self.jobID = job?.id
        self.jobType = job?.type
        self.trigger = job?.trigger
        self.state = job?.state
        self.waitReason = job?.waitReason
        self.generation = generation ?? job?.executionGeneration
        self.checkpointRevision = checkpointRevision
        self.leaseKind = leaseKind
        self.round = job?.budget.consumedLLMRounds
        self.durationMilliseconds = durationMilliseconds
        self.errorCode = errorCode
        self.requestID = requestID
    }
}

nonisolated struct HoloAgentReliabilityMetrics: Codable, Equatable, Sendable {
    var eventCount: Int
    var jobsCreated: Int
    var jobsCompleted: Int
    var jobsFailed: Int
    var jobsCancelled: Int
    var resumesStarted: Int
    var resumedJobsCompleted: Int
    var executionExpirations: Int
    var staleExecutionsRejected: Int
    var stepIdempotencyHits: Int
    var reconciledResults: Int
    var completionRate: Double?
    var resumeCompletionRate: Double?

    static func make(from events: [HoloAgentTelemetryEvent]) -> Self {
        let createdIDs = Set(events.filter { $0.name == .jobCreated }.compactMap(\.jobID))
        let completedIDs = Set(events.filter { $0.name == .jobCompleted }.compactMap(\.jobID))
        let resumedIDs = Set(events.filter { $0.name == .resumeStarted }.compactMap(\.jobID))
        return Self(
            eventCount: events.count,
            jobsCreated: createdIDs.count,
            jobsCompleted: completedIDs.count,
            jobsFailed: events.filter { $0.name == .jobFailed }.count,
            jobsCancelled: events.filter { $0.name == .jobCancelled }.count,
            resumesStarted: events.filter { $0.name == .resumeStarted }.count,
            resumedJobsCompleted: resumedIDs.intersection(completedIDs).count,
            executionExpirations: events.filter { $0.name == .executionExpired }.count,
            staleExecutionsRejected: events.filter { $0.name == .executionStaleRejected }.count,
            stepIdempotencyHits: events.filter { $0.name == .stepIdempotencyHit }.count,
            reconciledResults: events.filter { $0.name == .resultReconciled }.count,
            completionRate: createdIDs.isEmpty ? nil : Double(completedIDs.intersection(createdIDs).count) / Double(createdIDs.count),
            resumeCompletionRate: resumedIDs.isEmpty ? nil : Double(resumedIDs.intersection(completedIDs).count) / Double(resumedIDs.count)
        )
    }
}

protocol HoloAgentEventRecording: Sendable {
    func record(_ event: HoloAgentTelemetryEvent) async
}

struct HoloNoopAgentEventRecorder: HoloAgentEventRecording {
    nonisolated static let shared = HoloNoopAgentEventRecorder()
    func record(_ event: HoloAgentTelemetryEvent) async {}
}

/// 本地环形事件仓库：最多保留 1,000 条、14 天；写失败只记系统日志，不阻塞 Agent 主链。
actor HoloAgentEventStore: HoloAgentEventRecording {
    static let shared = HoloAgentEventStore()

    private let store: HoloAgentJSONStore<HoloAgentTelemetryEvent>
    private let maxCount: Int
    private let retentionInterval: TimeInterval
    private let logger = Logger(subsystem: "com.holo.app", category: "AgentObservability")

    init(directory: URL? = nil, maxCount: Int = 1_000, retentionDays: Int = 14) {
        if let directory {
            self.store = HoloAgentJSONStore(fileName: "agentTelemetryEvents.json", directory: directory)
        } else {
            self.store = HoloAgentJSONStore(fileName: "agentTelemetryEvents.json")
        }
        self.maxCount = max(1, maxCount)
        self.retentionInterval = TimeInterval(max(1, retentionDays) * 86_400)
    }

    func record(_ event: HoloAgentTelemetryEvent) async {
        do {
            let cutoff = event.timestamp.addingTimeInterval(-retentionInterval)
            try await store.mutate { events in
                events.removeAll { $0.timestamp < cutoff }
                events.append(event)
                if events.count > maxCount {
                    events.removeFirst(events.count - maxCount)
                }
            }
        } catch {
            logger.error("[Agent] 结构化事件写入失败 name=\(event.name.rawValue, privacy: .public)")
        }
    }

    func load() async throws -> [HoloAgentTelemetryEvent] {
        try await store.load()
    }

    func metrics() async throws -> HoloAgentReliabilityMetrics {
        HoloAgentReliabilityMetrics.make(from: try await load())
    }
}
