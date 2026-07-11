//
//  HoloHealthTool.swift
//  Holo
//
//  HoloAI Agent V3.1 — HealthKit 全指标只读工具。
//

import Foundation

enum HoloHealthMetricKind: String, Codable, CaseIterable, Hashable, Sendable {
    case steps
    case sleep
    case stand
    case activity
}

struct HoloHealthDailyRecord: Codable, Equatable, Sendable {
    var date: Date
    var value: Double
}

struct HoloHealthWorkoutRecord: Codable, Equatable, Sendable {
    var date: Date
    var totalMinutes: Double
    var sessionCount: Int
    var topType: String?
}

protocol HoloHealthDataSource: Sendable {
    func dailyRecords(
        for metric: HoloHealthMetricKind,
        timeRange: HoloAgentTimeRange?
    ) async -> [HoloHealthDailyRecord]

    func workoutRecords(timeRange: HoloAgentTimeRange?) async -> [HoloHealthWorkoutRecord]
}

struct HoloHealthTool: HoloDataTool {

    static let dynamicCatalog = HoloDataCatalog(datasets: HoloHealthMetricKind.allCases.map { kind in
        let config: (name: String, unit: String, description: String) = switch kind {
        case .steps: ("health.steps", "步", "每日步数")
        case .sleep: ("health.sleep", "小时", "每日睡眠时长")
        case .stand: ("health.stand", "小时", "每日站立小时")
        case .activity: ("health.activity", "分钟", "每日活动分钟")
        }
        return HoloDataSetSchema(
            name: config.name,
            domain: "health",
            description: config.description,
            timeField: "date",
            fields: [
                HoloDataField(name: "date", type: .date, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "记录日期"),
                HoloDataField(name: "value", type: .number, unit: config.unit, filterable: true, groupable: false, aggregatable: true, description: config.description)
            ],
            sensitivity: .sensitive,
            maximumRangeDays: 366
        )
    })

    let descriptor = HoloToolDescriptor(
        name: "health",
        description: "健康数据分析（综合状态 / 步数 / 睡眠 / 站立 / 活动分钟 / 运动会话）",
        supportedQueries: [
            "health_overview",
            "steps_summary",
            "sleep_summary",
            "stand_summary",
            "activity_summary",
            "workout_summary",
            "dynamic_query"
        ],
        supportedTimeRanges: ["recent", "7d", "14d", "30d"],
        outputMetrics: [
            "health.steps.average",
            "health.steps.goal_met_days",
            "health.steps.daily",
            "health.sleep.average_hours",
            "health.sleep.goal_met_days",
            "health.sleep.low_days",
            "health.sleep.hours",
            "health.stand.average_hours",
            "health.stand.goal_met_days",
            "health.stand.hours",
            "health.activity.average_minutes",
            "health.activity.goal_met_days",
            "health.activity.minutes",
            "health.workout.total_minutes",
            "health.workout.session_count",
            "health.workout.active_days",
            "health.workout.daily_minutes"
        ],
        sensitivityPolicy: "sensitive",
        dynamicCatalog: Self.dynamicCatalog
    )

    private let dataSource: HoloHealthDataSource

    init(dataSource: HoloHealthDataSource) {
        self.dataSource = dataSource
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        if request.query == "dynamic_query" {
            guard let plan = request.dynamicPlan else { return .invalid(reason: "dynamic_query 缺少 dynamicPlan") }
            do {
                try HoloDynamicQueryValidator.validate(plan, catalog: Self.dynamicCatalog)
                guard plan.source.hasPrefix("health.") else { return .invalid(reason: "健康工具不能访问 \(plan.source)") }
                return .valid
            } catch { return .invalid(reason: error.localizedDescription) }
        }
        return descriptor.supportedQueries.contains(request.query)
            ? .valid
            : .invalid(reason: "不支持的健康查询：\(request.query)")
    }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        if request.query == "dynamic_query", let plan = request.dynamicPlan {
            return await dynamicResult(request, plan: plan)
        }
        switch request.query {
        case "health_overview":
            return await overview(request)
        case "steps_summary":
            return await dailySummary(request, metric: .steps)
        case "sleep_summary":
            return await dailySummary(request, metric: .sleep)
        case "stand_summary":
            return await dailySummary(request, metric: .stand)
        case "activity_summary":
            return await dailySummary(request, metric: .activity)
        case "workout_summary":
            return await workoutSummary(request)
        default:
            return error(request, reason: "不支持的健康查询：\(request.query)")
        }
    }
}

