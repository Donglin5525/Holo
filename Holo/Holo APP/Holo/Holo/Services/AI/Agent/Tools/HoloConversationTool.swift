//
//  HoloConversationTool.swift
//  Holo
//
//  只暴露对话活动与 intent 元数据，不返回历史消息原文。
//

import Foundation

struct HoloConversationRecord: Codable, Equatable, Sendable {
    var id: UUID
    var role: String
    var intent: String?
    var timestamp: Date
}

protocol HoloConversationDataSource: Sendable {
    func recentRecords(limit: Int) async -> HoloDataSourceRead<[HoloConversationRecord]>
}

struct HoloConversationTool: HoloDataTool {

    let descriptor = HoloToolDescriptor(
        name: "conversation",
        description: "近期对话活动摘要（消息数量 / intent 频次 / 当前会话活跃度；不含历史原文）",
        supportedQueries: ["recent_intent_summary", "session_activity"],
        supportedTimeRanges: ["recent"],
        outputMetrics: [
            "conversation.message.count",
            "conversation.user.count",
            "conversation.assistant.count",
            "conversation.intent.count",
            "conversation.session.message_count"
        ],
        sensitivityPolicy: "sensitive"
    )

    private let dataSource: HoloConversationDataSource

    init(dataSource: HoloConversationDataSource) {
        self.dataSource = dataSource
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        descriptor.supportedQueries.contains(request.query)
            ? .valid
            : .invalid(reason: "不支持的对话查询：\(request.query)")
    }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        let read = await dataSource.recentRecords(limit: 50)
        let records = read.value.sorted { $0.timestamp < $1.timestamp }
        if let failure = readFailure(request, read: read) { return failure }
        guard !records.isEmpty else {
            return result(
                request,
                status: .empty,
                metrics: [],
                events: [],
                warnings: [HoloToolWarning(code: "NO_CONVERSATION_DATA", message: "没有可用的近期对话元数据")]
            )
        }

        let output: HoloDataToolResult
        switch request.query {
        case "recent_intent_summary":
            output = intentSummary(request, records: records)
        case "session_activity":
            output = sessionActivity(request, records: records)
        default:
            return result(
                request,
                status: .error,
                metrics: [],
                events: [],
                warnings: [],
                error: HoloToolError(
                    code: HoloToolErrorCode.invalidParams,
                    message: "不支持的对话查询：\(request.query)",
                    recoverable: true
                )
            )
        }
        return applyingReadMetadata(output, read: read)
    }
}

private extension HoloConversationTool {

    func intentSummary(
        _ request: HoloToolRequest,
        records: [HoloConversationRecord]
    ) -> HoloDataToolResult {
        var counts: [String: Int] = [:]
        for intent in records.compactMap(\.intent).filter({ !$0.isEmpty }) {
            counts[intent, default: 0] += 1
        }
        let events = counts.keys.sorted().map { intent in
            HoloEvidenceEvent(
                id: "conversation-intent-\(Self.stableToken(intent))",
                occurredAt: records.last?.timestamp,
                metricKey: "conversation.intent.count",
                metricValue: Double(counts[intent] ?? 0),
                excerpt: "近期对话意图 \(intent)：\(counts[intent] ?? 0) 次"
            )
        }
        return result(
            request,
            metrics: [
                metric("conversation.message.count", Double(records.count), unit: "条"),
                metric("conversation.user.count", Double(records.filter { $0.role == "user" }.count), unit: "条"),
                metric("conversation.assistant.count", Double(records.filter { $0.role == "assistant" }.count), unit: "条")
            ],
            events: events
        )
    }

    func sessionActivity(
        _ request: HoloToolRequest,
        records: [HoloConversationRecord]
    ) -> HoloDataToolResult {
        let descending = records.sorted { $0.timestamp > $1.timestamp }
        var currentSession: [HoloConversationRecord] = []
        var previousTimestamp: Date?
        for record in descending {
            if let previousTimestamp,
               previousTimestamp.timeIntervalSince(record.timestamp) > 4 * 60 * 60 {
                break
            }
            currentSession.append(record)
            previousTimestamp = record.timestamp
        }
        let latest = currentSession.first?.timestamp
        return result(
            request,
            metrics: [metric("conversation.session.message_count", Double(currentSession.count), unit: "条")],
            events: [
                HoloEvidenceEvent(
                    id: "conversation-session-\(currentSession.first?.id.uuidString.lowercased() ?? "empty")",
                    occurredAt: latest,
                    metricKey: "conversation.session.message_count",
                    metricValue: Double(currentSession.count),
                    excerpt: "当前会话共 \(currentSession.count) 条完成消息"
                )
            ]
        )
    }

    func result(
        _ request: HoloToolRequest,
        status: HoloToolResultStatus = .success,
        metrics: [HoloMetric],
        events: [HoloEvidenceEvent],
        warnings: [HoloToolWarning] = [],
        error: HoloToolError? = nil
    ) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id,
            tool: request.tool,
            status: status,
            coverage: nil,
            metrics: metrics,
            events: events,
            warnings: warnings,
            error: error,
            sensitivity: .sensitive
        )
    }

    func metric(_ key: String, _ value: Double, unit: String) -> HoloMetric {
        HoloMetric(metricKey: key, value: value, unit: unit, baselineValue: nil, comparison: nil)
    }

    func readFailure(
        _ request: HoloToolRequest,
        read: HoloDataSourceRead<[HoloConversationRecord]>
    ) -> HoloDataToolResult? {
        guard [.unavailable, .waitingForUnlock, .error].contains(read.status) else { return nil }
        let waiting = read.status == .waitingForUnlock
        return result(
            request,
            status: waiting ? .unavailable : (read.status == .error ? .error : .unavailable),
            metrics: [],
            events: [],
            warnings: [HoloToolWarning(
                code: waiting ? "WAITING_FOR_UNLOCK" : "CONVERSATION_DATA_UNAVAILABLE",
                message: read.warning ?? (waiting ? "设备解锁后才能读取对话元数据" : "暂时无法读取对话元数据")
            )],
            error: HoloToolError(
                code: waiting ? "WAITING_FOR_UNLOCK" : "DATA_SOURCE_UNAVAILABLE",
                message: read.warning ?? "对话数据源读取失败",
                recoverable: true
            )
        )
    }

    func applyingReadMetadata(
        _ result: HoloDataToolResult,
        read: HoloDataSourceRead<[HoloConversationRecord]>
    ) -> HoloDataToolResult {
        guard read.status == .partial || read.isTruncated else { return result }
        var updated = result
        updated.status = .partial
        let detail = "仅返回最近 \(read.returnedCount ?? read.value.count) 条"
            + (read.totalCount.map { "，共 \($0) 条" } ?? "")
        updated.warnings.append(HoloToolWarning(
            code: "CONVERSATION_DATA_TRUNCATED",
            message: read.warning ?? detail
        ))
        return updated
    }

    static func stableToken(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }
}
