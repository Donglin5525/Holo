//
//  ChatMessageViewData.swift
//  Holo
//
//  Chat 对话消息的值类型快照
//  让 SwiftUI 渲染层不再直接依赖 Core Data 对象
//

import Foundation
import CoreData

// MARK: - EntityCategory

/// 实体类别，用于统一解析 linkedEntityId
nonisolated enum EntityCategory: Hashable, Sendable, CaseIterable {
    case finance, task, habit, thought, memoryInsight, goal
}

// MARK: - MetadataState

/// 消息重元数据的加载状态
nonisolated enum ChatMessageMetadataState: Equatable, Sendable {
    case unavailable   // 用户消息、流式消息 — 不需要重元数据
    case unloaded      // 可能有重元数据，尚未加载
    case loading       // 正在批量加载中
    case loaded        // 已完成加载（解码结果可以为空）
}

enum ChatMessageType: String, Codable, Sendable {
    case normal
    case goalPlanning
    case periodReplay   // 周期回放（原记忆长廊 AI 回放，迁移到聊天）
    case quotaExhausted // 免费/Plus 额度耗尽提示（非系统错误，是档位限制）
}

nonisolated struct ChatMessageViewData: Identifiable, Equatable, Sendable, Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// 只比较源数据字段 + 外部预填状态。
    /// 派生缓存（cachedExtractedDataDictionary / cachedLinkedEntityIds /
    /// cachedAnalysisCards / cachedFlexibleQueryResult / cachedFlexibleQueryCard /
    /// cachedExecutionCards / cachedSingleCard / cachedSavedGoalCard）是源数据的
    /// 确定性函数，不参与相等判断——既正确（源相等则缓存相等）又更快
    /// （避免在 MessageBubbleView.equatable() 里比较大体积的卡片数组）。
    static func == (lhs: ChatMessageViewData, rhs: ChatMessageViewData) -> Bool {
        lhs.id == rhs.id
            && lhs.role == rhs.role
            && lhs.content == rhs.content
            && lhs.timestamp == rhs.timestamp
            && lhs.intent == rhs.intent
            && lhs.extractedDataJSON == rhs.extractedDataJSON
            && lhs.isStreaming == rhs.isStreaming
            && lhs.parentMessageId == rhs.parentMessageId
            && lhs.messageType == rhs.messageType
            && lhs.parsedBatch == rhs.parsedBatch
            && lhs.executionBatch == rhs.executionBatch
            && lhs.analysisContext == rhs.analysisContext
            && lhs.rawLog == rhs.rawLog
            && lhs.agentResult == rhs.agentResult
            && lhs.insightResult == rhs.insightResult
            && lhs.metadataState == rhs.metadataState
            && lhs.cachedDeletionState == rhs.cachedDeletionState
            && lhs.showsTimestampSeparator == rhs.showsTimestampSeparator
    }
    let id: UUID
    var role: String
    var content: String
    var timestamp: Date
    var intent: String?
    var extractedDataJSON: String?
    var isStreaming: Bool
    var parentMessageId: UUID?
    var messageType: ChatMessageType
    var parsedBatch: AIParseBatch?
    var executionBatch: AIExecutionBatch?
    var analysisContext: AnalysisContext?
    var rawLog: LLMLog?
    var agentResult: HoloRenderedAgentResult?
    var insightResult: MemoryInsightPayload?
    private var cachedExtractedDataDictionary: [String: String]?
    private var cachedLinkedEntityIds: [EntityCategory: UUID]
    /// 关联实体的删除态缓存（预计算，避免渲染时逐条查 Core Data）
    private var cachedDeletionState: [EntityCategory: Bool] = [:]
    // MARK: - 渲染派生数据缓存
    // 把"解码 JSON / 重建卡片 / 格式化金额"等成本从滑动渲染期移到数据创建期。
    // 滑动时每条消息只读取这些缓存，不再现算，避免数据量增大后逐条掉帧。
    private var cachedAnalysisCards: [ChatCardData] = []
    private var cachedFlexibleQueryResult: FlexibleQueryResult?
    private var cachedFlexibleQueryCard: ChatCardData?
    private var cachedExecutionCards: [ChatCardData] = []
    private var cachedSingleCard: ChatCardData?
    private var cachedSavedGoalCard: GoalSavedChatCardData?
    /// 是否在该消息上方显示时间分隔条（由 ChatViewModel 按相邻消息间隔预计算）。
    var showsTimestampSeparator: Bool = false
    var metadataState: ChatMessageMetadataState

    init(
        id: UUID,
        role: String,
        content: String,
        timestamp: Date,
        intent: String?,
        extractedDataJSON: String?,
        isStreaming: Bool,
        parentMessageId: UUID?,
        messageType: ChatMessageType = .normal,
        parsedBatch: AIParseBatch? = nil,
        executionBatch: AIExecutionBatch? = nil,
        analysisContext: AnalysisContext? = nil,
        rawLog: LLMLog? = nil,
        agentResult: HoloRenderedAgentResult? = nil,
        insightResult: MemoryInsightPayload? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.intent = intent
        self.extractedDataJSON = extractedDataJSON
        self.isStreaming = isStreaming
        self.parentMessageId = parentMessageId
        self.messageType = messageType
        self.parsedBatch = parsedBatch
        self.executionBatch = executionBatch
        self.analysisContext = analysisContext
        self.rawLog = rawLog
        self.agentResult = agentResult
        self.insightResult = insightResult
        self.metadataState = .loaded
        self.cachedExtractedDataDictionary = Self.decodeExtractedData(extractedDataJSON)
        self.cachedLinkedEntityIds = Self.buildLinkedEntityIds(
            extractedDataDictionary: cachedExtractedDataDictionary,
            executionBatch: executionBatch
        )
        recomputeDerivedCardCache()
    }

    @MainActor init(message: ChatMessage) {
        self.init(
            id: message.id,
            role: message.role,
            content: message.content,
            timestamp: message.timestamp,
            intent: message.intent,
            extractedDataJSON: message.extractedDataJSON,
            isStreaming: message.isStreaming,
            parentMessageId: message.parentMessageId,
            messageType: ChatMessageType(rawValue: message.messageType) ?? .normal,
            parsedBatch: message.parsedBatch,
            executionBatch: message.executionBatch,
            analysisContext: Self.decodeAnalysisContext(message.analysisContextJSON),
            rawLog: Self.decodeRawLog(message.rawLogJSON),
            agentResult: Self.decodeAgentResult(message.agentResultJSON),
            insightResult: Self.decodeInsightResult(message.insightResultJSON)
        )
    }

    init?(dictionary: [String: Any]) {
        guard let id = dictionary["id"] as? UUID,
              let role = dictionary["role"] as? String,
              let content = dictionary["content"] as? String,
              let timestamp = dictionary["timestamp"] as? Date,
              let isStreaming = dictionary["isStreaming"] as? Bool else {
            return nil
        }

        self.init(
            id: id,
            role: role,
            content: content,
            timestamp: timestamp,
            intent: dictionary["intent"] as? String,
            extractedDataJSON: dictionary["extractedDataJSON"] as? String,
            isStreaming: isStreaming,
            parentMessageId: dictionary["parentMessageId"] as? UUID,
            messageType: ChatMessageType(
                rawValue: dictionary["messageType"] as? String ?? ChatMessageType.normal.rawValue
            ) ?? .normal,
            parsedBatch: Self.decodeParseBatch(dictionary["parsedBatchJSON"] as? String),
            executionBatch: Self.decodeExecutionBatch(dictionary["executionBatchJSON"] as? String),
            analysisContext: Self.decodeAnalysisContext(dictionary["analysisContextJSON"] as? String),
            rawLog: Self.decodeRawLog(dictionary["rawLogJSON"] as? String),
            agentResult: Self.decodeAgentResult(dictionary["agentResultJSON"] as? String),
            insightResult: Self.decodeInsightResult(dictionary["insightResultJSON"] as? String)
        )
    }

    /// 轻量初始化器：只解析首屏渲染所需字段。
    /// queryAnalysis 与 periodReplay 直接解码结构化结果，避免卡片退化成普通文字气泡。
    init?(lightweightDictionary dictionary: [String: Any]) {
        guard let id = dictionary["id"] as? UUID,
              let role = dictionary["role"] as? String,
              let content = dictionary["content"] as? String,
              let timestamp = dictionary["timestamp"] as? Date,
              let isStreaming = dictionary["isStreaming"] as? Bool else {
            return nil
        }

        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.intent = dictionary["intent"] as? String
        self.extractedDataJSON = dictionary["extractedDataJSON"] as? String
        self.isStreaming = isStreaming
        self.parentMessageId = dictionary["parentMessageId"] as? UUID
        self.messageType = ChatMessageType(rawValue: dictionary["messageType"] as? String ?? "normal") ?? .normal
        self.parsedBatch = nil
        self.executionBatch = Self.decodeExecutionBatch(dictionary["executionBatchJSON"] as? String)
        self.rawLog = Self.decodeRawLog(dictionary["rawLogJSON"] as? String)

        // queryAnalysis 消息直接解码 analysisContext 和 agentResult，确保首帧即可渲染卡片。
        let intentStr = dictionary["intent"] as? String
        if intentStr == AIIntent.queryAnalysis.rawValue {
            self.analysisContext = Self.decodeAnalysisContext(dictionary["analysisContextJSON"] as? String)
            self.agentResult = Self.decodeAgentResult(dictionary["agentResultJSON"] as? String)
        } else {
            self.analysisContext = nil
            self.agentResult = nil
        }
        self.insightResult = Self.decodeInsightResult(dictionary["insightResultJSON"] as? String)

        // 元数据状态：首屏轻量查询会带上卡片渲染和日志所需字段，避免等待滚动触发懒加载。
        let hasFetchedCardMetadata =
            dictionary.keys.contains("executionBatchJSON") ||
            dictionary.keys.contains("rawLogJSON") ||
            dictionary.keys.contains("agentResultJSON") ||
            dictionary.keys.contains("insightResultJSON")
        if role == "user" || isStreaming {
            self.metadataState = .unavailable
        } else if hasFetchedCardMetadata {
            self.metadataState = .loaded
        } else if intentStr == AIIntent.queryAnalysis.rawValue && self.analysisContext != nil {
            self.metadataState = .loaded
        } else {
            self.metadataState = .unloaded
        }

        self.cachedExtractedDataDictionary = Self.decodeExtractedData(extractedDataJSON)
        self.cachedLinkedEntityIds = Self.buildLinkedEntityIds(
            extractedDataDictionary: cachedExtractedDataDictionary,
            executionBatch: executionBatch
        )
        recomputeDerivedCardCache()
    }

    /// 批量元数据加载后填充重字段
    mutating func enrichMetadata(
        parsedBatch: AIParseBatch?,
        executionBatch: AIExecutionBatch?,
        analysisContext: AnalysisContext?,
        rawLog: LLMLog?,
        agentResult: HoloRenderedAgentResult?,
        insightResult: MemoryInsightPayload?
    ) {
        self.parsedBatch = parsedBatch
        self.executionBatch = executionBatch
        self.analysisContext = analysisContext
        self.rawLog = rawLog
        self.agentResult = agentResult
        self.insightResult = insightResult
        self.metadataState = .loaded
        recomputeLinkedEntityIds()
        recomputeDerivedCardCache()
    }

    // MARK: - Extracted Data

    nonisolated var extractedDataDictionary: [String: String]? {
        cachedExtractedDataDictionary
    }

    mutating func setExtractedDataJSON(_ json: String?) {
        extractedDataJSON = json
        cachedExtractedDataDictionary = Self.decodeExtractedData(json)
        recomputeLinkedEntityIds()
        recomputeDerivedCardCache()
    }

    // MARK: - Analysis Cards

    /// 从 analysisContext 生成的卡片数据（读预算缓存）
    var analysisCards: [ChatCardData] {
        cachedAnalysisCards
    }

    /// 从 flexible query 结构化结果生成的查询卡片（读预算缓存）
    var flexibleQueryCard: ChatCardData? {
        cachedFlexibleQueryCard
    }

    var flexibleQueryResult: FlexibleQueryResult? {
        cachedFlexibleQueryResult
    }

    /// 从 executionBatch 构建的多卡片数据（读预算缓存）
    var executionCards: [ChatCardData] {
        cachedExecutionCards
    }

    /// 旧路径单卡片数据（读预算缓存）
    var singleCard: ChatCardData? {
        cachedSingleCard
    }

    /// 保存完成的目标卡片数据（读预算缓存）
    var savedGoalCard: GoalSavedChatCardData? {
        cachedSavedGoalCard
    }

    /// 是否为分析查询消息
    var isQueryAnalysis: Bool {
        guard let intentStr = intent,
              let intent = AIIntent(rawValue: intentStr) else { return false }
        return intent == .queryAnalysis
    }

    /// 是否为错误消息（AI 处理失败、超时、watchdog 中断等）
    var isError: Bool {
        content.hasPrefix("抱歉，处理时出错了") || content.hasSuffix("处理中断") || content.hasSuffix("响应超时")
    }

    /// 是否为额度耗尽提示（档位限制，区别于系统错误 isError）
    var isQuotaExhausted: Bool {
        messageType == .quotaExhausted
    }

    // 旧路径兜底：从 extractedDataJSON 解析（新项通常为 nil）
    private var linkedTransactionId: UUID? {
        guard let idStr = extractedDataDictionary?["transactionId"] else {
            return nil
        }
        return UUID(uuidString: idStr)
    }

    private var linkedTaskId: UUID? {
        guard let idStr = extractedDataDictionary?["taskId"] else {
            return nil
        }
        return UUID(uuidString: idStr)
    }

    // MARK: - Cache Invalidation

    /// 重新计算缓存的关联实体 ID（updateSnapshot 后调用）
    mutating func recomputeLinkedEntityIds() {
        let oldIds = cachedLinkedEntityIds
        cachedExtractedDataDictionary = Self.decodeExtractedData(extractedDataJSON)
        cachedLinkedEntityIds = Self.buildLinkedEntityIds(
            extractedDataDictionary: cachedExtractedDataDictionary,
            executionBatch: executionBatch
        )
        // 关联实体变更时，丢弃旧的删除态缓存，待下次预填刷新
        for category in EntityCategory.allCases where cachedLinkedEntityIds[category] != oldIds[category] {
            cachedDeletionState.removeValue(forKey: category)
        }
    }

    // MARK: - Render Cache

    /// 重新预算渲染派生数据缓存。
    /// 在所有会改变源数据（analysisContext / executionBatch / extractedData /
    /// intent / role / messageType / isStreaming）的入口调用，确保渲染期读到的卡片数据始终最新。
    private mutating func recomputeDerivedCardCache() {
        cachedAnalysisCards = analysisContext.map { ChatCardData.fromAnalysisContext($0) } ?? []
        cachedFlexibleQueryResult = decodeFlexibleQueryResult()
        cachedFlexibleQueryCard = ChatCardData.fromFlexibleQueryResult(cachedFlexibleQueryResult)
        cachedExecutionCards = ChatCardData.multiple(from: executionBatch)
        cachedSingleCard = derivedSingleCard()
        cachedSavedGoalCard = derivedSavedGoalCard()
    }

    private func decodeFlexibleQueryResult() -> FlexibleQueryResult? {
        guard let json = cachedExtractedDataDictionary?["flexibleQueryResultJSON"],
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(FlexibleQueryResult.self, from: data)
    }

    private func derivedSingleCard() -> ChatCardData? {
        guard role != "user",
              let intentStr = intent,
              let intentValue = AIIntent(rawValue: intentStr),
              !isStreaming else {
            return nil
        }
        return ChatCardData.from(intent: intentValue, data: cachedExtractedDataDictionary)
    }

    private func derivedSavedGoalCard() -> GoalSavedChatCardData? {
        guard role != "user",
              messageType == .goalPlanning,
              !isStreaming else {
            return nil
        }
        return GoalSavedChatCardData(dictionary: cachedExtractedDataDictionary)
    }

    // MARK: - Unified Entity Resolution

    /// 统一实体解析：新路径（executionBatch）优先，旧路径（extractedDataJSON）兜底
    nonisolated func resolveLinkedEntityId(for category: EntityCategory) -> UUID? {
        cachedLinkedEntityIds[category]
    }

    /// 检查是否存在关联实体
    nonisolated func hasLinkedEntity(for category: EntityCategory) -> Bool {
        resolveLinkedEntityId(for: category) != nil
    }

    // MARK: - Entity Deletion State

    /// 检查关联实体是否已被删除（读预计算缓存，不再渲染期查 Core Data）
    /// - Transaction: 硬删除（不存在即为已删除）
    /// - TodoTask: 软删除（deletedFlag == true 即为已删除）
    nonisolated func isEntityDeleted(for category: EntityCategory) -> Bool {
        cachedDeletionState[category] ?? false
    }

    /// 用预计算结果刷新删除态缓存（供 Repository 批量预填 / Core Data 变更时失效）
    mutating func setDeletionState(_ isDeleted: Bool, for category: EntityCategory) {
        cachedDeletionState[category] = isDeleted
    }

    // MARK: - DTO

    var dto: ChatMessageDTO? {
        switch role {
        case "user":
            return .user(content)
        case "assistant":
            return .assistant(content)
        case "system":
            return .system(content)
        default:
            return nil
        }
    }

    // MARK: - Private Helpers

    nonisolated private func intentsForCategory(_ category: EntityCategory) -> Set<AIIntent> {
        switch category {
        case .finance: return AIIntent.financeIntents
        case .task: return AIIntent.taskIntents
        case .habit: return [.checkIn]
        case .thought: return [.createNote]
        case .memoryInsight: return [.generateMemoryInsight]
        case .goal: return []
        }
    }

    nonisolated private func legacyEntityId(for category: EntityCategory) -> UUID? {
        guard let dict = extractedDataDictionary else { return nil }
        let key: String
        switch category {
        case .finance: key = "transactionId"
        case .task: key = "taskId"
        case .habit: key = "habitId"
        case .thought: key = "thoughtId"
        case .memoryInsight: key = "entityId"
        case .goal: key = "goalId"
        }
        guard let idStr = dict[key] else { return nil }
        return UUID(uuidString: idStr)
    }

    nonisolated private static func decodeExtractedData(_ json: String?) -> [String: String]? {
        guard let json,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    nonisolated static func decodeParseBatch(_ json: String?) -> AIParseBatch? {
        guard let json,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(AIParseBatch.self, from: data)
    }

    nonisolated static func decodeExecutionBatch(_ json: String?) -> AIExecutionBatch? {
        guard let json,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(AIExecutionBatch.self, from: data)
    }

    nonisolated static func decodeAnalysisContext(_ json: String?) -> AnalysisContext? {
        guard let json,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(AnalysisContext.self, from: data)
    }

    nonisolated static func decodeRawLog(_ json: String?) -> LLMLog? {
        guard let json,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(LLMLog.self, from: data)
    }

    nonisolated static func decodeAgentResult(_ json: String?) -> HoloRenderedAgentResult? {
        guard let json,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(HoloRenderedAgentResult.self, from: data)
    }

    nonisolated static func decodeInsightResult(_ json: String?) -> MemoryInsightPayload? {
        guard let json,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(MemoryInsightPayload.self, from: data)
    }

    nonisolated private static func buildLinkedEntityIds(
        extractedDataDictionary: [String: String]?,
        executionBatch: AIExecutionBatch?
    ) -> [EntityCategory: UUID] {
        var ids: [EntityCategory: UUID] = [:]

        if let batch = executionBatch {
            for item in batch.items {
                guard let idStr = item.linkedEntityId,
                      let id = UUID(uuidString: idStr),
                      let category = category(for: item.intent) else {
                    continue
                }
                ids[category] = id
            }
        }

        for category in [EntityCategory.finance, .task, .habit, .thought, .memoryInsight, .goal] where ids[category] == nil {
            guard let id = legacyEntityId(for: category, in: extractedDataDictionary) else { continue }
            ids[category] = id
        }

        return ids
    }

    nonisolated private static func category(for intent: AIIntent) -> EntityCategory? {
        if AIIntent.financeIntents.contains(intent) { return .finance }
        if AIIntent.taskIntents.contains(intent) { return .task }
        switch intent {
        case .checkIn: return .habit
        case .createNote: return .thought
        case .generateMemoryInsight: return .memoryInsight
        default: return nil
        }
    }

    nonisolated private static func legacyEntityId(for category: EntityCategory, in dict: [String: String]?) -> UUID? {
        guard let dict else { return nil }
        let key: String
        switch category {
        case .finance: key = "transactionId"
        case .task: key = "taskId"
        case .habit: key = "habitId"
        case .thought: key = "thoughtId"
        case .memoryInsight: key = "entityId"
        case .goal: key = "goalId"
        }
        guard let idStr = dict[key] else { return nil }
        return UUID(uuidString: idStr)
    }
}