private extension HoloHealthTool {

    func dynamicResult(_ request: HoloToolRequest, plan: HoloDynamicQueryPlan) async -> HoloDataToolResult {
        guard let kind = Self.metricKind(for: plan.source) else { return error(request, reason: "未注册健康数据集：\(plan.source)") }
        let currentRange = plan.timeRange ?? request.timeRange
        let baselineRange = plan.baseline
            ?? request.baseline
            ?? HoloDynamicQueryRangeResolver.baselineIfNeeded(for: plan, currentRange: currentRange)
        let current = await dataSource.dailyRecords(for: kind, timeRange: currentRange)
        let baseline = await dataSource.dailyRecords(for: kind, timeRange: baselineRange)
        let currentRows = current.filter { $0.value > 0 }.map { Self.queryRow($0, kind: kind) }
        let baselineRows = baseline.filter { $0.value > 0 }.map { Self.queryRow($0, kind: kind) }
        var scopedPlan = plan
        scopedPlan.timeRange = currentRange
        scopedPlan.baseline = baselineRange
        do {
            let output = try HoloDynamicQueryEngine.execute(
                plan: scopedPlan,
                catalog: Self.dynamicCatalog,
                currentRows: currentRows,
                baselineRows: baselineRows
            )
            return HoloDataToolResult(
                toolRequestID: request.id,
                tool: request.tool,
                status: output.metrics.isEmpty ? .empty : .success,
                coverage: output.coverage,
                metrics: output.metrics,
                events: output.events,
                warnings: [],
                error: nil,
                sensitivity: .sensitive
            )
        } catch let caughtError {
            return error(request, reason: caughtError.localizedDescription)
        }
    }

    static func metricKind(for source: String) -> HoloHealthMetricKind? {
        switch source {
        case "health.steps": .steps
        case "health.sleep": .sleep
        case "health.stand": .stand
        case "health.activity": .activity
        default: nil
        }
    }

    static func queryRow(_ record: HoloHealthDailyRecord, kind: HoloHealthMetricKind) -> HoloQueryRow {
        HoloQueryRow(
            id: "\(kind.rawValue)-\(idFormatter.string(from: record.date))",
            occurredAt: record.date,
            fields: ["date": .date(record.date), "value": .number(record.value)],
            excerpt: "\(displayFormatter.string(from: record.date)) \(kind.rawValue) \(record.value)"
        )
    }

    func dailySummary(
        _ request: HoloToolRequest,
        metric: HoloHealthMetricKind
    ) async -> HoloDataToolResult {
        let records = await dataSource.dailyRecords(for: metric, timeRange: request.timeRange)
            .filter { $0.value > 0 }
            .sorted { $0.date < $1.date }

        guard !records.isEmpty else {
            return empty(request, warning: warning(for: metric))
        }

        let summaryMetrics = metrics(for: metric, records: records)
        return HoloDataToolResult(
            toolRequestID: request.id,
            tool: request.tool,
            status: .success,
            coverage: coverage(records.map(\.date), timeRange: request.timeRange),
            metrics: summaryMetrics,
            events: summaryEvidenceEvents(summaryMetrics, metric: metric, records: records)
                + records.map { event(for: metric, record: $0) },
            warnings: [],
            error: nil,
            sensitivity: .sensitive
        )
    }

