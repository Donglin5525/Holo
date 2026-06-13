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
    /// 灵活查询结构化结果，供 ChatViewModel 渲染
    let flexibleQueryResult: FlexibleQueryResult?
    /// 命中本地深度 Agent 分流（query_analysis + agentRuntimeEnabled 开）。默认 false。
    var shouldRouteToAgent: Bool = false
    /// 意图识别 LLM 调用日志
    var intentCallLog: LLMCallLog?
    /// 结构化执行 parser 调用日志
    var actionParserCallLog: LLMCallLog?
}

@MainActor
final class ConversationCoordinator {

    private let logger = Logger(subsystem: "com.holo.app", category: "ConversationCoordinator")
    private let intentRouter: IntentRouting

    init(intentRouter: IntentRouting? = nil) {
        self.intentRouter = intentRouter ?? IntentRouter.shared
    }

    /// 是否应把该 intent 路由到本地深度 Agent（灰度，agentRuntimeEnabled flag 保护）。
    /// 仅 query_analysis 类分析意图、且非记账/打卡等执行动作才进 Agent。
    static func shouldRouteToDeepAgent(intent: String) -> Bool {
        guard HoloAIFeatureFlags.agentRuntimeEnabled else { return false }
        let executionIntents: Set<String> = [
            "record_expense", "record_income", "create_task", "complete_task",
            "update_task", "delete_task", "check_in"
        ]
        guard !executionIntents.contains(intent) else { return false }
        return intent == "query_analysis"
    }

    // MARK: - Main Entry

