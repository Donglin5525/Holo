//
//  HoloMemoryTool.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 2.3 本地记忆工具
//  读取长期确认记忆 / 情景活跃记忆 / 抑制规则，转为 Agent 可用证据。
//  依赖 HoloMemoryDataSource 协议而非具体 Store，便于测试注入（生产实现见 HoloMemoryDataSource.swift）。
//

import Foundation

/// MemoryTool 读取的记忆记录（中性视图，隔离真实模型依赖，便于测试）。
struct HoloMemoryToolRecord: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var summary: String
    var occurredAt: Date?
}

/// MemoryTool 读取的抑制规则（中性视图）。
struct HoloMemoryToolSuppression: Codable, Equatable, Sendable {
    var id: String
    var originalSummary: String
}

/// 记忆数据源协议：MemoryTool 依赖此协议，生产实现包裹真实 Store，测试用 mock。
protocol HoloMemoryDataSource: Sendable {
    /// 长期确认记忆（confirmed + silentlyAccepted）。
    func longTermConfirmed() async -> [HoloMemoryToolRecord]
    /// 情景活跃记忆（active + suggested）。
    func episodicActive() async -> [HoloMemoryToolRecord]
    /// 生效中的抑制规则。
    func suppressionRules() async -> [HoloMemoryToolSuppression]
}

/// 本地记忆工具：把三类记忆数据转成 Agent 可用证据（metrics + events）。
struct HoloMemoryTool: HoloDataTool {

    let descriptor = HoloToolDescriptor(
        name: "memory",
        description: "本地记忆查询（长期确认 / 情景活跃 / 抑制规则）",
        supportedQueries: ["recall_summary", "suppression_summary", "recent_episodic"],
        supportedTimeRanges: [],
        outputMetrics: [
            "memory.long_term.count",
            "memory.episodic.active_count",
            "memory.suppression.active_count"
        ],
        sensitivityPolicy: "normal"
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
        switch request.query {
        case "recall_summary":
            let records = await dataSource.longTermConfirmed()
            return Self.buildRecordResult(request: request, records: records,
                                          countMetric: "memory.long_term.count")
        case "recent_episodic":
            let records = await dataSource.episodicActive()
            return Self.buildRecordResult(request: request, records: records,
                                          countMetric: "memory.episodic.active_count")
        case "suppression_summary":
            let rules = await dataSource.suppressionRules()
            return Self.buildSuppressionResult(request: request, rules: rules)
        default:
            // validate 已拦截非法 query，此处兜底
            return HoloDataToolResult(
                toolRequestID: request.id, tool: request.tool, status: .error,
                coverage: nil, metrics: [], events: [], warnings: [],
                error: HoloToolError(code: HoloToolErrorCode.invalidParams,
                                     message: "不支持的查询：\(request.query)", recoverable: true)
            )
        }
    }

    // MARK: - 组装辅助

    private static func buildRecordResult(request: HoloToolRequest,
                                          records: [HoloMemoryToolRecord],
                                          countMetric: String) -> HoloDataToolResult {
        if records.isEmpty { return emptyResult(request) }
        let events = records.map {
            HoloEvidenceEvent(id: $0.id, occurredAt: $0.occurredAt,
                              metricKey: countMetric, metricValue: nil, excerpt: $0.summary)
        }
        let metrics = [HoloMetric(metricKey: countMetric, value: Double(records.count),
                                  unit: "条", baselineValue: nil, comparison: nil)]
        return HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .success,
            coverage: nil, metrics: metrics, events: events, warnings: [], error: nil
        )
    }

    private static func buildSuppressionResult(request: HoloToolRequest,
                                               rules: [HoloMemoryToolSuppression]) -> HoloDataToolResult {
        if rules.isEmpty { return emptyResult(request) }
        let events = rules.map {
            HoloEvidenceEvent(id: $0.id, occurredAt: nil,
                              metricKey: "memory.suppression.active_count",
                              metricValue: nil, excerpt: $0.originalSummary)
        }
        let metrics = [HoloMetric(metricKey: "memory.suppression.active_count",
                                  value: Double(rules.count), unit: "条",
                                  baselineValue: nil, comparison: nil)]
        return HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .success,
            coverage: nil, metrics: metrics, events: events, warnings: [], error: nil
        )
    }

    private static func emptyResult(_ request: HoloToolRequest) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .empty,
            coverage: nil, metrics: [], events: [], warnings: [], error: nil
        )
    }
}