    func workoutSummary(_ request: HoloToolRequest) async -> HoloDataToolResult {
        let records = await dataSource.workoutRecords(timeRange: request.timeRange)
            .filter { $0.totalMinutes > 0 || $0.sessionCount > 0 }
            .sorted { $0.date < $1.date }

        guard !records.isEmpty else {
            return empty(
                request,
                warning: HoloToolWarning(code: "NO_WORKOUT_DATA", message: "没有可用的运动会话数据")
            )
        }

        let totalMinutes = records.reduce(0) { $0 + $1.totalMinutes }
        let sessionCount = records.reduce(0) { $0 + $1.sessionCount }
        let summaryMetrics = [
            metric("health.workout.total_minutes", totalMinutes, unit: "分钟"),
            metric("health.workout.session_count", Double(sessionCount), unit: "次"),
            metric("health.workout.active_days", Double(records.count), unit: "天")
        ]
        return HoloDataToolResult(
            toolRequestID: request.id,
            tool: request.tool,
            status: .success,
            coverage: coverage(records.map(\.date), timeRange: request.timeRange),
            metrics: summaryMetrics,
            events: summaryEvidenceEvents(summaryMetrics, label: "运动汇总") + records.map(workoutEvent),
            warnings: [],
            error: nil,
            sensitivity: .sensitive
        )
    }

    func overview(_ request: HoloToolRequest) async -> HoloDataToolResult {
        async let steps = dailySummary(request, metric: .steps)
        async let sleep = dailySummary(request, metric: .sleep)
        async let stand = dailySummary(request, metric: .stand)
        async let activity = dailySummary(request, metric: .activity)
        async let workout = workoutSummary(request)

        let results = await [steps, sleep, stand, activity, workout]
        let available = results.filter { $0.status == .success || $0.status == .partial }
        guard !available.isEmpty else {
            return HoloDataToolResult(
                toolRequestID: request.id,
                tool: request.tool,
                status: .empty,
                coverage: nil,
                metrics: [],
                events: [],
                warnings: results.flatMap(\.warnings),
                error: nil,
                sensitivity: .sensitive
            )
        }

        let events = available.flatMap(\.events)
        return HoloDataToolResult(
            toolRequestID: request.id,
            tool: request.tool,
            status: available.count == results.count ? .success : .partial,
            coverage: coverage(events.compactMap(\.occurredAt), timeRange: request.timeRange),
            metrics: available.flatMap(\.metrics),
            events: events,
            warnings: results.flatMap(\.warnings),
            error: nil,
            sensitivity: .sensitive
        )
    }

    func metrics(
        for metricKind: HoloHealthMetricKind,
        records: [HoloHealthDailyRecord]
    ) -> [HoloMetric] {
        let average = records.reduce(0) { $0 + $1.value } / Double(records.count)
        switch metricKind {
        case .steps:
            return [
                metric("health.steps.average", average, unit: "步"),
                metric("health.steps.goal_met_days", Double(records.filter { $0.value >= 10_000 }.count), unit: "天")
            ]
        case .sleep:
            return [
                metric("health.sleep.average_hours", average, unit: "小时"),
                metric("health.sleep.goal_met_days", Double(records.filter { $0.value >= 8 }.count), unit: "天"),
                metric("health.sleep.low_days", Double(records.filter { $0.value < 6 }.count), unit: "天")
            ]
        case .stand:
            return [
                metric("health.stand.average_hours", average, unit: "小时"),
                metric("health.stand.goal_met_days", Double(records.filter { $0.value >= 12 }.count), unit: "天")
            ]
        case .activity:
            return [
                metric("health.activity.average_minutes", average, unit: "分钟"),
                metric("health.activity.goal_met_days", Double(records.filter { $0.value >= 30 }.count), unit: "天")
            ]
        }
    }

    func summaryEvidenceEvents(
        _ metrics: [HoloMetric],
        metric: HoloHealthMetricKind,
        records: [HoloHealthDailyRecord]
    ) -> [HoloEvidenceEvent] {
        let label: String = switch metric {
        case .steps: "步数汇总"
        case .sleep: "睡眠汇总"
        case .stand: "站立汇总"
        case .activity: "活动汇总"
        }
        return summaryEvidenceEvents(metrics, label: label, occurredAt: records.last?.date)
    }

    func summaryEvidenceEvents(
        _ metrics: [HoloMetric],
        label: String,
        occurredAt: Date? = nil
    ) -> [HoloEvidenceEvent] {
        metrics.map { metric in
            let valueText = metric.value.map { String(format: "%.2f", $0) } ?? "未知"
            return HoloEvidenceEvent(
                id: "summary-\(metric.metricKey)",
                occurredAt: occurredAt,
                metricKey: metric.metricKey,
                metricValue: metric.value,
                excerpt: "\(label)：\(metric.metricKey) = \(valueText) \(metric.unit ?? "")"
            )
        }
    }