    func process(
        text: String,
        userContext: UserContext,
        provider: AIProvider
    ) async throws -> ConversationProcessResult {
        let parseBatch = try await provider.parseUserInputBatch(text, context: userContext)
        let intentLog = provider.lastCallLog

        // 需要追问
        if parseBatch.needsClarification {
            return ConversationProcessResult(
                finalText: parseBatch.clarificationQuestion ?? parseBatch.fallbackResponseText ?? "我没完全理解，可以换个方式再说一次吗？",
                parsedBatch: parseBatch,
                executionBatch: nil,
                firstIntent: parseBatch.first?.intent,
                firstExtractedData: parseBatch.first?.extractedData,
                shouldStreamChat: false,
                analysisContext: nil,
                flexibleQueryResult: nil,
                intentCallLog: intentLog,
                actionParserCallLog: nil
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
                analysisContext: nil,
                flexibleQueryResult: nil,
                intentCallLog: intentLog,
                actionParserCallLog: nil
            )
        }

        // 深度 Agent 分流（灰度，agentRuntimeEnabled 把关）：query_analysis 命中 → 走本地 Agent
        if let firstIntent = parseBatch.first?.intent,
           Self.shouldRouteToDeepAgent(intent: firstIntent.rawValue) {
            return ConversationProcessResult(
                finalText: "",
                parsedBatch: parseBatch,
                executionBatch: nil,
                firstIntent: firstIntent,
                firstExtractedData: parseBatch.first?.extractedData,
                shouldStreamChat: false,
                analysisContext: nil,
                flexibleQueryResult: nil,
                shouldRouteToAgent: true,
                intentCallLog: intentLog,
                actionParserCallLog: nil
            )
        }

        // 分析查询拦截：queryAnalysis 不走普通查询路径
        // 不限制 mode，因为不同 LLM 可能返回 single_action 而非 query
        if parseBatch.items.count == 1,
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
                    analysisContext: nil,
                    flexibleQueryResult: nil,
                    intentCallLog: intentLog,
                    actionParserCallLog: nil
                )
            }

            return ConversationProcessResult(
                finalText: "",
                parsedBatch: parseBatch,
                executionBatch: nil,
                firstIntent: .queryAnalysis,
                firstExtractedData: parseBatch.first?.extractedData,
                shouldStreamChat: true,
                analysisContext: context,
                flexibleQueryResult: nil,
                intentCallLog: intentLog,
                actionParserCallLog: nil
            )
        }

        // 灵活数据查询拦截（Branch 3.5）：无论 mode 是 query 还是 single_action
        if parseBatch.items.count == 1,
           parseBatch.first?.intent == .flexibleDataQuery {
            return await handleFlexibleQuery(
                text: text,
                extractedData: parseBatch.first?.extractedData,
                userContext: userContext,
                provider: provider,
                parseBatch: parseBatch,
                intentLog: intentLog
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
                analysisContext: nil,
                flexibleQueryResult: nil,
                intentCallLog: intentLog,
                actionParserCallLog: nil
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
                analysisContext: nil,
                flexibleQueryResult: nil,
                intentCallLog: intentLog,
                actionParserCallLog: nil
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
                analysisContext: nil,
                flexibleQueryResult: nil,
                intentCallLog: intentLog,
                actionParserCallLog: nil
            )
        }

        // 执行前校验
        let validationResult = AIParseBatchValidator.validate(batch: parseBatch)
        if !validationResult.isValid {
            for issue in validationResult.issues {
                logger.info("校验问题 [item \(issue.itemIndex)] \(issue.code.rawValue): \(issue.message)")
            }
        }

        // 顺序执行每个动作
        var executionItems: [AIExecutionItem] = []
        var actionParserLog: LLMCallLog?

        for item in parseBatch.items {
            try Task.checkCancellation()

            if item.intent == .createTask {
                var renderData = item.extractedData ?? [:]

                // 重复任务：触发 action parser 补充 repeat 字段
                if Self.looksLikeRepeatTask(text, data: item.extractedData),
                   let actionResult = try? await callActionParser(
                       text: text,
                       data: item.extractedData,
                       kind: .taskRepeat,
                       userContext: userContext,
                       provider: provider
                   ) {
                    actionParserLog = actionResult.log
                    // Step 3a: DEBUG 探针——只记录 key set，不记录 value
                    #if DEBUG
                    let taskParserKeys = actionResult.data.keys.sorted().joined(separator: ",")
                    logger.debug("Task action parser returned keys: \(taskParserKeys, privacy: .public)")
                    #endif
                    // Step 3b: 显式白名单合并——只允许 repeat* 字段
                    for (key, value) in actionResult.data where !value.isEmpty && Self.repeatParserKeys.contains(key) {
                        renderData[key] = value
                    }
                }

                renderData["confirmationStatus"] = "pending"
                renderData["pendingKind"] = "task"
                executionItems.append(
                    AIExecutionItem(
                        id: UUID().uuidString,
                        parseItemId: item.id,
                        intent: item.intent,
                        status: .skipped,
                        summaryText: renderData["repeatEnabled"] == "true"
                            ? "我识别到一个重复提醒，请确认后创建"
                            : "我识别到一个待办，请确认后创建",
                        renderData: renderData.isEmpty ? nil : renderData,
                        linkedEntityType: nil,
                        linkedEntityId: nil,
                        errorText: nil
                    )
                )
                continue
            }

            if item.intent.isFinance {
                var renderData = item.extractedData ?? [:]

                // 分期记账：触发 action parser 补充 installment 字段
                if Self.looksLikeInstallment(text, data: item.extractedData),
                   let actionResult = try? await callActionParser(
                       text: text,
                       data: item.extractedData,
                       kind: .financeInstallment,
                       userContext: userContext,
                       provider: provider
                   ) {
                    actionParserLog = actionResult.log
                    // Step 3a: DEBUG 探针——只记录 key set，不记录 value
                    #if DEBUG
                    let financeParserKeys = actionResult.data.keys.sorted().joined(separator: ",")
                    logger.debug("Finance action parser returned keys: \(financeParserKeys, privacy: .public)")
                    #endif
                    // Step 3b: 显式白名单合并——只允许 installment* 字段
                    for (key, value) in actionResult.data where !value.isEmpty && Self.installmentParserKeys.contains(key) {
                        renderData[key] = value
                    }
                }

                // 预览分类匹配（不创建交易，仅获取真实分类名用于卡片展示）
                let txType: TransactionType = item.intent == .recordIncome ? .income : .expense
                if let preview = try? await intentRouter.previewCategoryMatch(
                    extractedData: item.extractedData,
                    type: txType
                ) {
                    if let primary = preview.primary {
                        renderData["primaryCategory"] = primary
                    }
                    if let sub = preview.sub {
                        renderData["subCategory"] = sub
                    }
                }

                renderData["confirmationStatus"] = "pending"
                renderData["pendingKind"] = "transaction"
                let summary: String
                if renderData["installmentEnabled"] == "true" {
                    let periods = renderData["installmentPeriods"] ?? "?"
                    summary = "我识别到一笔分期支出，分 \(periods) 期，请确认后记录"
                } else {
                    summary = item.intent == .recordExpense
                        ? "我识别到一笔支出，请确认后记录"
                        : "我识别到一笔收入，请确认后记录"
                }
                executionItems.append(
                    AIExecutionItem(
                        id: UUID().uuidString,
                        parseItemId: item.id,
                        intent: item.intent,
                        status: .skipped,
                        summaryText: summary,
                        renderData: renderData.isEmpty ? nil : renderData,
                        linkedEntityType: nil,
                        linkedEntityId: nil,
                        errorText: nil
                    )
                )
                continue
            }

            do {
                let routeResult = try await intentRouter.route(item.asParsedResult)
                let renderData = Self.buildRenderData(from: item, routeResult: routeResult)

                logger.info("[多动作] item=\(item.id) intent=\(item.intent.rawValue) note=\(renderData?["note"] ?? "nil") candidate=\(renderData?["categoryCandidate"] ?? "nil") primary=\(renderData?["primaryCategory"] ?? "nil") sub=\(renderData?["subCategory"] ?? "nil")")

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
            analysisContext: nil,
            flexibleQueryResult: nil,
            intentCallLog: intentLog,
            actionParserCallLog: actionParserLog
        )
    }

    // MARK: - Private Helpers

    // MARK: Parser 白名单——显式列出允许从 parser 结果写入 renderData 的字段

    /// finance_action_parser 允许覆盖的字段（与 defaultPrompts.json finance_action_parser 输出字段对齐）
    private static let installmentParserKeys: Set<String> = [
        "installmentEnabled", "installmentTotalAmount",
        "installmentPeriods", "installmentFeePerPeriod",
        "installmentFirstDueDate", "installmentSummary",
    ]

    /// task_action_parser 允许覆盖的字段（与 defaultPrompts.json task_action_parser 输出字段对齐）
    private static let repeatParserKeys: Set<String> = [
        "repeatEnabled", "repeatType", "repeatInterval",
        "repeatWeekdays", "repeatMonthDay", "repeatUntilDate", "repeatSummary",
    ]

    // MARK: Action Parser 触发判断

    private static func looksLikeInstallment(_ text: String, data: [String: String]?) -> Bool {
        if let data = data, data["installmentEnabled"] == "true" { return true }
        let patterns = ["分\\d+期", "分\\s*期", "分期", "分[二三四五六七八九十]+期"]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static func looksLikeRepeatTask(_ text: String, data: [String: String]?) -> Bool {
        if let data = data, data["repeatEnabled"] == "true" { return true }
        let patterns = ["每隔", "每天", "每周[一二三四五六日天]", "每月\\d+号", "每周[一二三四五六日天]和"]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private func callActionParser(
        text: String,
        data: [String: String]?,
        kind: AIActionParserKind,
        userContext: UserContext,
        provider: AIProvider
    ) async throws -> (data: [String: String], log: LLMCallLog?) {
        let batch = try await provider.parseActionInput(text, context: userContext, kind: kind)
        guard let data = batch.first?.extractedData else {
            throw APIError.serverError(batch.clarificationQuestion ?? "结构化执行解析没有返回有效字段")
        }
        return (data, provider.lastCallLog)
    }

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

        // 分类未匹配时，覆盖卡片显示为统一兜底分类，保留 categoryCandidate 供 UI 展示
        if routeResult.categoryUnmatched {
            data["primaryCategory"] = FinancePendingCategory.currentName
            data["subCategory"] = nil
        } else {
            // 匹配成功时，用 Core Data 真实科目名覆盖 LLM 可能缺失的值
            if let primary = routeResult.matchedPrimaryCategory {
                data["primaryCategory"] = primary
            }
            if let sub = routeResult.matchedSubCategory {
                data["subCategory"] = sub
            }
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

    // MARK: - Flexible Query

    private func handleFlexibleQuery(
        text: String,
        extractedData: [String: String]?,
        userContext: UserContext,
        provider: AIProvider,
        parseBatch: AIParseBatch,
        intentLog: LLMCallLog?
    ) async -> ConversationProcessResult {
        do {
            let plannerResult = try await FlexibleQueryPlanner(provider: provider)
                .plan(userQuestion: text, extractedData: extractedData, userContext: userContext)

            switch plannerResult.status {
            case .needsClarification:
                return ConversationProcessResult(
                    finalText: plannerResult.clarificationQuestion ?? "你能再说具体一些吗？",
                    parsedBatch: parseBatch,
                    executionBatch: nil,
                    firstIntent: .flexibleDataQuery,
                    firstExtractedData: extractedData,
                    shouldStreamChat: false,
                    analysisContext: nil,
                    flexibleQueryResult: nil,
                    intentCallLog: intentLog,
                    actionParserCallLog: nil
                )

            case .unsupported:
                return ConversationProcessResult(
                    finalText: "这个问题当前还不能基于本地数据查询，我可以帮你分析一段时间的消费趋势。",
                    parsedBatch: parseBatch,
                    executionBatch: nil,
                    firstIntent: .flexibleDataQuery,
                    firstExtractedData: extractedData,
                    shouldStreamChat: false,
                    analysisContext: nil,
                    flexibleQueryResult: nil,
                    intentCallLog: intentLog,
                    actionParserCallLog: nil
                )

            case .ready:
                guard let plan = plannerResult.plan else {
                    return ConversationProcessResult(
                        finalText: "抱歉，查询出了点问题。你可以换个方式问我。",
                        parsedBatch: parseBatch,
                        executionBatch: nil,
                        firstIntent: .flexibleDataQuery,
                        firstExtractedData: extractedData,
                        shouldStreamChat: false,
                        analysisContext: nil,
                        flexibleQueryResult: nil,
                        intentCallLog: intentLog,
                        actionParserCallLog: nil
                    )
                }

                let result = try await FlexibleQueryExecutor().execute(plan)
                let answer = FlexibleQueryAnswerBuilder().answer(result)

                return ConversationProcessResult(
                    finalText: answer,
                    parsedBatch: parseBatch,
                    executionBatch: nil,
                    firstIntent: .flexibleDataQuery,
                    firstExtractedData: extractedData,
                    shouldStreamChat: false,
                    analysisContext: nil,
                    flexibleQueryResult: result,
                    intentCallLog: intentLog,
                    actionParserCallLog: nil
                )
            }
        } catch {
            logger.error("FlexibleQuery 失败: \(error.localizedDescription)")
            return ConversationProcessResult(
                finalText: "抱歉，查询出了点问题。你可以换个方式问我，或者让我帮你分析一段时间的消费记录。",
                parsedBatch: parseBatch,
                executionBatch: nil,
                firstIntent: .flexibleDataQuery,
                firstExtractedData: extractedData,
                shouldStreamChat: false,
                analysisContext: nil,
                flexibleQueryResult: nil,
                intentCallLog: intentLog,
                actionParserCallLog: nil
            )
        }
    }
}
