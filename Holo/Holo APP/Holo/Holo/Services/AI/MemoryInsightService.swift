//
//  MemoryInsightService.swift
//  Holo
//
//  记忆洞察生成服务
//  串联上下文构建 → AI 调用 → JSON 解析 → 持久化
//

import Foundation
import os.log

@MainActor
final class MemoryInsightService {

    static let shared = MemoryInsightService()

    /// 是否应优先从 Agent Result 读取记忆长廊（灰度，agentMemoryGalleryEnabled flag 保护）。
    /// flag 关闭时保持现有 MemoryInsightService 流程作为 fallback。
    static var shouldReadAgentResults: Bool {
        HoloAIFeatureFlags.agentMemoryGalleryEnabled
    }

    private let logger = Logger(subsystem: "com.holo.app", category: "MemoryInsightService")
    private let repository = MemoryInsightRepository()
    private let contextBuilder = MemoryInsightContextBuilder()

    /// 当前是否正在生成（防止重复点击）
    private(set) var isGenerating: Bool = false

    /// 超时时间（秒）
    private let generationTimeout: TimeInterval = 70

    /// 缓存的 AI Provider
    private var currentProvider: AIProvider?

    private init() {
        // 监听 AI 配置变更通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resetProvider),
            name: .aiConfigDidChange,
            object: nil
        )
    }

    // MARK: - AI Configuration Check

    /// 检查 AI 是否已配置
    var isAIConfigured: Bool {
        if HoloBackendEnvironment.isEnabledByDefault {
            return true
        }

        guard let config = try? KeychainService.shared.loadAIConfig() else {
            return false
        }
        return config.isConfigured
    }

    // MARK: - Provider Resolution

    /// 从 Keychain 读取 AI 配置并创建 Provider
    private func resolveProvider() throws -> AIProvider {
        if let current = currentProvider { return current }
        let provider = HoloBackendEnvironment.makeDefaultProvider()
        currentProvider = provider
        return provider
    }

    @objc private func resetProvider() {
        currentProvider = nil
        logger.info("AI Provider 已重置")
    }

    // MARK: - Generate Insight

    /// 生成指定周期的洞察
    /// - Parameters:
    ///   - periodType: 周期类型（weekly/monthly）
    ///   - start: 周期开始日期
    ///   - end: 周期结束日期
    ///   - forceRefresh: 是否强制刷新（跳过 hash 检查）
    /// - Returns: 生成完成的 MemoryInsight
    func generateInsight(
        periodType: MemoryInsightPeriodType,
        start: Date,
        end: Date,
        forceRefresh: Bool = false,
        observationStage: MemoryInsightObservationStage = .full7d
    ) async throws -> MemoryInsight {
        // consent 最终防线：未授权 AI 数据处理时一律拒绝生成，覆盖全部 8 个调用入口
        // （手动 / Chat 意图 / 后台日周月 / 前台补偿日周月）。见本周观察方案 §4.1。
        guard HoloAIFeatureFlags.aiDataProcessingConsentGranted else {
            throw MemoryInsightError.aiDataProcessingConsentRequired
        }

        // 并发保护
        guard !isGenerating else {
            throw MemoryInsightError.generationInProgress
        }
        isGenerating = true
        defer { isGenerating = false }

        // 让 UI 有机会渲染"生成中"状态，避免点击后立即卡死
        await Task.yield()

        // 0. 聚合未消费反馈（生成前批量聚合，偏好更新后用于本次生成）
        if InsightFeatureFlags.preferenceLearningEnabled {
            let context = CoreDataStack.shared.viewContext
            InsightFeedbackAggregator.shared.aggregate(in: context)
            await Task.yield()
        }

        // 1. 构建上下文
        let (context, snapshotHash) = await contextBuilder.build(
            periodType: periodType,
            start: start,
            end: end
        )
        try Task.checkCancellation()
        await Task.yield()

        // Prompt 版本不再公开下发；生成结果会记录服务端返回的版本（若有）。
        let currentPromptVersion: Int16 = 0
        try Task.checkCancellation()

        // 3. 检查缓存（非强制刷新且 hash + version 一致）
        if !forceRefresh {
            if let existing = repository.fetchInsight(
                periodType: periodType,
                start: start,
                end: end,
                snapshotHash: snapshotHash,
                promptVersion: currentPromptVersion
            ), existing.insightStatus == .ready {
                logger.info("洞察缓存命中（hash + version），跳过生成")
                return existing
            }
        }

        // 4. 去重检查：与同版本、同 stage 近期洞察文本相似度（方案 §4.2，避免跨 stage 误杀）
        if !forceRefresh {
            if let similar = checkSimilarityWithRecent(
                periodType: periodType,
                observationStage: observationStage,
                context: context,
                promptVersion: currentPromptVersion
            ) {
                logger.info("洞察与近期内容高度相似，跳过生成")
                return similar
            }
        }

        // 5. 获取 Provider
        let provider = try resolveProvider()
        try Task.checkCancellation()

        // 6. 保存 generating 状态
        let insight = try repository.saveGenerating(
            periodType: periodType,
            start: start,
            end: end,
            snapshotHash: snapshotHash,
            observationStage: observationStage
        )

        // 7. 序列化上下文为 JSON
        let contextJSON: String
        do {
            let data = try JSONEncoder().encode(context)
            guard let json = String(data: data, encoding: .utf8) else {
                throw MemoryInsightError.contextBuildFailed("JSON 编码失败")
            }
            contextJSON = json
        } catch {
            try? repository.saveFailed(insight: insight, errorMessage: error.localizedDescription)
            throw MemoryInsightError.contextBuildFailed(error.localizedDescription)
        }
        try Task.checkCancellation()

        // 8. 调用 AI（带超时）
        let insightType: InsightType
        switch periodType {
        case .daily: insightType = .memoryDailyReview
        case .weekly: insightType = .memoryWeeklyReplay
        case .monthly, .quarterly, .custom: insightType = .memoryMonthlyReplay
        }
        let generationResult: MemoryInsightGenerationResult
        do {
            generationResult = try await withThrowingTaskGroup(of: MemoryInsightGenerationResult.self) { group in
            group.addTask {
                try await provider.generateMemoryInsight(type: insightType, contextJSON: contextJSON)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.generationTimeout) * 1_000_000_000)
                throw MemoryInsightError.generationTimeout
            }

            guard let first = try await group.next() else {
                throw MemoryInsightError.generationTimeout
            }
            group.cancelAll()
            return first
        }
        } catch {
            let apiError = error as? APIError
            try? repository.saveFailed(
                insight: insight,
                errorMessage: error.localizedDescription,
                category: apiError?.diagnosticCategory ?? String(describing: type(of: error)),
                requestId: apiError?.requestId
            )
            throw error
        }
        try Task.checkCancellation()

        // 7. 解析 JSON：区分空响应、非法 JSON 与 Schema 不完整，避免向用户暴露原始模型文本。
        let payload: MemoryInsightPayload
        switch MemoryInsightResponseParser.parseResult(generationResult.rawResponse) {
        case .success(let parsed):
            payload = parsed
        case .failure(let failure):
            try? repository.saveFailed(
                insight: insight,
                errorMessage: failure.userMessage,
                category: String(describing: failure),
                requestId: generationResult.requestId
            )
            throw failure
        }

        // 8. Evidence 后处理
        var processedPayload = payload
        processedPayload = postProcessEvidence(processedPayload, start: start, end: end)

        // 8.5 Post-process: 填充 moduleHint / patternType
        processedPayload = MemoryInsightResponseParser.fillModuleHints(processedPayload)

        // 8.6 Rerank: 根据偏好排序
        if InsightFeatureFlags.rerankEnabled {
            let profile = InsightPreferenceProfileService.shared.loadProfile()
            let rerankedCards = InsightCardReranker.rerank(processedPayload.cards, with: profile)
            processedPayload = MemoryInsightPayload(
                title: processedPayload.title,
                summary: processedPayload.summary,
                cards: rerankedCards,
                suggestedQuestions: processedPayload.suggestedQuestions
            )
        }

        // 9. 保存 ready 状态（使用真实 promptVersion）
        let providerName: String? = nil
        let promptVersion = Int16(generationResult.promptVersion ?? 0)
        try repository.saveReady(
            insight: insight,
            payload: processedPayload,
            rawResponse: generationResult.rawResponse,
            providerName: providerName,
            promptVersion: promptVersion,
            requestId: generationResult.requestId
        )

        // 10. 发送洞察生成完成通知（供长期记忆候选提取使用）
        let cardPayloads: [[String: Any]] = processedPayload.cards.compactMap { card in
            guard card.patternType != nil, !card.evidence.isEmpty else { return nil }

            var payload: [String: Any] = [
                "id": card.id,
                "title": card.title,
                "summary": card.body,
                "patternType": card.patternType ?? "",
                "evidence": card.evidence.map { [
                    "sourceID": ($0.matchedSourceId?.uuidString) ?? "",
                    "excerpt": $0.label
                ] },
                "cardType": card.type.rawValue
            ]

            // 携带记忆候选语义字段
            if let mc = card.memoryCandidate {
                payload["memoryCandidate"] = [
                    "subjectKey": mc.subjectKey,
                    "semanticType": mc.semanticType,
                    "displaySummary": mc.displaySummary,
                    "aiUseSummary": mc.aiUseSummary
                ] as [String: String]
            }

            return payload
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .memoryInsightDidGenerate,
                object: nil,
                userInfo: [
                    "insightID": insight.id.uuidString,
                    "cards": cardPayloads
                ]
            )
        }

        logger.info("洞察生成成功：\(periodType.rawValue)")
        return insight
    }

    // MARK: - Mark Stale

    /// 检查并标记过期洞察
    func markStaleIfNeeded(
        periodType: MemoryInsightPeriodType,
        start: Date,
        end: Date
    ) async {
        let (_, newHash) = await contextBuilder.build(
            periodType: periodType,
            start: start,
            end: end
        )
        try? repository.markStaleIfNeeded(
            periodType: periodType,
            start: start,
            end: end,
            newSnapshotHash: newHash
        )
    }

    // MARK: - Evidence Post-Processing

    /// 按 (date, sourceType) 查找匹配的 MemoryItem UUID
    private func postProcessEvidence(
        _ payload: MemoryInsightPayload,
        start: Date,
        end: Date
    ) -> MemoryInsightPayload {
        var processedCards: [MemoryInsightCard] = []

        for card in payload.cards {
            var processedEvidence: [MemoryInsightEvidence] = []
            for ev in card.evidence {
                var updated = ev
                if let dateStr = ev.date,
                   let sourceType = ev.sourceType,
                   let date = DateFormatter.yyyyMMdd.date(from: dateStr) {
                    updated.matchedSourceId = findMatchingSourceId(
                        date: date,
                        sourceType: sourceType
                    )
                }
                processedEvidence.append(updated)
            }
            processedCards.append(MemoryInsightCard(
                id: card.id,
                type: card.type,
                title: card.title,
                body: card.body,
                evidence: processedEvidence,
                suggestedQuestion: card.suggestedQuestion,
                anomalySeverity: card.anomalySeverity,
                moduleHint: card.moduleHint,
                patternType: card.patternType,
                memoryCandidate: card.memoryCandidate
            ))
        }

        return MemoryInsightPayload(
            title: payload.title,
            summary: payload.summary,
            cards: processedCards,
            suggestedQuestions: payload.suggestedQuestions
        )
    }

    /// 按 (date, sourceType) 查询第一条匹配的 MemoryItem id
    private func findMatchingSourceId(date: Date, sourceType: String) -> UUID? {
        // MVP: 不做精确匹配，evidence 主要用于 UI 展示文字而非跳转
        // 后续可升级为按 content 关键词匹配
        return nil
    }

    // MARK: - Dedup

    /// 检查近期洞察相似度（同 promptVersion 内去重）
    private func checkSimilarityWithRecent(
        periodType: MemoryInsightPeriodType,
        observationStage: MemoryInsightObservationStage,
        context: MemoryInsightContext,
        promptVersion: Int16
    ) -> MemoryInsight? {
        let recentInsights = repository.fetchRecentReadyInsights(
            periodType: periodType,
            observationStage: observationStage,
            promptVersion: promptVersion,
            limit: 3
        )
        guard !recentInsights.isEmpty else { return nil }

        // 提取本期 context 关键 token
        let currentTokens = extractContextTokens(context)

        for insight in recentInsights {
            guard let payload = insight.parsedPayload else { continue }
            let historicTokens = extractPayloadTokens(payload)

            // 计算交集比例
            let intersection = Set(currentTokens).intersection(Set(historicTokens))
            let union = Set(currentTokens).union(Set(historicTokens))
            guard !union.isEmpty else { continue }

            let similarity = Double(intersection.count) / Double(union.count)
            if similarity > 0.85 {
                logger.info("洞察去重命中，相似度 \(similarity)")
                return insight
            }
        }
        return nil
    }

    /// 从 context 提取关键词 token
    private func extractContextTokens(_ context: MemoryInsightContext) -> [String] {
        var tokens: [String] = []
        // 财务关键词
        for cat in context.finance.topCategories {
            tokens.append(cat.categoryName)
        }
        // 习惯关键词
        tokens.append(contentsOf: context.habits.topPerformingHabits)
        tokens.append(contentsOf: context.habits.strugglingHabits)
        // 任务关键词
        tokens.append(contentsOf: context.tasks.importantCompletedTasks)
        // 异常关键词
        for anomaly in context.anomalies {
            tokens.append(anomaly.title)
        }
        return tokens.filter { !$0.isEmpty }
    }

    /// 从 payload 提取文本 token（过滤数字日期等易变 token）
    private func extractPayloadTokens(_ payload: MemoryInsightPayload) -> [String] {
        var tokens: [String] = []
        tokens.append(payload.title)
        tokens.append(payload.summary)

        for card in payload.cards {
            tokens.append(card.title)
            // body 中过滤数字和日期
            let filteredBody = card.body.components(separatedBy: CharacterSet.decimalDigits)
                .joined()
                .components(separatedBy: CharacterSet(charactersIn: "-/¥%"))
                .filter { $0.count >= 2 }
            tokens.append(contentsOf: filteredBody)
        }

        return tokens.filter { $0.count >= 2 }
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let aiConfigDidChange = Notification.Name("aiConfigDidChange")
}

// MARK: - Date Formatter Extension

private extension DateFormatter {
    static let yyyyMMdd: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
