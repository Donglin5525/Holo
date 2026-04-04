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

        // 默认为普通聊天
        return ParsedResult(
            intent: .chat,
            confidence: 0.6,
            extractedData: nil,
            needsClarification: false,
            clarificationQuestion: nil,
            responseText: "[Mock] 收到你的消息：\(input)"
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
