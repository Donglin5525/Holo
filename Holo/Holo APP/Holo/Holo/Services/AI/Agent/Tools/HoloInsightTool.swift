//
//  HoloInsightTool.swift
//  Holo
//
//  读取用户已经看到的周期洞察摘要，不返回 rawResponse/cardsJSON。
//

import Foundation

struct HoloInsightToolRecord: Codable, Equatable, Sendable {
    var id: UUID
    var periodType: String
    var periodStart: Date
    var periodEnd: Date
    var title: String
    var summary: String
    var generatedAt: Date
    var status: String
}

protocol HoloInsightDataSource: Sendable {
    func recentInsights(limit: Int) async -> [HoloInsightToolRecord]
}

struct HoloInsightTool: HoloDataTool {

    let descriptor = HoloToolDescriptor(
        name: "insight",
        description: "Holo 已生成的历史观察摘要（日/周/月洞察标题、摘要和周期）",
        supportedQueries: ["latest_observation", "recent_observations"],
        supportedTimeRanges: ["recent", "30d"],
        outputMetrics: ["insight.observation.count"],
        sensitivityPolicy: "sensitive"
    )

    private let dataSource: HoloInsightDataSource

    init(dataSource: HoloInsightDataSource) {
        self.dataSource = dataSource
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        descriptor.supportedQueries.contains(request.query)
            ? .valid
            : .invalid(reason: "不支持的历史观察查询：\(request.query)")
    }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        let records = await dataSource.recentInsights(limit: 6)
            .sorted { $0.generatedAt > $1.generatedAt }
        guard !records.isEmpty else {
            return result(
                request,
                status: .empty,
                records: [],
                warnings: [HoloToolWarning(code: "NO_INSIGHT_DATA", message: "没有可用的历史观察")]
            )
        }

        switch request.query {
        case "latest_observation":
            return result(request, records: Array(records.prefix(1)))
        case "recent_observations":
            return result(request, records: Array(records.prefix(6)))
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
                    message: "不支持的历史观察查询：\(request.query)",
                    recoverable: true
                ),
                sensitivity: .sensitive
            )
        }
    }
}

private extension HoloInsightTool {

    func result(
        _ request: HoloToolRequest,
        status: HoloToolResultStatus = .success,
        records: [HoloInsightToolRecord],
        warnings: [HoloToolWarning] = []
    ) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id,
            tool: request.tool,
            status: status,
            coverage: nil,
            metrics: records.isEmpty ? [] : [
                HoloMetric(
                    metricKey: "insight.observation.count",
                    value: Double(records.count),
                    unit: "条",
                    baselineValue: nil,
                    comparison: nil
                )
            ],
            events: records.map { record in
                HoloEvidenceEvent(
                    id: "insight-\(record.id.uuidString.lowercased())",
                    occurredAt: record.generatedAt,
                    metricKey: "insight.observation",
                    metricValue: nil,
                    excerpt: "\(Self.periodLabel(record.periodType))观察「\(record.title)」：\(record.summary)"
                )
            },
            warnings: warnings,
            error: nil,
            sensitivity: .sensitive
        )
    }

    static func periodLabel(_ rawValue: String) -> String {
        switch rawValue {
        case "daily": return "每日"
        case "weekly": return "每周"
        case "monthly": return "每月"
        case "quarterly": return "季度"
        default: return "周期"
        }
    }
}
