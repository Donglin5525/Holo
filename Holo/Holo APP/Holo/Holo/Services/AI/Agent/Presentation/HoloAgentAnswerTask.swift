//
//  HoloAgentAnswerTask.swift
//  Holo
//
//  HoloAI Agent 统一结果语义契约 P2 — 通用答案任务（Answer Task）
//  从 Evidence 的类型化语义 + 用户问题确定性派生领域无关的答案任务，
//  不读 metricKey 字符串猜含义；同义问法收敛为同一任务。
//  P4 派生优先级修正：时间多点不再自动判趋势（固定健康工具汇总证据 = 单一聚合 + 每日点，
//  「平均/日均」问法应 lookup 聚合值），只有显式趋势意图词或 linearTrend/trend 语义才派生 trend；
//  排名意图的「最」排除「最近」等时间副词；lookup 主语义优先单一 current 聚合。
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
        // 显式趋势语义（linearTrend 操作 / trend 角色）→ trend，与问法无关
        if semantics.contains(where: { $0.operation == .linearTrend || $0.valueRole == .trend }) {
            return .trend
        }
        // 显式排名意图优先于时间序列启发（P3：「哪天/哪个最多」要排名，不是趋势）
        let allGrouped = semantics.filter { $0.dimension != nil }
        if asksRanking(question), Set(allGrouped.compactMap(\.groupLabel)).count >= 2 {
            return .ranking
        }
        let timeDimensions: Set<HoloMetricDimension> = [.day, .week, .month, .weekend]
        let timeLabels = Set(semantics.filter { $0.dimension.map(timeDimensions.contains) == true }
            .compactMap(\.groupLabel))
        if timeLabels.count >= 2 {
            // P4 修正：时间多点本身不再自动判趋势——固定健康工具的汇总证据同时携带
            // 单一 current 聚合（如 health.steps.average）与 day 维度每日点，
            // 「平均步数」类问题应回答聚合值（lookup），只有显式趋势意图才派生 trend。
            if asksTrend(question) { return .trend }
            return .lookup
        }
        // 业务维度多分组 → breakdown / ranking
        let grouped = semantics.filter { $0.dimension != nil }
        let distinctLabels = Set(grouped.compactMap(\.groupLabel))
        if !grouped.isEmpty, distinctLabels.count >= 2 {
            return asksRanking(question) ? .ranking : .breakdown
        }
        return .lookup
    }

    /// 排名意图词：最（排除「最近」等时间副词）/排名/第一/前几。
    private static func asksRanking(_ question: String) -> Bool {
        if ["排名", "第一", "前几"].contains(where: { question.contains($0) }) { return true }
        // 「最」只在修饰数量/程度时表排名（最多/最高/最快…），「最近/最终」不算。
        var rest = question[question.startIndex...]
        while let index = rest.firstIndex(of: "最") {
            let next = rest.index(after: index)
            guard next < rest.endIndex else { return true }
            if rest[next] != "近" { return true }
            rest = rest[next...]
        }
        return false
    }

    /// 趋势意图词：趋势/变化/走向/越来越（P4：时间多点只在显式意图下派生 trend）。
    private static func asksTrend(_ question: String) -> Bool {
        ["趋势", "变化", "走向", "越来越"].contains { question.contains($0) }
    }

    // MARK: 主语义

    /// comparison 时取 delta/changeRate 指标的语义（问变化率时优先 changeRate）；
    /// lookup 时优先单一 current 聚合（无维度），避免健康汇总证据取到每日点；否则第一个。
    private static func primarySemantic(
        semantics: [HoloMetricSemantic],
        mode: HoloAnswerMode,
        question: String
    ) -> HoloMetricSemantic? {
        if mode == .lookup,
           let aggregate = semantics.first(where: { $0.valueRole == .current && $0.dimension == nil }) {
            return aggregate
        }
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
