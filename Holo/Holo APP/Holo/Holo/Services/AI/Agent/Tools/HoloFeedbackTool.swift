//
//  HoloFeedbackTool.swift
//  Holo
//
//  洞察反馈闭环工具：读取用户对历史洞察的评分与纠正，帮 agent 知道
//  「哪些类型的观察用户觉得不准 / 没价值」，避免重蹈覆辙。
//
//  隐私边界：
//  - 只读，绝不调用 markConsumed（那是 InsightFeedbackAggregator 的职责）
//  - 评分与原因枚举可完整暴露（结构性信号）
//  - 自由文本纠正（userCorrection）仅在 corrections_summary 里以 ≤60 字脱敏摘录出现，
//    且不进入 dynamic_query 动态数据集，控制敏感内容扩散面
//

import Foundation

// MARK: - Value Types (tool-local)

struct HoloFeedbackRecord: Codable, Equatable, Sendable {
    var id: UUID
    var insightId: UUID
    var accuracyRating: String?      // accurate / inaccurate
    var valueRating: String?         // useful / notUseful / notMeaningful
    var reasonType: String?          // FeedbackReasonType rawValue
    var module: String?
    var patternType: String?
    var userCorrection: String?
    var createdAt: Date
}

// MARK: - DataSource Protocol

protocol HoloFeedbackDataSource: Sendable {
    /// 读取最近 N 条反馈（按 createdAt 降序）。limit 上限由 DataSource 内部钳制。
    func recentFeedback(limit: Int) async -> [HoloFeedbackRecord]
}

// MARK: - Tool

struct HoloFeedbackTool: HoloDataTool {

    let descriptor = HoloToolDescriptor(
        name: "feedback",
        description: "用户对历史洞察的评分与纠正反馈（评分分布 / 纠正主题聚类 / 近期纠正脱敏摘要）",
        supportedQueries: ["rating_summary", "correction_themes", "corrections_summary"],
        supportedTimeRanges: ["recent", "30d", "90d"],
        outputMetrics: [
            "feedback.total.count",
            "feedback.accuracy.accurate_count",
            "feedback.accuracy.inaccurate_count",
            "feedback.value.useful_count",
            "feedback.value.not_useful_count",
            "feedback.correction.count",
            "feedback.theme.count"
        ],
        sensitivityPolicy: "sensitive"
    )

    /// 自由文本纠正在 evidence excerpt 中的最大字符数。
    static let correctionExcerptLimit = 60

    private let dataSource: HoloFeedbackDataSource

    init(dataSource: HoloFeedbackDataSource) {
        self.dataSource = dataSource
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        descriptor.supportedQueries.contains(request.query)
            ? .valid
            : .invalid(reason: "不支持的反馈查询：\(request.query)")
    }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        // 按查询语义决定拉取窗口：rating_summary / correction_themes 看全量近期，
        // corrections_summary 只展示最近若干条脱敏摘要。
        let limit: Int
        switch request.query {
        case "corrections_summary": limit = 10
        case "correction_themes": limit = 50
        default: limit = 50
        }
        let records = await dataSource.recentFeedback(limit: limit).sorted { $0.createdAt > $1.createdAt }
        guard !records.isEmpty else {
            return empty(request: request, warnings: [
                HoloToolWarning(code: "NO_FEEDBACK_DATA", message: "没有可用的洞察反馈")
            ])
        }
        switch request.query {
        case "rating_summary":
            return ratingSummary(request: request, records: records)
        case "correction_themes":
            return correctionThemes(request: request, records: records)
        case "corrections_summary":
            return correctionsSummary(request: request, records: records)
        default:
            return empty(request: request, warnings: [
                HoloToolWarning(code: "UNSUPPORTED_QUERY", message: "不支持的反馈查询：\(request.query)")
            ])
        }
    }
}

// MARK: - Query Implementations

private extension HoloFeedbackTool {

    /// rating_summary：整体评分分布，帮 agent 判断「用户对历史洞察整体满意吗」。
    func ratingSummary(request: HoloToolRequest, records: [HoloFeedbackRecord]) -> HoloDataToolResult {
        let total = records.count
        let accurate = records.filter { $0.accuracyRating == AccuracyRating.accurate.rawValue }.count
        let inaccurate = records.filter { $0.accuracyRating == AccuracyRating.inaccurate.rawValue }.count
        let useful = records.filter { $0.valueRating == ValueRating.useful.rawValue }.count
        let notUseful = records.filter {
            $0.valueRating == ValueRating.notUseful.rawValue || $0.valueRating == ValueRating.notMeaningful.rawValue
        }.count

        var metrics: [HoloMetric] = [
            HoloMetric(metricKey: "feedback.total.count", value: Double(total), unit: "条", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "feedback.accuracy.accurate_count", value: Double(accurate), unit: "条", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "feedback.accuracy.inaccurate_count", value: Double(inaccurate), unit: "条", baselineValue: nil, comparison: nil)
        ]
        if useful > 0 || notUseful > 0 {
            metrics.append(HoloMetric(metricKey: "feedback.value.useful_count", value: Double(useful), unit: "条", baselineValue: nil, comparison: nil))
            metrics.append(HoloMetric(metricKey: "feedback.value.not_useful_count", value: Double(notUseful), unit: "条", baselineValue: nil, comparison: nil))
        }

        let accuracyRatio = total > 0 ? Double(accurate) / Double(total) : 0
        let valueRatio = (useful + notUseful) > 0 ? Double(useful) / Double(useful + notUseful) : nil
        var parts: [String] = ["最近 \(total) 条反馈"]
        parts.append("准确率 \(Self.percentText(accuracyRatio))")
        if let valueRatio {
            parts.append("有价值占比 \(Self.percentText(valueRatio))")
        }
        let events = [HoloEvidenceEvent(
            id: "\(request.id)-rating-overview",
            occurredAt: records.first?.createdAt,
            metricKey: "feedback.total.count",
            metricValue: Double(total),
            excerpt: parts.joined(separator: "，")
        )]
        return success(request: request, metrics: metrics, events: events)
    }

