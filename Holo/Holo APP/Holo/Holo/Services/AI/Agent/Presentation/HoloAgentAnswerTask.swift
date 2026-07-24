//
//  HoloAgentAnswerTask.swift
//  Holo
//
//  HoloAI Agent 统一结果语义契约 P2 — 通用答案任务（Answer Task）
//  从 Evidence 的类型化语义 + 用户问题确定性派生领域无关的答案任务，
//  不读 metricKey 字符串猜含义；同义问法收敛为同一任务。
//

import Foundation

// MARK: - 灰度开关

/// P2 结果语义灰度开关，仿照 `HoloAgentDynamicQueryFlags` 的 UserDefaults 模式，默认开启。
nonisolated enum HoloAgentResultSemanticsFlags {
    private static let typedSemanticsKey = "holo_agent_typedResultSemanticsEnabled"
    private static let deterministicComposerKey = "holo_agent_deterministicAnswerComposerEnabled"

    /// 是否优先消费 evidence 上的类型化语义（P1）。
    static var typedSemanticsEnabled: Bool {
        get {
            if let stored = UserDefaults.standard.object(forKey: typedSemanticsKey) as? Bool { return stored }
            return true
        }
        set { UserDefaults.standard.set(newValue, forKey: typedSemanticsKey) }
    }

    /// 是否启用确定性答案合成器（P2）。关闭后 Renderer 完全走旧逻辑。
    static var deterministicComposerEnabled: Bool {
        get {
            if let stored = UserDefaults.standard.object(forKey: deterministicComposerKey) as? Bool { return stored }
            return true
        }
        set { UserDefaults.standard.set(newValue, forKey: deterministicComposerKey) }
    }
}

// MARK: - 答案模式

nonisolated enum HoloAnswerMode: String, Codable, CaseIterable, Sendable {
    case lookup
    case comparison
    case ranking
    case breakdown
    case trend
    case correlation
    case suggestion
}

// MARK: - 答案任务

/// 领域无关的答案任务：问法变化只影响派生，不影响后续计算与展示规则。
nonisolated struct HoloAnswerTask: Codable, Equatable, Sendable {
    var mode: HoloAnswerMode
    var domain: HoloEvidenceSourceModule?
    var measure: HoloMetricMeasure?
    var dimension: HoloMetricDimension?
    var direction: HoloMetricDirection?
    var primaryRangeLabel: String
    var baselineRangeLabel: String?
    var limit: Int = 3
}

// MARK: - 答案任务派生

/// 从 evidence 的 semantic + question 确定性派生 `HoloAnswerTask`。
/// 只读类型化语义与用户问题的显式意图词，不做 metricKey 字符串猜测。
nonisolated enum HoloAnswerTaskDeriver {

    /// 派生入口；evidence 全部无 semantic 时返回 nil，调用方走旧逻辑。
    static func derive(question: String?, evidence: [HoloEvidenceRecord]) -> HoloAnswerTask? {
        let semantics = evidence.compactMap(\.semantic)
        guard !semantics.isEmpty else { return nil }

        let text = question ?? ""
        let mode = resolveMode(semantics: semantics, question: text)
        let primary = primarySemantic(semantics: semantics, mode: mode, question: text)
        let direction = resolveDirection(question: text)

        let primaryRangeLabel = evidence
            .compactMap { $0.timeRange?.label.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "本期"
        let explicitBaseline = evidence
            .compactMap { $0.baselineTimeRange?.label.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let hasBaselineRange = evidence.contains { $0.baselineTimeRange != nil }
        let baselineRangeLabel: String?
        if let explicitBaseline {
            baselineRangeLabel = explicitBaseline
        } else if mode == .comparison || hasBaselineRange {
            baselineRangeLabel = "上期"
        } else {
            baselineRangeLabel = nil
        }

        return HoloAnswerTask(
            mode: mode,
            domain: primary?.domain,
            measure: primary?.measure,
            dimension: primary?.dimension,
            direction: direction,
            primaryRangeLabel: primaryRangeLabel,
            baselineRangeLabel: baselineRangeLabel,
            limit: 3
        )
    }

    // MARK: 模式判定

    private static func resolveMode(semantics: [HoloMetricSemantic], question: String) -> HoloAnswerMode {
        // 任一 delta / changeRate → comparison
        if semantics.contains(where: { $0.valueRole == .delta || $0.valueRole == .changeRate }) {
            return .comparison
        }
        // 跨域关联操作 → correlation
        if semantics.contains(where: {
            $0.operation == .correlation || $0.operation == .conditionalAverage || $0.operation == .groupComparison
        }) {
            return .correlation
        }
        // 显式趋势或时间维度多点 → trend
        if semantics.contains(where: { $0.operation == .linearTrend || $0.valueRole == .trend }) {
            return .trend
        }
        let timeDimensions: Set<HoloMetricDimension> = [.day, .week, .month, .weekend]
        let timeLabels = Set(semantics.filter { $0.dimension.map(timeDimensions.contains) == true }
            .compactMap(\.groupLabel))
        if timeLabels.count >= 2 { return .trend }
        // 业务维度多分组 → breakdown / ranking
        let grouped = semantics.filter { $0.dimension != nil }
        let distinctLabels = Set(grouped.compactMap(\.groupLabel))
        if !grouped.isEmpty, distinctLabels.count >= 2 {
            return asksRanking(question) ? .ranking : .breakdown
        }
        return .lookup
    }

    /// 排名意图词：最/排名/第一/前几/最高/最多。
    private static func asksRanking(_ question: String) -> Bool {
        ["最", "排名", "第一", "前几", "最高", "最多"].contains { question.contains($0) }
    }

    // MARK: 主语义

    /// comparison 时取 delta/changeRate 指标的语义（问变化率时优先 changeRate），否则第一个。
    private static func primarySemantic(
        semantics: [HoloMetricSemantic],
        mode: HoloAnswerMode,
        question: String
    ) -> HoloMetricSemantic? {
        guard mode == .comparison else { return semantics.first }
        let asksRate = ["涨幅", "降幅", "增长最快", "增长最慢", "变化率", "百分比"].contains { question.contains($0) }
        if asksRate, let rate = semantics.first(where: { $0.valueRole == .changeRate }) {
            return rate
        }
        return semantics.first(where: { $0.valueRole == .delta || $0.valueRole == .changeRate })
    }

    // MARK: 意图方向

    /// 从 question 显式解析用户意图方向（不是猜指标含义）；
    /// 先剥离「多少」避免把问数量的 lookup 误判为 increase。
    static func resolveDirection(question: String) -> HoloMetricDirection? {
        let text = question.replacingOccurrences(of: "多少", with: "")
        if ["多", "增加", "涨", "上升"].contains(where: { text.contains($0) }) { return .increase }
        if ["少", "减少", "降"].contains(where: { text.contains($0) }) { return .decrease }
        return nil
    }
}
