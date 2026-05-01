//
//  ChatMessageViewData.swift
//  Holo
//
//  Chat 对话消息的值类型快照
//  让 SwiftUI 渲染层不再直接依赖 Core Data 对象
//

import Foundation

// MARK: - EntityCategory

/// 实体类别，用于统一解析 linkedEntityId
nonisolated enum EntityCategory: Hashable, Sendable {
    case finance, task, habit, thought, memoryInsight
}

nonisolated struct ChatMessageViewData: Identifiable, Equatable, Sendable {
    let id: UUID
    var role: String
    var content: String
    var timestamp: Date
    var intent: String?
    var extractedDataJSON: String?
    var isStreaming: Bool
    var parentMessageId: UUID?
    var parsedBatch: AIParseBatch?
    var executionBatch: AIExecutionBatch?
    private var cachedExtractedDataDictionary: [String: String]?
    private var cachedLinkedEntityIds: [EntityCategory: UUID]

    init(
        id: UUID,
        role: String,
        content: String,
        timestamp: Date,
        intent: String?,
        extractedDataJSON: String?,
        isStreaming: Bool,
        parentMessageId: UUID?,
        parsedBatch: AIParseBatch? = nil,
        executionBatch: AIExecutionBatch? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.intent = intent
        self.extractedDataJSON = extractedDataJSON
        self.isStreaming = isStreaming
        self.parentMessageId = parentMessageId
        self.parsedBatch = parsedBatch
        self.executionBatch = executionBatch
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
            parsedBatch: message.parsedBatch,
            executionBatch: message.executionBatch
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
            executionBatch: Self.decodeExecutionBatch(dictionary["executionBatchJSON"] as? String)
        )
    }

    // MARK: - Extracted Data

    nonisolated var extractedDataDictionary: [String: String]? {
        cachedExtractedDataDictionary
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

    // MARK: - Unified Entity Resolution

    /// 统一实体解析：新路径（executionBatch）优先，旧路径（extractedDataJSON）兜底
    nonisolated func resolveLinkedEntityId(for category: EntityCategory) -> UUID? {
        cachedLinkedEntityIds[category]
    }

    /// 检查是否存在关联实体
    nonisolated func hasLinkedEntity(for category: EntityCategory) -> Bool {
        resolveLinkedEntityId(for: category) != nil
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

    nonisolated private static func decodeParseBatch(_ json: String?) -> AIParseBatch? {
        guard let json,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(AIParseBatch.self, from: data)
    }

    nonisolated private static func decodeExecutionBatch(_ json: String?) -> AIExecutionBatch? {
        guard let json,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(AIExecutionBatch.self, from: data)
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

        for category in [EntityCategory.finance, .task, .habit, .thought, .memoryInsight] where ids[category] == nil {
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
        }
        guard let idStr = dict[key] else { return nil }
        return UUID(uuidString: idStr)
    }
}
