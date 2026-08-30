//
//  LifePlanGenerationService.swift
//  Holo
//
//  每周生活计划生成服务：Agent 深度分析完成后，将分析结论 + 上一份计划台账
//  组装为结构化 LifePlan。schema 校验失败重试一次，再失败降级为普通分析（不阻塞）。
//

import Foundation
import CoreData

@MainActor
final class LifePlanGenerationService {

    static let shared = LifePlanGenerationService()
    private init() {}

    enum GenerationOutcome {
        case saved(LifePlanSnapshot)
        case dataInsufficient(missingDomains: [String])
        case degraded(reason: String)
        /// 计划生成额度（lifePlan 池）耗尽：档位终态而非故障，上层据此给出
        /// 准确文案（不引导重试——重试需先重烧深度分析额度，且重置前必失败）。
        case quotaExhausted(userMessage: String)
    }

    // MARK: - 数据充分度（近 7 天 ≥2 域有有效记录；不满足时不伪装理解）

    nonisolated static func checkDataSufficiency(now: Date = Date()) -> (sufficient: Bool, missing: [String]) {
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600) as NSDate
        let context = CoreDataStack.shared.viewContext

        func count(_ entity: String, _ predicate: NSPredicate) -> Int {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
            request.predicate = predicate
            return (try? context.count(for: request)) ?? 0
        }

        let domains: [(name: String, count: Int)] = [
            ("任务", count("TodoTask", NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "completedAt > %@", weekAgo),
                NSPredicate(format: "deletedAt == nil")
            ]))),
            ("习惯打卡", count("HabitRecord", NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "date > %@", weekAgo),
                NSPredicate(format: "deletedAt == nil")
            ]))),
            ("记账", count("Transaction", NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "date > %@", weekAgo),
                NSPredicate(format: "deletedAt == nil")
            ]))),
            ("想法", count("Thought", NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "createdAt > %@", weekAgo),
                NSPredicate(format: "deletedAt == nil")
            ])))
        ]
        let activeDomains = domains.filter { $0.count > 0 }
        let missing = domains.filter { $0.count == 0 }.map(\.name)
        return (activeDomains.count >= 2, missing)
    }

    // MARK: - 生成主流程

    func generatePlan(
        agentResult: HoloRenderedAgentResult,
        jobID: String,
        budget: PlanConsumedBudget?,
        provider: AIProvider,
        userContext: UserContext,
        now: Date = Date()
    ) async -> GenerationOutcome {
        let scheduleOverview = await weeklyScheduleOverview(now: now)
        let prompt = buildPrompt(agentResult: agentResult, now: now, scheduleOverview: scheduleOverview)

        // LLM 结构化输出，失败重试一次
        var payload: LifePlanGenerationPayload?
        var lastError: String = "未知错误"
        for _ in 0..<2 {
            do {
                let raw = try await provider.completeWeeklyPlan(prompt: prompt, context: userContext)
                if let decoded = Self.decodePayload(from: raw), decoded.isValid {
                    payload = decoded
                    break
                }
                lastError = "输出未通过 schema 校验"
            } catch let error as HoloQuotaError {
                // 额度耗尽：不重试（必再失败）、不降级成通用「稍后再试」文案。
                LifePlanRepository.shared.recordDegradedRun(jobID: jobID, budget: budget, now: now)
                return .quotaExhausted(userMessage: error.userMessage)
            } catch {
                lastError = error.localizedDescription
            }
        }

        guard let payload else {
            LifePlanRepository.shared.recordDegradedRun(jobID: jobID, budget: budget, now: now)
            return .degraded(reason: lastError)
        }

        do {
            let evidenceSummaries = agentResult.evidenceReferences.map { (id: $0.id, summary: $0.summary) }
            let snapshot = try LifePlanRepository.shared.saveGeneratedPlan(
                payload: payload,
                jobID: jobID,
                budget: budget,
                evidenceSummaries: evidenceSummaries,
                now: now
            )
            return .saved(snapshot)
        } catch {
            LifePlanRepository.shared.recordDegradedRun(jobID: jobID, budget: budget, now: now)
            return .degraded(reason: "计划落库失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Prompt 组装

    private func buildPrompt(agentResult: HoloRenderedAgentResult, now: Date, scheduleOverview: String?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var prompt = """
        今天是 \(formatter.string(from: now))。

        【本周分析结论】
        标题：\(agentResult.title)
        摘要：\(agentResult.summary)
        """

        for section in agentResult.sections.prefix(8) {
            prompt += "\n- \(section.title)：\(section.body)"
        }
        if let recommendations = agentResult.recommendations, !recommendations.isEmpty {
            prompt += "\n分析给出的建议（供参考，重点须重新取舍）："
            for recommendation in recommendations.prefix(5) {
                prompt += "\n· \(recommendation.title)"
            }
        }

        if let previous = LifePlanRepository.shared.previousPlanContext(now: now) {
            if let data = try? JSONEncoder().encode(previous),
               let json = String(data: data, encoding: .utf8) {
                prompt += "\n\n【上一份计划台账】（\(formatter.string(from: previous.periodStart)) ~ \(formatter.string(from: previous.periodEnd))，taskCompleted 为真实完成状态）\n\(json)"
            }
        }

        // 系统日历日程概览（未开启/无日程时整节省略，模型按「可能有」处理）
        if let scheduleOverview {
            prompt += "\n\n【本周日程概览】\n\(scheduleOverview)"
        }

        prompt += "\n\n请根据以上信息生成本周计划。"
        return prompt
    }

    /// 本周日程密度概览：按天汇总定时日程数量与时段（周规划避让的输入）
    private func weeklyScheduleOverview(now: Date) async -> String? {
        let store = ScheduleStore.shared
        guard store.isAvailableForAgent else { return nil }

        let calendar = Calendar.current
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = Locale(identifier: "zh_CN")
        weekdayFormatter.dateFormat = "E"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        var lines: [String] = []
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }
            let items = await store.fetchSchedules(onDay: day).filter { !$0.isAllDay }
            guard !items.isEmpty else { continue }
            let first = timeFormatter.string(from: items[0].startDate)
            let last = timeFormatter.string(from: items[items.count - 1].endDate)
            let density = items.count >= 4 ? "（密集日）" : ""
            lines.append("\(weekdayFormatter.string(from: day)) \(items.count) 场（\(first)–\(last)）\(density)")
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "；")
    }

    /// 剥离可能的 markdown fence 后解码
    nonisolated static func decodePayload(from raw: String) -> LifePlanGenerationPayload? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fenceEnd = text.range(of: "```", options: .backwards) {
                text = String(text[..<fenceEnd.lowerBound])
            }
        }
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LifePlanGenerationPayload.self, from: data)
    }
}