    /// correction_themes：用户纠正过的主题聚类，按 module / patternType 聚合，
    /// 只统计 reason 枚举与出现次数，不含纠正文本。
    func correctionThemes(request: HoloToolRequest, records: [HoloFeedbackRecord]) -> HoloDataToolResult {
        let corrected = records.filter { $0.reasonType != nil || ($0.userCorrection?.isEmpty == false) }
        guard !corrected.isEmpty else {
            return empty(request: request, warnings: [
                HoloToolWarning(code: "NO_CORRECTION_DATA", message: "没有用户纠正过的反馈")
            ])
        }

        // reason 维度
        let reasonCounts = Dictionary(grouping: corrected, by: { $0.reasonType ?? "unspecified" })
            .mapValues { $0.count }
            .sorted { $0.value > $1.value }

        // module 维度
        let moduleCounts = Dictionary(grouping: corrected, by: { $0.module?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未分类" })
            .mapValues { $0.count }
            .sorted { $0.value > $1.value }
            .prefix(5)

        let metrics: [HoloMetric] = [
            HoloMetric(metricKey: "feedback.correction.count", value: Double(corrected.count), unit: "条", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "feedback.theme.count", value: Double(reasonCounts.count), unit: "类", baselineValue: nil, comparison: nil)
        ]

        var events: [HoloEvidenceEvent] = reasonCounts.prefix(6).map { (reason, count) in
            HoloEvidenceEvent(
                id: "\(request.id)-theme-reason-\(reason)",
                occurredAt: nil,
                metricKey: "feedback.correction.count",
                metricValue: Double(count),
                excerpt: "纠正原因「\(Self.reasonLabel(reason))」\(count) 次"
            )
        }
        events += moduleCounts.map { (module, count) in
            HoloEvidenceEvent(
                id: "\(request.id)-theme-module-\(module)",
                occurredAt: nil,
                metricKey: "feedback.correction.count",
                metricValue: Double(count),
                excerpt: "领域「\(module)」被纠正 \(count) 次"
            )
        }
        return success(request: request, metrics: metrics, events: events)
    }

    /// corrections_summary：最近若干条纠正的脱敏摘要（自由文本 ≤60 字截断）。
    func correctionsSummary(request: HoloToolRequest, records: [HoloFeedbackRecord]) -> HoloDataToolResult {
        let corrected = records.filter { $0.userCorrection?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        guard !corrected.isEmpty else {
            return empty(request: request, warnings: [
                HoloToolWarning(code: "NO_CORRECTION_TEXT", message: "没有带文本纠正的反馈")
            ])
        }
        let metrics: [HoloMetric] = [
            HoloMetric(metricKey: "feedback.correction.count", value: Double(corrected.count), unit: "条", baselineValue: nil, comparison: nil)
        ]
        let events = corrected.prefix(6).enumerated().map { index, item in
            let raw = (item.userCorrection ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let truncated = Self.truncate(raw, limit: Self.correctionExcerptLimit)
            let reason = item.reasonType.map { "（\(Self.reasonLabel($0))）" } ?? ""
            return HoloEvidenceEvent(
                id: "\(request.id)-correction-\(index)-\(item.id.uuidString.prefix(8))",
                occurredAt: item.createdAt,
                metricKey: "feedback.correction.count",
                metricValue: 1,
                excerpt: "用户纠正\(reason)：\(truncated)"
            )
        }
        return HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .success,
            coverage: nil, metrics: metrics, events: events, warnings: [], error: nil,
            sensitivity: .sensitive
        )
    }

    // MARK: - Helpers

    func success(request: HoloToolRequest, metrics: [HoloMetric], events: [HoloEvidenceEvent]) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .success,
            coverage: nil, metrics: metrics, events: events, warnings: [], error: nil,
            sensitivity: .sensitive
        )
    }

    func empty(request: HoloToolRequest, warnings: [HoloToolWarning]) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .empty,
            coverage: nil, metrics: [], events: [], warnings: warnings, error: nil,
            sensitivity: .sensitive
        )
    }

    static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    static func percentText(_ ratio: Double) -> String {
        String(format: "%.0f%%", ratio * 100)
    }

    /// reason rawValue → 中文标签，未知值原样回退。
    static func reasonLabel(_ rawValue: String) -> String {
        if let parsed = FeedbackReasonType(rawValue: rawValue) {
            return parsed.displayName
        }
        return rawValue
    }
}
