//
//  HoloAgentModelTimeRangePolicy.swift
//  Holo
//
//  Agent 时间语义改造 L3 — LLM 填写查询窗口的确定性护栏。
//
//  L1 词表与 L2 通用规则未命中的时间表达（「春天那会儿」「上上个月」）交给 LLM 解析，
//  LLM 在 toolRequest.timeRange 里给出窗口；本护栏决定该窗口能否被提升为 job 权威范围。
//  防幻觉不靠「不让模型碰时间」，靠「填了就必须过护栏 + 过了就向用户晒出来」。
//

import Foundation

nonisolated enum HoloAgentModelTimeRangePolicy {

    /// 模型可申报窗口的跨度上限（天）。更长的历史窗口对个人数据复盘没有意义，
    /// 且与各数据集 maximumRangeDays（366）形成双保险。
    static let maximumSpanDays: Int = 731

    /// 模型窗口最早可回溯的年份下限（相对今天）。
    static let maximumLookbackYears: Int = 5

    static func validate(
        _ range: HoloAgentTimeRange,
        asOf: Date = Date(),
        calendar inputCalendar: Calendar = .current
    ) -> Bool {
        guard let start = range.start, let end = range.end else { return false }
        guard start < end else { return false }

        var calendar = inputCalendar
        calendar.locale = Locale(identifier: "zh_CN")
        let today = calendar.startOfDay(for: asOf)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? asOf

        // 结束不得越过明天 0 点（允许「截至今天」的窗口）
        guard end <= tomorrow else { return false }

        // 跨度上限
        let spanDays = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? .max
        guard spanDays <= maximumSpanDays else { return false }

        // 回溯下限
        guard let earliest = calendar.date(byAdding: .year, value: -maximumLookbackYears, to: today) else { return false }
        guard start >= earliest else { return false }

        // label 必须非空：卡片披露要展示它，空 label 说明模型没按协议填依据
        let trimmed = range.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        return true
    }

    /// 从 LLM 输出的 toolRequests 中选出候选窗口：取第一个携带合法 timeRange 的请求。
    /// （多工具请求应使用同一窗口；若模型给了互相冲突的窗口，第一个过护栏的胜出，
    /// 其余差异在 requestWithJobScope 的权威覆盖下被统一。）
    static func firstValidRange(
        in requests: [HoloToolRequest],
        asOf: Date = Date(),
        calendar: Calendar = .current
    ) -> HoloAgentTimeRange? {
        for request in requests {
            let candidates: [HoloAgentTimeRange?] = [request.timeRange, request.dynamicPlan?.timeRange]
            for candidate in candidates {
                guard let candidate else { continue }
                if validate(candidate, asOf: asOf, calendar: calendar) {
                    return candidate
                }
            }
        }
        return nil
    }
}
