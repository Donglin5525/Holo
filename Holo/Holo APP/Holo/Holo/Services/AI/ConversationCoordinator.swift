//
//  ConversationCoordinator.swift
//  Holo
//
//  AI Chat 的轻量编排层
//  负责 batch 解析、顺序执行和结果聚合
//

import Foundation
import os.log

/// Coordinator 处理结果
struct ConversationProcessResult {
    let finalText: String
    let parsedBatch: AIParseBatch?
    let executionBatch: AIExecutionBatch?
    /// 仅用于兼容旧字段写入，多动作消息的真实渲染优先读取 executionBatch
    let firstIntent: AIIntent?
    let firstExtractedData: [String: String]?
    let shouldStreamChat: Bool
    let analysisContext: AnalysisContext?
}

@MainActor
final class ConversationCoordinator {

    private let logger = Logger(subsystem: "com.holo.app", category: "ConversationCoordinator")
    private let intentRouter: IntentRouting

    init(intentRouter: IntentRouting = IntentRouter.shared) {
        self.intentRouter = intentRouter
    }

    // MARK: - Main Entry

    func process(
        text: String,
        userContext: UserContext,
        provider: AIProvider
    ) async throws -> ConversationProcessResult {
        let parseBatch = try await provider.parseUserInputBatch(text, context: userContext)

        // 需要追问
        if parseBatch.needsClarification {
            return ConversationProcessResult(
                finalText: parseBatch.clarificationQuestion ?? parseBatch.fallbackResponseText ?? "我没完全理解，可以换个方式再说一次吗？",
                parsedBatch: parseBatch,
                executionBatch: nil,
                firstIntent: parseBatch.first?.intent,
                firstExtractedData: parseBatch.first?.extractedData,
                shouldStreamChat: false,
                analysisContext: nil
            )
        }

        // 空结果
        if parseBatch.isEmpty {
            return ConversationProcessResult(
                finalText: "我没能识别出可执行操作，请拆开重试。",
                parsedBatch: parseBatch,
                executionBatch: nil,
                firstIntent: nil,
                firstExtractedData: nil,
                shouldStreamChat: false,
                analysisContext: nil
            )
        }

        // 分析查询拦截：queryAnalysis 不走普通查询路径
        if parseBatch.mode == .query,
           parseBatch.items.count == 1,
           parseBatch.first?.intent == .queryAnalysis {
            let request = AnalysisPeriodResolver.resolve(
                extractedData: parseBatch.first?.extractedData,
                originalText: text,
                referenceDate: Date()
            )

            let context = await AnalysisContextBuilder().build(request: request)

            if context.isEmpty {
                return ConversationProcessResult(
                    finalText: "在 \(request.periodLabel) 期间没有找到可分析的数据。你可以换一个时间范围试试。",
                    parsedBatch: parseBatch,
                    executionBatch: nil,
                    firstIntent: .queryAnalysis,
                    firstExtractedData: parseBatch.first?.extractedData,
                    shouldStreamChat: false,
                    analysisContext: nil
                )
            }

            return ConversationProcessResult(
                finalText: "",
                parsedBatch: parseBatch,
                executionBatch: nil,
                firstIntent: .queryAnalysis,
                firstExtractedData: parseBatch.first?.extractedData,
                shouldStreamChat: true,
                analysisContext: context
            )
        }

        // 纯查询
        if parseBatch.mode == .query, parseBatch.items.count == 1 {
            return ConversationProcessResult(
                finalText: "",
                parsedBatch: parseBatch,
                executionBatch: nil,
                firstIntent: parseBatch.first?.intent,
                firstExtractedData: parseBatch.first?.extractedData,
                shouldStreamChat: true,
                analysisContext: nil
            )
        }

        // 混合 query + action
        let hasQuery = parseBatch.items.contains { $0.intent.isQuery }
        let hasAction = parseBatch.items.contains { !$0.intent.isQuery && $0.intent != .unknown }
        if hasQuery && hasAction {
            return ConversationProcessResult(
                finalText: "当前版本暂不支持把查询和执行操作混在一句话里，请拆成两句发送。",
                parsedBatch: parseBatch,
                executionBatch: nil,
                firstIntent: parseBatch.first?.intent,
                firstExtractedData: parseBatch.first?.extractedData,
                shouldStreamChat: false,
                analysisContext: nil
            )
        }

        // 低置信度检查
        let hasLowConfidence = parseBatch.items.contains {
            !$0.isHighConfidence && !$0.intent.isQuery
        }
        if hasLowConfidence {
            return ConversationProcessResult(
                finalText: "我不太确定你想要做什么，可以再描述得清楚一些吗？",
                parsedBatch: parseBatch,
                executionBatch: nil,
                firstIntent: parseBatch.first?.intent,
                firstExtractedData: parseBatch.first?.extractedData,
                shouldStreamChat: false,
                analysisContext: nil
            )
        }

        // 顺序执行每个动作
        var executionItems: [AIExecutionItem] = []

        for item in parseBatch.items {
            try Task.checkCancellation()

            do {
                let routeResult = try await intentRouter.route(item.asParsedResult)
                let renderData = Self.buildRenderData(from: item, routeResult: routeResult)

                executionItems.append(
                    AIExecutionItem(
                        id: UUID().uuidString,
                        parseItemId: item.id,
                        intent: item.intent,
                        status: .success,
                        summaryText: routeResult.text,
                        renderData: renderData,
                        linkedEntityType: routeResult.linkedEntity?.type.rawValue,
                        linkedEntityId: routeResult.linkedEntity?.id.uuidString,
                        errorText: nil
                    )
                )
            } catch {
                logger.error("动作执行失败: \(item.intent.rawValue) - \(error.localizedDescription)")
                executionItems.append(
                    AIExecutionItem(
                        id: UUID().uuidString,
                        parseItemId: item.id,
                        intent: item.intent,
                        status: .failed,
                        summaryText: "\(item.intent.rawValue) 执行失败",
                        renderData: item.extractedData,
                        linkedEntityType: nil,
                        linkedEntityId: nil,
                        errorText: error.localizedDescription
                    )
                )
            }
        }

        let finalText = Self.buildFinalText(from: executionItems)
        let executionBatch = AIExecutionBatch(
            mode: executionItems.count > 1 ? .multiAction : .singleAction,
            items: executionItems,
            finalText: finalText
        )

        return ConversationProcessResult(
            finalText: finalText,
            parsedBatch: parseBatch,
            executionBatch: executionBatch,
            firstIntent: parseBatch.first?.intent,
            firstExtractedData: parseBatch.first?.extractedData,
            shouldStreamChat: false,
            analysisContext: nil
        )
    }

