//
//  HoloMemoryTool.swift
//  Holo
//
//  Agent 的记忆工具只消费 Query Service 的 allowlist 结果。
//

import Foundation

struct HoloMemoryToolRecord: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var summary: String
    var occurredAt: Date?
    var persistenceClass: HoloMemoryPersistenceClass
}

protocol HoloMemoryDataSource: Sendable {
    func queryRecords(question: String, currentStateOnly: Bool) async -> [HoloMemoryToolRecord]
    func suppressionCount() async -> Int
}

struct HoloMemoryTool: HoloDataTool {
    let descriptor = HoloToolDescriptor(
        name: "memory",
        description: "本地统一记忆查询（领域 / 跨域 / 抑制状态）",
        supportedQueries: ["recall_summary", "suppression_summary", "recent_episodic"],
        supportedTimeRanges: [],
        outputMetrics: [
            "memory.recall.count",
            "memory.current_state.count",
            "memory.suppression.active_count"
        ],
        sensitivityPolicy: "按 Query Service allowlist 返回，不暴露抑制正文"
    )

    private let dataSource: HoloMemoryDataSource

    init(dataSource: HoloMemoryDataSource) {
        self.dataSource = dataSource
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        let supported: Set<String> = ["recall_summary", "suppression_summary", "recent_episodic"]
        if supported.contains(request.query) { return .valid }
        return .invalid(reason: "不支持的查询：\(request.query)")
    }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        let question = request.parameters["question"] ?? "我最近状态如何"
        switch request.query {
        case "recall_summary":
            let records = await dataSource.queryRecords(
                question: question,
                currentStateOnly: false
            )
            return Self.buildRecordResult(
                request: request,
                records: records,
                countMetric: "memory.recall.count"
            )
        case "recent_episodic":
            let records = await dataSource.queryRecords(
                question: question,
                currentStateOnly: true
            )
            return Self.buildRecordResult(
                request: request,
                records: records,
                countMetric: "memory.current_state.count"
            )
        case "suppression_summary":
            return Self.buildSuppressionResult(
                request: request,
                count: await dataSource.suppressionCount()
            )
        default:
            return HoloDataToolResult(
                toolRequestID: request.id,
                tool: request.tool,
                status: .error,
                coverage: nil,
                metrics: [],
                events: [],
                warnings: [],
                error: HoloToolError(
                    code: HoloToolErrorCode.invalidParams,
                    message: "不支持的查询：\(request.query)",
                    recoverable: true
                )
            )
        }
    }

    private static func buildRecordResult(
        request: HoloToolRequest,
        records: [HoloMemoryToolRecord],
        countMetric: String
    ) -> HoloDataToolResult {
        if records.isEmpty { return emptyResult(request) }
        let events = records.map {
            HoloEvidenceEvent(
                id: $0.id,
                occurredAt: $0.occurredAt,
                metricKey: countMetric,
                metricValue: nil,
                excerpt: $0.summary
            )
        }
        return HoloDataToolResult(
            toolRequestID: request.id,
            tool: request.tool,
            status: .success,
            coverage: nil,
            metrics: [HoloMetric(
                metricKey: countMetric,
                value: Double(records.count),
                unit: "条",
                baselineValue: nil,
                comparison: nil
            )],
            events: events,
            warnings: [],
            error: nil
        )
    }

    private static func buildSuppressionResult(
        request: HoloToolRequest,
        count: Int
    ) -> HoloDataToolResult {
        guard count > 0 else { return emptyResult(request) }
        return HoloDataToolResult(
            toolRequestID: request.id,
            tool: request.tool,
            status: .success,
            coverage: nil,
            metrics: [HoloMetric(
                metricKey: "memory.suppression.active_count",
                value: Double(count),
                unit: "条",
                baselineValue: nil,
                comparison: nil
            )],
            events: [],
            warnings: [],
            error: nil
        )
    }

    private static func emptyResult(_ request: HoloToolRequest) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id,
            tool: request.tool,
            status: .empty,
            coverage: nil,
            metrics: [],
            events: [],
            warnings: [],
            error: nil
        )
    }
}
