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
enum EntityCategory {
    case finance, task, habit, thought, memoryInsight
}

struct ChatMessageViewData: Identifiable, Equatable, Sendable {
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
    }

    init(message: ChatMessage) {
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

    // MARK: - Extracted Data

    var extractedDataDictionary: [String: String]? {
        guard let json = extractedDataJSON,
              let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return dict
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
    func resolveLinkedEntityId(for category: EntityCategory) -> UUID? {
        // 新路径：从 executionBatch 查找 linkedEntityId
        if let batch = executionBatch {
            let targetIntents = intentsForCategory(category)
            for item in batch.items {
                if targetIntents.contains(item.intent),
                   let idStr = item.linkedEntityId,
                   let id = UUID(uuidString: idStr) {
                    return id
                }
            }
        }

        // 旧路径兜底：从 extractedDataJSON 按 category 字段名查找
        return legacyEntityId(for: category)
    }

    /// 检查是否存在关联实体
    func hasLinkedEntity(for category: EntityCategory) -> Bool {
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

    private func intentsForCategory(_ category: EntityCategory) -> Set<AIIntent> {
        switch category {
        case .finance: return AIIntent.financeIntents
        case .task: return AIIntent.taskIntents
        case .habit: return [.checkIn]
        case .thought: return [.createNote]
        case .memoryInsight: return [.generateMemoryInsight]
        }
    }

    private func legacyEntityId(for category: EntityCategory) -> UUID? {
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
}
