//
//  HoloProjectTool.swift
//  Holo
//
//  消费项目工具：读取用户的订阅 / 分期 / 周期性支出 / 一次性大件，
//  帮 agent 看到「项目维度」而非散交易，并理解一次性大件的真实摊销成本。
//
//  隐私边界：消费项目本身是用户主动录入的财务数据，标 normal（与 finance 工具一致）。
//  全部只读，不改 SpendingProject 实体或触发后台补账。
//

import Foundation

// MARK: - Value Types (tool-local)

/// 工具本地视图，避免 MO 跨 actor 传递。
/// 金额统一以 NSDecimalNumber → Double 折算，工具只做聚合展示。
struct HoloProjectToolRecord: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var kind: String                  // recurring / oneOff
    var amount: Double                // 原始金额（元）
    var frequency: String?            // monthly / yearly（仅 recurring）
    var startDate: Date
    var endDate: Date?
    var nextOccurrenceDate: Date?
    var isPaused: Bool
    var occurrencesGenerated: Int32
    var maxOccurrences: Int32
    var usageCount: Int32
    var monthlyCommitment: Double?    // 月均承诺（仅 recurring）
    var dailyCost: Double?            // 日均成本（仅 oneOff）
    var perUseCost: Double?           // 每次使用成本（仅 oneOff）
    var hasRemainingOccurrences: Bool
}

struct HoloProjectSnapshot: Codable, Equatable, Sendable {
    var projects: [HoloProjectToolRecord]
}

// MARK: - DataSource Protocol

protocol HoloProjectDataSource: Sendable {
    func snapshot() async -> HoloProjectSnapshot
}

// MARK: - Tool

struct HoloProjectTool: HoloDataTool {

    let descriptor = HoloToolDescriptor(
        name: "project",
        description: "消费项目分析（订阅与周期支出 / 即将到来的承诺 / 一次性大件摊销）",
        supportedQueries: ["recurring_summary", "upcoming_commitments", "oneoff_amortization"],
        supportedTimeRanges: ["recent", "30d", "90d"],
        outputMetrics: [
            "project.recurring.active_count",
            "project.recurring.monthly_commitment_total",
            "project.recurring.top_commitment",
            "project.upcoming.count",
            "project.oneoff.amortization_count",
            "project.oneoff.daily_cost",
            "project.oneoff.per_use_cost"
        ],
        sensitivityPolicy: "normal"
    )

    private let dataSource: HoloProjectDataSource

    init(dataSource: HoloProjectDataSource) {
        self.dataSource = dataSource
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        descriptor.supportedQueries.contains(request.query)
            ? .valid
            : .invalid(reason: "不支持的消费项目查询：\(request.query)")
    }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        let snapshot = await dataSource.snapshot()
        guard !snapshot.projects.isEmpty else {
            return empty(request: request, warnings: [
                HoloToolWarning(code: "NO_PROJECT_DATA", message: "没有可用的消费项目")
            ])
        }
        switch request.query {
        case "recurring_summary":
            return recurringSummary(request: request, snapshot: snapshot)
        case "upcoming_commitments":
            return upcomingCommitments(request: request, snapshot: snapshot)
        case "oneoff_amortization":
            return oneoffAmortization(request: request, snapshot: snapshot)
        default:
            return empty(request: request, warnings: [
                HoloToolWarning(code: "UNSUPPORTED_QUERY", message: "不支持的消费项目查询：\(request.query)")
            ])
        }
    }
}

// MARK: - Query Implementations

private extension HoloProjectTool {

    /// recurring_summary：活跃订阅 / 周期支出总览 + Top5 月均承诺。
    func recurringSummary(request: HoloToolRequest, snapshot: HoloProjectSnapshot) -> HoloDataToolResult {
        let recurring = snapshot.projects.filter { $0.kind == SpendingProjectKind.recurring.rawValue && !$0.isPaused && $0.hasRemainingOccurrences }
        guard !recurring.isEmpty else {
            return empty(request: request, warnings: [
                HoloToolWarning(code: "NO_RECURRING_PROJECT", message: "没有活跃的订阅或周期支出")
            ])
        }
        let monthlyTotal = recurring.compactMap { $0.monthlyCommitment }.reduce(0, +)
        let topByCommitment = recurring
            .filter { ($0.monthlyCommitment ?? 0) > 0 }
            .sorted { ($0.monthlyCommitment ?? 0) > ($1.monthlyCommitment ?? 0) }
            .prefix(5)

        let metrics: [HoloMetric] = [
            HoloMetric(metricKey: "project.recurring.active_count", value: Double(recurring.count), unit: "个", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "project.recurring.monthly_commitment_total", value: monthlyTotal, unit: "元/月", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "project.recurring.top_commitment", value: topByCommitment.first?.monthlyCommitment ?? 0, unit: "元/月", baselineValue: nil, comparison: topByCommitment.first?.name)
        ]

        let events: [HoloEvidenceEvent] = topByCommitment.enumerated().map { index, project in
            HoloEvidenceEvent(
                id: "\(request.id)-recurring-\(index)-\(project.id.uuidString.prefix(8))",
                occurredAt: project.nextOccurrenceDate,
                metricKey: "project.recurring.monthly_commitment_total",
                metricValue: project.monthlyCommitment,
                excerpt: "订阅「\(project.name)」\(Self.frequencyLabel(project.frequency))承诺 \(Self.moneyText(project.monthlyCommitment ?? 0)) 元/月"
            )
        }
        return success(request: request, metrics: metrics, events: events)
    }

