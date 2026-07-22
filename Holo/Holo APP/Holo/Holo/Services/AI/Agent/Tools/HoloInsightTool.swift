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
    func recentInsights(limit: Int) async -> HoloDataSourceRead<[HoloInsightToolRecord]>
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
        let read = await dataSource.recentInsights(limit: 6)
        let records = read.value.sorted { $0.generatedAt > $1.generatedAt }
        if [.unavailable, .waitingForUnlock, .error].contains(read.status) {
            return result(
                request,
                status: read.status == .error ? .error : .unavailable,
                records: [],
                warnings: [HoloToolWarning(
                    code: read.status == .waitingForUnlock ? "WAITING_FOR_UNLOCK" : "INSIGHT_DATA_UNAVAILABLE",
                    message: read.warning ?? "暂时无法读取历史观察"
                )],
                error: HoloToolError(code: "DATA_SOURCE_UNAVAILABLE", message: read.warning ?? "历史观察读取失败", recoverable: true)
            )
        }
        guard !records.isEmpty else {
            return result(
                request,
                status: .empty,
                records: [],
                warnings: [HoloToolWarning(code: "NO_INSIGHT_DATA", message: "没有可用的历史观察")]
            )
        }

        var output: HoloDataToolResult
        switch request.query {
        case "latest_observation":
            output = result(request, records: Array(records.prefix(1)))
        case "recent_observations":
            output = result(request, records: Array(records.prefix(6)))
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
        if read.status == .partial || read.isTruncated {
            output.status = .partial
            output.warnings.append(HoloToolWarning(
                code: "INSIGHT_DATA_TRUNCATED",
                message: read.warning ?? "仅返回最近 \(read.returnedCount ?? records.count) 条历史观察"
            ))
        }
        return output
    }
}

private extension HoloInsightTool {

    func result(
        _ request: HoloToolRequest,
        status: HoloToolResultStatus = .success,
        records: [HoloInsightToolRecord],
        warnings: [HoloToolWarning] = [],
        error: HoloToolError? = nil
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
            error: error,
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
