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
nonisolated enum EntityCategory: Hashable, Sendable {
    case finance, task, habit, thought, memoryInsight, goal
}

// MARK: - MetadataState

/// 消息重元数据的加载状态
enum ChatMessageMetadataState: Equatable, Sendable {
    case unavailable   // 用户消息、流式消息 — 不需要重元数据
    case unloaded      // 可能有重元数据，尚未加载
    case loading       // 正在批量加载中
    case loaded        // 已完成加载（解码结果可以为空）
}

enum ChatMessageType: String, Codable, Sendable {
    case normal
    case goalPlanning
}

nonisolated struct ChatMessageViewData: Identifiable, Equatable, Sendable, Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
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
    private var cachedExtractedDataDictionary: [String: String]?
    private var cachedLinkedEntityIds: [EntityCategory: UUID]
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
        rawLog: LLMLog? = nil
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
        self.metadataState = .loaded
        self.cachedExtractedDataDictionary = Self.decodeExtractedData(extractedDataJSON)
        self.cachedLinkedEntityIds = Self.buildLinkedEntityIds(
            extractedDataDictionary: cachedExtractedDataDictionary,
            executionBatch: executionBatch
        )
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
            rawLog: Self.decodeRawLog(message.rawLogJSON)
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
            parsedBatch: Self.decodeParseBatch(dictionary["parsedBatchJSON"] as? String),
            executionBatch: Self.decodeExecutionBatch(dictionary["executionBatchJSON"] as? String),
            analysisContext: Self.decodeAnalysisContext(dictionary["analysisContextJSON"] as? String),
            rawLog: Self.decodeRawLog(dictionary["rawLogJSON"] as? String)
        )
    }

    /// 轻量初始化器：只解析渲染文本气泡所需的字段，不读取重 JSON 元数据
    /// 例外：queryAnalysis 消息直接解码 analysisContext，避免卡片渲染闪烁
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
        self.executionBatch = nil
        self.rawLog = nil

        // queryAnalysis 消息直接解码 analysisContext，确保首帧即可渲染卡片
        let intentStr = dictionary["intent"] as? String
        if intentStr == AIIntent.queryAnalysis.rawValue {
            self.analysisContext = Self.decodeAnalysisContext(dictionary["analysisContextJSON"] as? String)
        } else {
            self.analysisContext = nil
        }

        // 元数据状态：queryAnalysis 已解码 analysisContext 视为 loaded
        if role == "user" || isStreaming {
            self.metadataState = .unavailable
        } else if intentStr == AIIntent.queryAnalysis.rawValue && self.analysisContext != nil {
            self.metadataState = .loaded
        } else {
            self.metadataState = .unloaded
        }

        self.cachedExtractedDataDictionary = Self.decodeExtractedData(extractedDataJSON)
        self.cachedLinkedEntityIds = Self.buildLinkedEntityIds(
            extractedDataDictionary: cachedExtractedDataDictionary,
            executionBatch: nil
        )
    }

    /// 批量元数据加载后填充重字段
    mutating func enrichMetadata(
        parsedBatch: AIParseBatch?,
        executionBatch: AIExecutionBatch?,
        analysisContext: AnalysisContext?,
        rawLog: LLMLog?
    ) {
        self.parsedBatch = parsedBatch
        self.executionBatch = executionBatch
        self.analysisContext = analysisContext
        self.rawLog = rawLog
        self.metadataState = .loaded
        recomputeLinkedEntityIds()
    }

    // MARK: - Extracted Data

    nonisolated var extractedDataDictionary: [String: String]? {
        cachedExtractedDataDictionary
    }

    // MARK: - Analysis Cards

    /// 从 analysisContext 生成的卡片数据
    var analysisCards: [ChatCardData] {
        guard let context = analysisContext else { return [] }
        return ChatCardData.fromAnalysisContext(context)
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
        cachedExtractedDataDictionary = Self.decodeExtractedData(extractedDataJSON)
        cachedLinkedEntityIds = Self.buildLinkedEntityIds(
            extractedDataDictionary: cachedExtractedDataDictionary,
            executionBatch: executionBatch
        )
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

    /// 检查关联实体是否已被删除
    /// - Transaction: 硬删除（不存在即为已删除）
    /// - TodoTask: 软删除（deletedFlag == true 即为已删除）
    nonisolated func isEntityDeleted(for category: EntityCategory) -> Bool {
        guard let entityId = resolveLinkedEntityId(for: category) else { return false }
        return !Self.entityExists(entityId, category: category)
    }

    /// 检查指定实体是否存在（且未被软删除）
    nonisolated private static func entityExists(_ id: UUID, category: EntityCategory) -> Bool {
        let context = CoreDataStack.shared.viewContext
        switch category {
        case .finance:
            let request = Transaction.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            return (try? context.count(for: request)) ?? 0 > 0
        case .task:
            let request = TodoTask.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@ AND deletedFlag == NO", id as CVarArg)
            request.fetchLimit = 1
            return (try? context.count(for: request)) ?? 0 > 0
        case .goal:
            let request = Goal.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            return (try? context.count(for: request)) ?? 0 > 0
        default:
            return true
        }
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
