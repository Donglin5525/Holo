//
//  HoloHealthTool.swift
//  Holo
//
//  HoloAI Agent V3.1 — HealthTool MVP
//  将 HealthKit 睡眠范围数据转为 Agent 可验证的指标和每日证据。
//

import Foundation

struct HoloHealthDailyRecord: Codable, Equatable, Sendable {
    var date: Date
    var value: Double
}

protocol HoloHealthDataSource: Sendable {
    func sleepRecords(timeRange: HoloAgentTimeRange?) async -> [HoloHealthDailyRecord]
}

struct HoloHealthTool: HoloDataTool {

    let descriptor = HoloToolDescriptor(
        name: "health",
        description: "健康数据分析（睡眠时长 / 睡眠趋势 / 低睡眠天数）",
        supportedQueries: ["sleep_summary"],
        supportedTimeRanges: ["recent", "7d", "14d", "30d"],
        outputMetrics: [
            "health.sleep.average_hours",
            "health.sleep.goal_met_days",
            "health.sleep.low_days",
            "health.sleep.hours"
        ],
        sensitivityPolicy: "normal"
    )

    private let dataSource: HoloHealthDataSource

    init(dataSource: HoloHealthDataSource) {
        self.dataSource = dataSource
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        request.query == "sleep_summary"
            ? .valid
            : .invalid(reason: "不支持的健康查询：\(request.query)")
    }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        let records = await dataSource.sleepRecords(timeRange: request.timeRange)
            .filter { $0.value > 0 }
            .sorted { $0.date < $1.date }
        guard !records.isEmpty else {
            return HoloDataToolResult(
                toolRequestID: request.id,
                tool: request.tool,
                status: .empty,
                coverage: nil,
                metrics: [],
                events: [],
                warnings: [
                    HoloToolWarning(code: "NO_SLEEP_DATA", message: "没有可用的睡眠数据")
                ],
                error: nil
            )
        }

        let total = records.reduce(0) { $0 + $1.value }
        let average = total / Double(records.count)
        let goalMetDays = records.filter { $0.value >= 8 }.count
        let lowDays = records.filter { $0.value < 6 }.count

        return HoloDataToolResult(
            toolRequestID: request.id,
            tool: request.tool,
            status: .success,
            coverage: HoloDataCoverage(
                coveredDays: records.count,
                totalDays: records.count,
                coverageRatio: 1,
                missingRanges: [],
                note: "已读取 \(records.count) 天睡眠数据"
            ),
            metrics: [
                HoloMetric(
                    metricKey: "health.sleep.average_hours",
                    value: Self.round(average),
                    unit: "小时",
                    baselineValue: nil,
                    comparison: nil
                ),
                HoloMetric(
                    metricKey: "health.sleep.goal_met_days",
                    value: Double(goalMetDays),
                    unit: "天",
                    baselineValue: nil,
                    comparison: nil
                ),
                HoloMetric(
                    metricKey: "health.sleep.low_days",
                    value: Double(lowDays),
                    unit: "天",
                    baselineValue: nil,
                    comparison: nil
                )
            ],
            events: records.map(Self.event),
            warnings: [],
            error: nil
        )
    }

    private static func event(for record: HoloHealthDailyRecord) -> HoloEvidenceEvent {
        HoloEvidenceEvent(
            id: "sleep-\(Self.idFormatter.string(from: record.date))",
            occurredAt: record.date,
            metricKey: "health.sleep.hours",
            metricValue: Self.round(record.value),
            excerpt: "\(Self.displayFormatter.string(from: record.date)) 睡眠 \(String(format: "%.1f", record.value)) 小时"
        )
    }

    private static func round(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static let idFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
}
