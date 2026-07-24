//
//  HoloDeterministicAnswerComposer.swift
//  Holo
//
//  HoloAI Agent 统一结果语义契约 P2 — 确定性答案合成器
//  按「答案模式 + 类型化证据」在本地合成标题、直接结论、明细与限制说明；
//  数字只消费 evidence.semantic，不信任模型文案；语义不足返回 nil，调用方走旧逻辑。
//

import Foundation

/// 合成器输出：全部为可直接展示的用户文案。
nonisolated struct HoloComposedAnswer: Equatable, Sendable {
    var headline: String
    var directAnswer: String
    var mainMetric: String?
    var items: [String]
    var coverageText: String?
    var limitations: [String]
}

nonisolated enum HoloDeterministicAnswerComposer {

    /// 合成入口；语义不足以支撑 task.mode 时返回 nil。
    static func compose(
        task: HoloAnswerTask,
        evidence: [HoloEvidenceRecord],
        coverage: HoloDataCoverage?
    ) -> HoloComposedAnswer? {
        // 跳过 NaN / 无穷，避免格式化出 "nan"/"inf"。
        let semantics = evidence.compactMap(\.semantic).filter { $0.resultValue.isFinite }
        guard !semantics.isEmpty else { return nil }

        let body: (headline: String, directAnswer: String, mainMetric: String?, items: [String])?
        switch task.mode {
        case .comparison:
            body = composeComparison(task: task, semantics: semantics)
        case .ranking, .breakdown:
            body = composeBreakdown(task: task, semantics: semantics, ranking: task.mode == .ranking)
        case .lookup:
            body = composeLookup(task: task, semantics: semantics)
        case .trend:
            body = composeTrend(task: task, semantics: semantics)
        case .correlation:
            body = composeCorrelation(task: task, semantics: semantics)
        case .suggestion:
            body = nil // suggestion 不由证据派生，保留给后续阶段
        }
        guard let body else { return nil }

        return HoloComposedAnswer(
            headline: body.headline,
            directAnswer: body.directAnswer,
            mainMetric: body.mainMetric,
            items: body.items,
            coverageText: coverageText(coverage, rangeLabel: task.primaryRangeLabel),
            limitations: limitations(coverage)
        )
    }

    // MARK: - comparison（含变化率排序变体）

    private static func composeComparison(
        task: HoloAnswerTask,
        semantics: [HoloMetricSemantic]
    ) -> (String, String, String?, [String])? {
        let deltas = semantics.filter { $0.valueRole == .delta }
        let changeRates = semantics.filter { $0.valueRole == .changeRate }
        guard !deltas.isEmpty || !changeRates.isEmpty else { return nil }

        let nounInfo = nounAndUnit(domain: task.domain, measure: deltas.first?.measure ?? task.measure)
        let baseline = task.baselineRangeLabel ?? "上期"
        let useRateRanking = task.measure == .ratio && !changeRates.isEmpty

        // 总增量：优先 groupLabel == nil（"all" 组）的 delta，否则各组 delta 之和；
        // 含内部 token 的分组不可展示，直接从总量与明细中排除。
        let groupDeltas = deltas.filter { $0.groupLabel != nil && sanitizedGroupLabel($0.groupLabel) != nil }
        let overallDelta = deltas.first { $0.groupLabel == nil }?.resultValue
            ?? groupDeltas.reduce(0) { $0 + $1.resultValue }
        let unit = deltas.first?.displayUnit ?? nounInfo.unit

        // 明细项：按方向过滤，|delta| 降序，并列按 groupLabel 字典序保证稳定。
        let items: [String]
        if useRateRanking {
            items = rankedRateItems(task: task, changeRates: changeRates, deltas: deltas, unit: unit)
        } else {
            items = rankedDeltaItems(task: task, deltas: groupDeltas, unit: unit)
        }

        var sentences: [String] = []
        let totalMeasure = deltas.first?.measure ?? task.measure
        let totalText = format(abs(overallDelta), unit: unit, measure: totalMeasure)
        if abs(overallDelta) < 1e-9 {
            var sentence = "\(task.primaryRangeLabel)\(nounInfo.noun)与\(baseline)基本持平"
            sentence += items.isEmpty ? "。" : "，分项变化主要来自\(joinItems(items))。"
            sentences = [sentence]
        } else {
            let totalVerb = overallDelta > 0 ? "增加" : "减少"
            var sentence = "\(task.primaryRangeLabel)\(nounInfo.noun)比\(baseline)\(totalVerb) \(withUnit(totalText, unit))"
            if items.isEmpty {
                if let wanted = task.direction {
                    sentence += "，没有发现\(wanted == .increase ? "增加项" : "减少项")"
                }
                sentence += "。"
            } else {
                sentence += "，主要来自\(joinItems(items))。"
            }
            sentences = [sentence]

            // 贡献占比：总量为 0 时不给占比；首项方向与总量一致才有意义。
            if overallDelta != 0, let top = topDeltaItem(task: task, deltas: groupDeltas),
               top.resultValue * overallDelta > 0,
               let label = sanitizedGroupLabel(top.groupLabel) {
                let percent = format(top.resultValue / overallDelta * 100, unit: "%", measure: .ratio)
                sentences.append("\(label)贡献了总\(overallDelta > 0 ? "增" : "减")量的 \(percent)%。")
            }

            // 抵消项：总量方向与某分组变化不一致时明确说明。
            if let offset = groupDeltas
                .filter({ $0.resultValue * overallDelta < 0 && sanitizedGroupLabel($0.groupLabel) != nil })
                .max(by: { abs($0.resultValue) < abs($1.resultValue) }),
               let label = sanitizedGroupLabel(offset.groupLabel) {
                let offsetVerb = offset.resultValue > 0 ? "增加" : "减少"
                let offsetText = format(abs(offset.resultValue), unit: unit, measure: offset.measure)
                sentences.append("其中\(label)\(offsetVerb) \(withUnit(offsetText, unit))，抵消了部分\(overallDelta > 0 ? "增" : "减")量。")
            }
        }

        let headline = task.dimension != nil
            ? "\(task.primaryRangeLabel)的\(nounInfo.noun)去向"
            : "\(task.primaryRangeLabel)的\(nounInfo.noun)变化"
        let mainMetric = abs(overallDelta) < 1e-9
            ? "基本持平"
            : "\(overallDelta > 0 ? "+" : "-")\(withUnit(totalText, unit))"
        return (headline, sentences.joined(), mainMetric, items)
    }

    /// delta 明细：direction 过滤 + |delta| 降序 + groupLabel 字典序稳定并列。
    private static func rankedDeltaItems(
        task: HoloAnswerTask,
        deltas: [HoloMetricSemantic],
        unit: String?
    ) -> [String] {
        let filtered = deltas.filter { delta in
            guard sanitizedGroupLabel(delta.groupLabel) != nil else { return false }
            switch task.direction {
            case .increase: return delta.resultValue > 1e-9
            case .decrease: return delta.resultValue < -1e-9
            case nil, .flat, .unknown: return abs(delta.resultValue) >= 1e-9
            }
        }
        let sorted = filtered.sorted { lhs, rhs in
            if abs(lhs.resultValue) != abs(rhs.resultValue) {
                return abs(lhs.resultValue) > abs(rhs.resultValue)
            }
            return (lhs.groupLabel ?? "") < (rhs.groupLabel ?? "")
        }
        return sorted.prefix(task.limit).compactMap { delta in
            guard let label = sanitizedGroupLabel(delta.groupLabel) else { return nil }
            let sign = delta.resultValue >= 0 ? "+" : "-"
            return "\(label)（\(sign)\(format(abs(delta.resultValue), unit: unit, measure: delta.measure)) \(unit ?? "")）"
        }
    }

    /// 变化率明细：按 |changeRate| 排序；基准为 0 的项不展示百分比，回退为绝对变化。
    private static func rankedRateItems(
        task: HoloAnswerTask,
        changeRates: [HoloMetricSemantic],
        deltas: [HoloMetricSemantic],
        unit: String?
    ) -> [String] {
        let filtered = changeRates.filter { rate in
            guard sanitizedGroupLabel(rate.groupLabel) != nil else { return false }
            switch task.direction {
            case .increase: return rate.resultValue > 1e-9
            case .decrease: return rate.resultValue < -1e-9
            case nil, .flat, .unknown: return abs(rate.resultValue) >= 1e-9
            }
        }
        let sorted = filtered.sorted { lhs, rhs in
            if abs(lhs.resultValue) != abs(rhs.resultValue) {
                return abs(lhs.resultValue) > abs(rhs.resultValue)
            }
            return (lhs.groupLabel ?? "") < (rhs.groupLabel ?? "")
        }
        return sorted.prefix(task.limit).compactMap { rate in
            guard let label = sanitizedGroupLabel(rate.groupLabel) else { return nil }
            if let baseline = rate.baselineValue, abs(baseline) < 1e-9 {
                // 基准为 0：百分比无意义，只展示绝对变化。
                guard let delta = deltas.first(where: { $0.groupLabel == rate.groupLabel }) else { return nil }
                let sign = delta.resultValue >= 0 ? "+" : "-"
                return "\(label)（\(sign)\(format(abs(delta.resultValue), unit: unit, measure: delta.measure)) \(unit ?? "")）"
            }
            let percent = abs(rate.resultValue) <= 1.000_001 ? rate.resultValue * 100 : rate.resultValue
            let sign = percent >= 0 ? "+" : "-"
            return "\(label)（\(sign)\(format(abs(percent), unit: "%", measure: .ratio))%）"
        }
    }

    private static func topDeltaItem(task: HoloAnswerTask, deltas: [HoloMetricSemantic]) -> HoloMetricSemantic? {
        rankedCandidates(task: task, deltas: deltas).first
    }

    private static func rankedCandidates(task: HoloAnswerTask, deltas: [HoloMetricSemantic]) -> [HoloMetricSemantic] {
        deltas
            .filter { sanitizedGroupLabel($0.groupLabel) != nil && abs($0.resultValue) >= 1e-9 }
            .sorted {
                if abs($0.resultValue) != abs($1.resultValue) {
                    return abs($0.resultValue) > abs($1.resultValue)
                }
                return ($0.groupLabel ?? "") < ($1.groupLabel ?? "")
            }
    }

    // MARK: - breakdown / ranking

    private static func composeBreakdown(
        task: HoloAnswerTask,
        semantics: [HoloMetricSemantic],
        ranking: Bool
    ) -> (String, String, String?, [String])? {
        let currents = semantics.filter {
            $0.valueRole == .current && $0.dimension != nil && sanitizedGroupLabel($0.groupLabel) != nil
        }
        guard currents.count >= 2 else { return nil }
        let nounInfo = nounAndUnit(domain: task.domain, measure: task.measure)
        let unit = currents.first?.displayUnit ?? nounInfo.unit
        let sorted = currents.sorted {
            if $0.resultValue != $1.resultValue { return $0.resultValue > $1.resultValue }
            return ($0.groupLabel ?? "") < ($1.groupLabel ?? "")
        }
        let items = sorted.prefix(task.limit).compactMap { semantic -> String? in
            guard let label = sanitizedGroupLabel(semantic.groupLabel) else { return nil }
            return "\(label)（\(format(semantic.resultValue, unit: unit, measure: semantic.measure)) \(unit ?? "")）"
        }
        guard !items.isEmpty else { return nil }

        let total = semantics.first { $0.valueRole == .current && $0.groupLabel == nil }?.resultValue
            ?? currents.reduce(0) { $0 + $1.resultValue }
        let totalText = format(total, unit: unit, measure: task.measure)
        let directAnswer: String
        if ranking {
            directAnswer = "\(task.primaryRangeLabel)\(nounInfo.noun)最高的是\(joinItems(items))。"
        } else {
            directAnswer = "\(task.primaryRangeLabel)\(nounInfo.noun)共 \(withUnit(totalText, unit))，主要来自\(joinItems(items))。"
        }
        return ("\(task.primaryRangeLabel)的\(nounInfo.noun)去向", directAnswer, withUnit(totalText, unit), items)
    }

    // MARK: - lookup

    private static func composeLookup(
        task: HoloAnswerTask,
        semantics: [HoloMetricSemantic]
    ) -> (String, String, String?, [String])? {
        guard let primary = semantics.first(where: { $0.valueRole == .current }) ?? semantics.first else {
            return nil
        }
        let nounInfo = nounAndUnit(domain: task.domain ?? primary.domain, measure: task.measure ?? primary.measure)
        let unit = primary.displayUnit ?? nounInfo.unit
        let valueText = format(primary.resultValue, unit: unit, measure: primary.measure)
        let directAnswer = "\(task.primaryRangeLabel)，\(nounInfo.noun) \(withUnit(valueText, unit))"
        return ("\(task.primaryRangeLabel)的\(nounInfo.noun)", directAnswer, withUnit(valueText, unit), [])
    }

    // MARK: - trend

    private static func composeTrend(
        task: HoloAnswerTask,
        semantics: [HoloMetricSemantic]
    ) -> (String, String, String?, [String])? {
        let nounInfo = nounAndUnit(domain: task.domain, measure: task.measure)
        // 斜率：优先显式 trend 语义，否则用时间维度首尾点估算。
        let explicit = semantics.first { $0.valueRole == .trend || $0.operation == .linearTrend }
        let slope: Double
        let unit: String?
        if let explicit {
            slope = explicit.resultValue
            unit = explicit.displayUnit ?? nounInfo.unit
        } else {
            let points = semantics
                .filter { $0.groupLabel != nil }
                .sorted { ($0.groupLabel ?? "") < ($1.groupLabel ?? "") }
            guard points.count >= 2, let first = points.first, let last = points.last else { return nil }
            slope = (last.resultValue - first.resultValue) / Double(points.count - 1)
            unit = first.displayUnit ?? nounInfo.unit
        }
        let intervalUnit: String
        switch task.dimension {
        case .day, .weekend: intervalUnit = "天"
        case .week: intervalUnit = "周"
        case .month: intervalUnit = "月"
        default: intervalUnit = "天"
        }
        let directAnswer: String
        if abs(slope) < 1e-9 {
            directAnswer = "\(task.primaryRangeLabel)，\(nounInfo.noun)整体基本持平。"
        } else {
            let word = slope > 0 ? "上升" : "下降"
            let magnitude = format(abs(slope), unit: unit, measure: task.measure)
            directAnswer = "\(task.primaryRangeLabel)，\(nounInfo.noun)呈\(word)趋势，平均每\(intervalUnit)变化约 \(withUnit(magnitude, unit))。"
        }
        return ("\(task.primaryRangeLabel)的\(nounInfo.noun)趋势", directAnswer, nil, [])
    }

    // MARK: - correlation

    private static func composeCorrelation(
        task: HoloAnswerTask,
        semantics: [HoloMetricSemantic]
    ) -> (String, String, String?, [String])? {
        guard let primary = semantics.first(where: {
            $0.operation == .correlation || $0.operation == .conditionalAverage || $0.operation == .groupComparison
        }) else { return nil }
        let coefficient = primary.resultValue
        let strength = abs(coefficient) >= 0.7 ? "较强" : (abs(coefficient) >= 0.4 ? "中等" : "较弱")
        let valueText = String(format: "%.2f", coefficient)
        let directAnswer = "\(task.primaryRangeLabel)，两项数据的相关系数为 \(valueText)，相关性\(strength)，仅表示关联，不表示因果。"
        return ("\(task.primaryRangeLabel)的关联分析", directAnswer, valueText, [])
    }

    // MARK: - 覆盖度

    private static func coverageText(_ coverage: HoloDataCoverage?, rangeLabel: String) -> String? {
        guard let coverage else { return nil }
        return "\(rangeLabel)共 \(coverage.totalDays) 天，其中 \(coverage.coveredDays)/\(coverage.totalDays) 天有有效记录"
    }

    private static func limitations(_ coverage: HoloDataCoverage?) -> [String] {
        guard let coverage else { return [] }
        let ratio = coverage.coverageRatio
            ?? (coverage.totalDays > 0 ? Double(coverage.coveredDays) / Double(coverage.totalDays) : 1)
        return ratio < 0.6 ? ["数据覆盖不足，结论仅供参考"] : []
    }

    // MARK: - 名词与单位表

    /// 名词与单位由 (domain, measure) 确定性决定，禁止从 metricKey 推；未知组合用通用措辞。
    static func nounAndUnit(
        domain: HoloEvidenceSourceModule?,
        measure: HoloMetricMeasure?
    ) -> (noun: String, unit: String?) {
        switch (domain, measure) {
        case (.finance, .amount): return ("支出", "元")
        case (.finance, .count): return ("消费次数", "次")
        case (.habit, .count): return ("完成次数", "次")
        case (.task, .count): return ("任务", "个")
        case (.health, .durationHours): return ("时长", "小时")
        case (.health, .durationMinutes): return ("时长", "分钟")
        case (_, .steps): return ("步数", "步")
        case (_, .amount): return ("金额", "元")
        case (_, .count): return ("数量", "个")
        case (_, .durationHours): return ("时长", "小时")
        case (_, .durationMinutes): return ("时长", "分钟")
        case (_, .ratio): return ("占比", "%")
        case (_, .days): return ("天数", "天")
        case (_, .nights): return ("天数", "晚")
        default: return ("该指标", nil)
        }
    }

    // MARK: - 展示工具

    /// groupLabel 只作转义展示文本：过滤控制字符；含内部 token 的分组跳过（返回 nil）。
    static func sanitizedGroupLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !HoloMetricSemanticCatalog.containsInternalToken(trimmed) else { return nil }
        let scalars = trimmed.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars))
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 数字格式化复用 `HoloMetricSemanticCatalog.formattedNumber`；调用前须保证 value 有限。
    static func format(_ value: Double, unit: String?, measure: HoloMetricMeasure?) -> String {
        guard value.isFinite else { return "0" }
        let key = measure == .amount ? "amount" : ""
        return HoloMetricSemanticCatalog.formattedNumber(value, metricKey: key, unit: unit)
    }

    /// 数值与单位之间统一空一格（「1,248 元」）；无单位原样返回。
    static func withUnit(_ valueText: String, _ unit: String?) -> String {
        guard let unit, !unit.isEmpty else { return valueText }
        return "\(valueText) \(unit)"
    }

    /// 「A、B 和 C」式并列连接。
    static func joinItems(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        if items.count == 1 { return last }
        return items.dropLast().joined(separator: "、") + "和" + last
    }
}