    func event(
        for metricKind: HoloHealthMetricKind,
        record: HoloHealthDailyRecord
    ) -> HoloEvidenceEvent {
        let config: (key: String, label: String, unit: String, digits: Int) = switch metricKind {
        case .steps: ("health.steps.daily", "步数", "步", 0)
        case .sleep: ("health.sleep.hours", "睡眠", "小时", 1)
        case .stand: ("health.stand.hours", "站立", "小时", 1)
        case .activity: ("health.activity.minutes", "活动", "分钟", 0)
        }
        let valueText = config.digits == 0
            ? String(format: "%.0f", record.value)
            : String(format: "%.1f", record.value)
        return HoloEvidenceEvent(
            id: "\(metricKind.rawValue)-\(Self.idFormatter.string(from: record.date))",
            occurredAt: record.date,
            metricKey: config.key,
            metricValue: Self.round(record.value),
            excerpt: "\(Self.displayFormatter.string(from: record.date)) \(config.label) \(valueText) \(config.unit)"
        )
    }

    func workoutEvent(_ record: HoloHealthWorkoutRecord) -> HoloEvidenceEvent {
        let typeText = record.topType.map { " · \($0)" } ?? ""
        return HoloEvidenceEvent(
            id: "workout-\(Self.idFormatter.string(from: record.date))",
            occurredAt: record.date,
            metricKey: "health.workout.daily_minutes",
            metricValue: Self.round(record.totalMinutes),
            excerpt: "\(Self.displayFormatter.string(from: record.date)) 运动 \(String(format: "%.0f", record.totalMinutes)) 分钟 · \(record.sessionCount) 次\(typeText)"
        )
    }

    func coverage(_ dates: [Date], timeRange: HoloAgentTimeRange?) -> HoloDataCoverage {
        let calendar = Calendar.current
        let uniqueDays = Set(dates.map { calendar.startOfDay(for: $0) }).count
        let totalDays = Self.expectedDays(in: timeRange, calendar: calendar)
        return HoloDataCoverage(
            coveredDays: uniqueDays,
            totalDays: totalDays,
            coverageRatio: totalDays > 0 ? Double(uniqueDays) / Double(totalDays) : nil,
            missingRanges: [],
            note: "已读取 \(uniqueDays)/\(totalDays) 天健康数据"
        )
    }

    static func expectedDays(in timeRange: HoloAgentTimeRange?, calendar: Calendar) -> Int {
        guard let start = timeRange?.start, let end = timeRange?.end else { return 14 }
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        return max(1, calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 1)
    }

    func warning(for metric: HoloHealthMetricKind) -> HoloToolWarning {
        switch metric {
        case .steps: HoloToolWarning(code: "NO_STEPS_DATA", message: "没有可用的步数数据")
        case .sleep: HoloToolWarning(code: "NO_SLEEP_DATA", message: "没有可用的睡眠数据")
        case .stand: HoloToolWarning(code: "NO_STAND_DATA", message: "没有可用的站立数据")
        case .activity: HoloToolWarning(code: "NO_ACTIVITY_DATA", message: "没有可用的活动分钟数据")
        }
    }

    func empty(_ request: HoloToolRequest, warning: HoloToolWarning) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id,
            tool: request.tool,
            status: .empty,
            coverage: nil,
            metrics: [],
            events: [],
            warnings: [warning],
            error: nil,
            sensitivity: .sensitive
        )
    }

    func error(_ request: HoloToolRequest, reason: String) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id,
            tool: request.tool,
            status: .error,
            coverage: nil,
            metrics: [],
            events: [],
            warnings: [],
            error: HoloToolError(code: HoloToolErrorCode.invalidParams, message: reason, recoverable: true),
            sensitivity: .sensitive
        )
    }

    func metric(_ key: String, _ value: Double, unit: String) -> HoloMetric {
        HoloMetric(
            metricKey: key,
            value: Self.round(value),
            unit: unit,
            baselineValue: nil,
            comparison: nil
        )
    }

    static func round(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    static let idFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
}