    /// upcoming_commitments：按 nextOccurrenceDate 升序，列出即将到来的下一笔周期承诺。
    func upcomingCommitments(request: HoloToolRequest, snapshot: HoloProjectSnapshot) -> HoloDataToolResult {
        let now = Date()
        let upcoming = snapshot.projects
            .filter { $0.kind == SpendingProjectKind.recurring.rawValue && !$0.isPaused && $0.hasRemainingOccurrences }
            .compactMap { project -> (HoloProjectToolRecord, Date)? in
                guard let next = project.nextOccurrenceDate, next >= now else { return nil }
                return (project, next)
            }
            .sorted { $0.1 < $1.1 }
        guard !upcoming.isEmpty else {
            return empty(request: request, warnings: [
                HoloToolWarning(code: "NO_UPCOMING_PROJECT", message: "没有即将到来的周期承诺")
            ])
        }

        let metrics: [HoloMetric] = [
            HoloMetric(metricKey: "project.upcoming.count", value: Double(upcoming.count), unit: "笔", baselineValue: nil, comparison: nil)
        ]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let events: [HoloEvidenceEvent] = upcoming.prefix(6).enumerated().map { index, pair in
            let (project, next) = pair
            return HoloEvidenceEvent(
                id: "\(request.id)-upcoming-\(index)-\(project.id.uuidString.prefix(8))",
                occurredAt: next,
                metricKey: "project.upcoming.count",
                metricValue: project.amount,
                excerpt: "\(formatter.string(from: next)) 将发生「\(project.name)」\(Self.moneyText(project.amount)) 元"
            )
        }
        return success(request: request, metrics: metrics, events: events)
    }

    /// oneoff_amortization：一次性大件的摊销视角（日均成本 / 每次使用成本）。
    func oneoffAmortization(request: HoloToolRequest, snapshot: HoloProjectSnapshot) -> HoloDataToolResult {
        let oneOff = snapshot.projects.filter { $0.kind == SpendingProjectKind.oneOff.rawValue }
        guard !oneOff.isEmpty else {
            return empty(request: request, warnings: [
                HoloToolWarning(code: "NO_ONEOFF_PROJECT", message: "没有一次性大件消费项目")
            ])
        }
        // 按日均成本降序（日均越高 = 越没"回本"）
        let ranked = oneOff.sorted { ($0.dailyCost ?? 0) > ($1.dailyCost ?? 0) }
        let avgDaily = oneOff.compactMap { $0.dailyCost }.reduce(0, +) / Double(max(oneOff.count, 1))

        let metrics: [HoloMetric] = [
            HoloMetric(metricKey: "project.oneoff.amortization_count", value: Double(oneOff.count), unit: "个", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "project.oneoff.daily_cost", value: avgDaily, unit: "元/天", baselineValue: nil, comparison: "平均日均")
        ]

        let events: [HoloEvidenceEvent] = ranked.prefix(6).enumerated().map { index, project in
            var parts: [String] = ["大件「\(project.name)」购入 \(Self.moneyText(project.amount)) 元"]
            if let daily = project.dailyCost, daily > 0 {
                parts.append("日均 \(Self.moneyText(daily)) 元/天")
            }
            // usageCount 当前无 UI 写入入口（recordUsage 暂未接入），恒为 0；
            // 待「记录使用」接入后 perUseCost 才会有值，届时自动展示每次使用成本。
            if project.usageCount > 0, let perUse = project.perUseCost, perUse > 0 {
                parts.append("每次使用约 \(Self.moneyText(perUse)) 元（已用 \(project.usageCount) 次）")
            }
            return HoloEvidenceEvent(
                id: "\(request.id)-oneoff-\(index)-\(project.id.uuidString.prefix(8))",
                occurredAt: project.startDate,
                metricKey: "project.oneoff.daily_cost",
                metricValue: project.dailyCost,
                excerpt: parts.joined(separator: "，")
            )
        }
        return success(request: request, metrics: metrics, events: events)
    }

    // MARK: - Helpers

    func success(request: HoloToolRequest, metrics: [HoloMetric], events: [HoloEvidenceEvent]) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .success,
            coverage: nil, metrics: metrics, events: events, warnings: [], error: nil
        )
    }

    func empty(request: HoloToolRequest, warnings: [HoloToolWarning]) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .empty,
            coverage: nil, metrics: [], events: [], warnings: warnings, error: nil
        )
    }

    static func frequencyLabel(_ rawValue: String?) -> String {
        guard let rawValue, let parsed = SpendingProjectFrequency(rawValue: rawValue) else { return "" }
        return parsed.title
    }

    static func moneyText(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }
}