    // MARK: - Private Helpers

    private static func buildRenderData(
        from item: AIParseItem,
        routeResult: IntentRouter.RouteResult
    ) -> [String: String]? {
        var data = item.extractedData ?? [:]

        if let entity = routeResult.linkedEntity {
            data["entityType"] = entity.type.rawValue
            data["entityId"] = entity.id.uuidString
        }
        if let txId = routeResult.transactionId {
            data["transactionId"] = txId.uuidString
        }
        if let taskId = routeResult.taskId {
            data["taskId"] = taskId.uuidString
        }
        if let habitId = routeResult.habitId {
            data["habitId"] = habitId.uuidString
        }
        if let thoughtId = routeResult.thoughtId {
            data["thoughtId"] = thoughtId.uuidString
        }

        return data.isEmpty ? nil : data
    }

    private static func buildFinalText(from items: [AIExecutionItem]) -> String {
        guard !items.isEmpty else { return "我没能识别出可执行操作，请拆开重试。" }
        if items.count == 1 { return items[0].summaryText }

        let lines = items.enumerated().map { index, item in
            let prefix = "\(index + 1). "
            if item.status == .failed {
                return prefix + "\(item.summaryText)：\(item.errorText ?? "未知错误")"
            }
            return prefix + item.summaryText
        }

        let failedCount = items.filter { $0.status == .failed }.count
        var result = "已为你处理 \(items.count) 件事：\n" + lines.joined(separator: "\n")
        if failedCount > 0 {
            result += "\n其中 \(failedCount) 项失败"
        }
        return result
    }
}
