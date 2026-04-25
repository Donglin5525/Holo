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

    private let logger = Logger(subsystem: "com.holo.app", category: "MemoryInsightService")
    private let repository = MemoryInsightRepository()

    /// 当前是否正在生成（防止重复点击）
    private(set) var isGenerating: Bool = false

    /// 超时时间（秒）
    private let generationTimeout: TimeInterval = 30

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
        guard let config = try? KeychainService.shared.loadAIConfig() else {
            return false
        }
        return config.isConfigured
    }

    // MARK: - Provider Resolution

    /// 从 Keychain 读取 AI 配置并创建 Provider
    private func resolveProvider() throws -> AIProvider {
        if let current = currentProvider { return current }

        guard let config = try KeychainService.shared.loadAIConfig(),
              config.isConfigured else {
            throw MemoryInsightError.aiNotConfigured
        }

        let provider = OpenAICompatibleProvider(config: config)
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
        forceRefresh: Bool = false
    ) async throws -> MemoryInsight {
        // 并发保护
        guard !isGenerating else {
            throw MemoryInsightError.generationInProgress
        }
        isGenerating = true
        defer { isGenerating = false }

        // 1. 构建上下文
        let (context, snapshotHash) = await MemoryInsightContextBuilder.build(
            periodType: periodType,
            referenceDate: end
        )

        // 2. 检查缓存（非强制刷新且 hash 一致）
        if !forceRefresh {
            if let existing = try repository.fetchInsight(periodType: periodType, start: start, end: end),
               existing.sourceSnapshotHash == snapshotHash,
               existing.insightStatus == .ready {
                logger.info("洞察缓存命中，跳过生成")
                return existing
            }
        }

        // 3. 获取 Provider
        let provider = try resolveProvider()

        // 4. 保存 generating 状态
        let insight = try repository.saveGenerating(
            periodType: periodType,
            start: start,
            end: end,
            snapshotHash: snapshotHash
        )

        // 5. 序列化上下文为 JSON
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

        // 6. 调用 AI（带超时）
        let insightType: InsightType = periodType == .weekly ? .memoryWeeklyReplay : .memoryMonthlyReplay
        let rawResponse: String
        do {
            rawResponse = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await provider.generateMemoryInsight(type: insightType, contextJSON: contextJSON)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.generationTimeout) * 1_000_000_000)
                throw MemoryInsightError.generationTimeout
            }

            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        } catch {
            try? repository.saveFailed(insight: insight, errorMessage: error.localizedDescription)
            throw error
        }

        // 7. 解析 JSON
        guard let payload = MemoryInsightResponseParser.parse(rawResponse) else {
            let errorMsg = String(rawResponse.prefix(200))
            try? repository.saveFailed(insight: insight, errorMessage: "JSON 解析失败：\(errorMsg)")
            throw MemoryInsightError.parsingFailed(errorMsg)
        }

        // 8. Evidence 后处理
        var processedPayload = payload
        processedPayload = postProcessEvidence(processedPayload, start: start, end: end)

        // 9. 保存 ready 状态
        let providerName: String? = nil
        try repository.saveReady(
            insight: insight,
            payload: processedPayload,
            rawResponse: rawResponse,
            providerName: providerName,
            promptVersion: 1
        )

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
        let (_, newHash) = await MemoryInsightContextBuilder.build(
            periodType: periodType,
            referenceDate: end
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
                suggestedQuestion: card.suggestedQuestion
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
}

// MARK: - Notification Name

extension Notification.Name {
    static let aiConfigDidChange = Notification.Name("aiConfigDidChange")
    static let memoryInsightContinueInChat = Notification.Name("memoryInsightContinueInChat")
}

// MARK: - Date Formatter Extension

private extension DateFormatter {
    static let yyyyMMdd: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
