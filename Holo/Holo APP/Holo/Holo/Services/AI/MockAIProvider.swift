//
//  MockAIProvider.swift
//  Holo
//
//  AI Provider Mock 实现
//  开发阶段调试 UI 和 IntentRouter，无需真实 API Key
//

import Foundation
import os.log

@MainActor
final class MockAIProvider: AIProvider {

    private let logger = Logger(subsystem: "com.holo.app", category: "MockAIProvider")

    // MARK: - AIProvider

    func parseUserInput(_ input: String, context: UserContext) async throws -> ParsedResult {
        // 模拟网络延迟
        try await Task.sleep(nanoseconds: 500_000_000)

        let lowercased = input.lowercased()

        // 简单关键词匹配模拟意图识别
        if lowercased.contains("花") || lowercased.contains("买") || lowercased.contains("吃饭") || lowercased.contains("午饭") || lowercased.contains("块") {
            let amount = extractAmount(from: input)
            return ParsedResult(
                intent: .recordExpense,
                confidence: 0.85,
                extractedData: [
                    "amount": amount,
                    "note": input,
                    "type": "expense"
                ],
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "已记录支出 ¥\(amount)"
            )
        }

        if lowercased.contains("收入") || lowercased.contains("工资") {
            let amount = extractAmount(from: input)
            return ParsedResult(
                intent: .recordIncome,
                confidence: 0.85,
                extractedData: [
                    "amount": amount,
                    "note": input,
                    "type": "income"
                ],
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "已记录收入 ¥\(amount)"
            )
        }

        if lowercased.contains("任务") || lowercased.contains("待办") || lowercased.contains("提醒我") {
            return ParsedResult(
                intent: .createTask,
                confidence: 0.8,
                extractedData: [
                    "title": input.replacingOccurrences(of: "帮我建个任务", with: "")
                        .replacingOccurrences(of: "提醒我", with: "")
                        .trimmingCharacters(in: .whitespaces)
                ],
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "已创建任务"
            )
        }

        if lowercased.contains("打卡") || lowercased.contains("完成习惯") {
            return ParsedResult(
                intent: .checkIn,
                confidence: 0.8,
                extractedData: [:],
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "已打卡"
            )
        }

        // 新增意图关键词匹配
        if lowercased.contains("完成") || lowercased.contains("做完了") {
            let keyword = input.replacingOccurrences(of: "完成", with: "")
                .replacingOccurrences(of: "了", with: "")
                .trimmingCharacters(in: .whitespaces)
            return ParsedResult(
                intent: .completeTask,
                confidence: 0.8,
                extractedData: ["taskKeyword": keyword.isEmpty ? input : keyword],
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "完成任务"
            )
        }

        if lowercased.contains("删除任务") || lowercased.contains("不要了") {
            let keyword = input.replacingOccurrences(of: "删除任务", with: "")
                .replacingOccurrences(of: "不要了", with: "")
                .trimmingCharacters(in: .whitespaces)
            return ParsedResult(
                intent: .deleteTask,
                confidence: 0.8,
                extractedData: ["taskKeyword": keyword.isEmpty ? input : keyword],
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "删除任务"
            )
        }

        if lowercased.contains("改成") || lowercased.contains("修改") {
            let keyword = input.replacingOccurrences(of: "把", with: "")
                .replacingOccurrences(of: "改成", with: " ")
                .replacingOccurrences(of: "修改", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return ParsedResult(
                intent: .updateTask,
                confidence: 0.8,
                extractedData: ["taskKeyword": keyword],
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "更新任务"
            )
        }

        if lowercased.contains("记一下") || lowercased.contains("笔记") {
            return ParsedResult(
                intent: .createNote,
                confidence: 0.8,
                extractedData: ["noteContent": input],
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "记录笔记"
            )
        }

        if lowercased.contains("有什么任务") || lowercased.contains("待办") || lowercased.contains("任务列表") {
            return ParsedResult(
                intent: .queryTasks,
                confidence: 0.85,
                extractedData: nil,
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "查询任务列表"
            )
        }

        if lowercased.contains("习惯状态") || lowercased.contains("打卡了吗") || lowercased.contains("习惯完成") {
            return ParsedResult(
                intent: .queryHabits,
                confidence: 0.85,
                extractedData: nil,
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "查询习惯状态"
            )
        }

        // 兜底：未识别意图
        return ParsedResult(
            intent: .unknown,
            confidence: 0.4,
            extractedData: nil,
            needsClarification: true,
            clarificationQuestion: "我可以帮你记账、创建任务、记录心情等，你想做什么？",
            responseText: "[Mock] 未识别指令：\(input)"
        )
    }

    func generateInsight(type: InsightType, data: UserContext) async throws -> String {
        try await Task.sleep(nanoseconds: 800_000_000)

        switch type {
        case .dailySummary:
            return """
            **今日总结（Mock）**

            今日支出：\(data.transactions.todayExpense)
            今日收入：\(data.transactions.todayIncome)
            习惯完成：\(data.habits.todayCompleted)/\(data.habits.todayTotal)
            任务完成：\(data.tasks.todayCompleted)/\(data.tasks.todayTotal)
            """
        default:
            return "[Mock] 这是\(type.rawValue)的模拟报告内容。"
        }
    }

    func generateMemoryInsight(type: InsightType, contextJSON: String) async throws -> String {
        try await Task.sleep(nanoseconds: 800_000_000)

        return """
        {
          "title": "你在把生活重新拉回节奏里",
          "summary": "习惯完成回暖，支出保持稳定，观点里反复提到建立仪式感和减少临时补救。",
          "cards": [
            {
              "id": "habit_1",
              "type": "habit",
              "title": "运动习惯在回暖",
              "body": "本周跑步记录连续 5 天，比上周多了 3 天。周末也没有中断。",
              "evidence": [
                {"id": "e1", "label": "跑步完成", "date": "2026-04-23", "sourceType": "habitRecord"},
                {"id": "e2", "label": "跑步完成", "date": "2026-04-24", "sourceType": "habitRecord"}
              ],
              "suggestedQuestion": "哪些习惯最容易中断？"
            },
            {
              "id": "finance_1",
              "type": "finance",
              "title": "支出没有明显失控",
              "body": "本周支出保持稳定，餐饮占比最高。",
              "evidence": [
                {"id": "e3", "label": "本周总支出 ¥420", "date": null, "sourceType": "transaction"}
              ],
              "suggestedQuestion": null
            },
            {
              "id": "thought_1",
              "type": "thought",
              "title": "在思考节奏和仪式感",
              "body": "本周观点中多次提到建立仪式感和减少临时补救。",
              "evidence": [
                {"id": "e4", "label": "观点：减少临时补救", "date": "2026-04-22", "sourceType": "thought"}
              ],
              "suggestedQuestion": "怎样把仪式感融入日常？"
            }
          ],
          "suggestedQuestions": [
            "为什么我周三支出比较多？",
            "下周应该优先保持哪个习惯？"
          ]
        }
        """
    }

    func chat(messages: [ChatMessageDTO], userContext: UserContext) async throws -> String {
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let lastMessage = messages.last?.content ?? ""
        return "[Mock] 收到你的消息：\(lastMessage)\n\n这是 Mock AI 的模拟回复。在设置中配置真实的 API Key 后，将接入大语言模型提供智能服务。"
    }

    func chatStreaming(messages: [ChatMessageDTO], userContext: UserContext) -> AsyncThrowingStream<String, Error> {
        let response = "[Mock] 这是流式回复的模拟内容。配置真实 API Key 后将接入大语言模型。"
        let chars = Array(response)

        return AsyncThrowingStream { continuation in
            Task {
                for char in chars {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continuation.yield(String(char))
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Batch Parsing

    /// 多动作 mock：按标点分句，每段独立解析
    /// 注意：这只是非常弱的分句能力，不代表正式拆分策略
    func parseUserInputBatch(_ input: String, context: UserContext) async throws -> AIParseBatch {
        let segments = input
            .split(whereSeparator: { "，,；;".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if segments.count <= 1 {
            let single = try await parseUserInput(input, context: context)
            return wrapSingleAsBatch(single)
        }

        var items: [AIParseItem] = []
        for segment in segments {
            let parsed = try await parseUserInput(segment, context: context)
            items.append(parsed.asParseItem)
        }

        let hasQuery = items.contains { $0.intent == .query || $0.intent == .queryTasks || $0.intent == .queryHabits }
        let hasAction = items.contains { $0.intent != .query && $0.intent != .queryTasks && $0.intent != .queryHabits && $0.intent != .unknown }

        if hasQuery && hasAction {
            return AIParseBatch(
                mode: .clarification,
                items: items,
                needsClarification: true,
                clarificationQuestion: "当前版本暂不支持把查询和执行操作混在一句话里，请拆成两句发送。"
            )
        }

        let mode: AIInteractionMode = hasQuery ? .query : .multiAction
        return AIParseBatch(mode: mode, items: items)
    }

    private func wrapSingleAsBatch(_ parsed: ParsedResult) -> AIParseBatch {
        let mode: AIInteractionMode
        switch parsed.intent {
        case .query, .queryTasks, .queryHabits:
            mode = .query
        case .unknown:
            mode = parsed.needsClarification ? .clarification : .unknown
        default:
            mode = .singleAction
        }

        return AIParseBatch(
            mode: mode,
            items: [parsed.asParseItem],
            needsClarification: parsed.needsClarification,
            clarificationQuestion: parsed.clarificationQuestion,
            fallbackResponseText: parsed.responseText
        )
    }

    // MARK: - Private Helpers

    private func extractAmount(from text: String) -> String {
        // 简单的金额提取
        let pattern = "[0-9]+\\.?[0-9]*"
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return "0"
        }
        return String(text[range])
    }
}
