//
//  ChatMessageViewData.swift
//  Holo
//
//  Chat 对话消息的值类型快照
//  让 SwiftUI 渲染层不再直接依赖 Core Data 对象
//

import Foundation

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

    var extractedDataDictionary: [String: String]? {
        guard let json = extractedDataJSON,
              let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return dict
    }

    var linkedTransactionId: UUID? {
        guard let idStr = extractedDataDictionary?["transactionId"] else {
            return nil
        }
        return UUID(uuidString: idStr)
    }

    var linkedTaskId: UUID? {
        guard let idStr = extractedDataDictionary?["taskId"] else {
            return nil
        }
        return UUID(uuidString: idStr)
    }

    /// 检查 executionBatch 中是否存在任务类型的 linkedEntityId
    /// extractedDataJSON 只有 LLM 原始数据（不含 taskId），
    /// 真正的 taskId 在 executionBatch.items[].linkedEntityId 中
    var hasTaskLinkedEntity: Bool {
        guard let batch = executionBatch else { return false }
        let taskIntents: Set<AIIntent> = [.createTask, .completeTask, .updateTask]
        return batch.items.contains { item in
            taskIntents.contains(item.intent) && item.linkedEntityId != nil
        }
    }

    var linkedEntity: LinkedEntity? {
        guard let dict = extractedDataDictionary else { return nil }

        if let typeStr = dict["entityType"],
           let idStr = dict["entityId"],
           let type = LinkedEntityType(rawValue: typeStr),
           let id = UUID(uuidString: idStr) {
            return LinkedEntity(type: type, id: id)
        }

        if let idStr = dict["transactionId"], let id = UUID(uuidString: idStr) {
            return LinkedEntity(type: .transaction, id: id)
        }
        if let idStr = dict["taskId"], let id = UUID(uuidString: idStr) {
            return LinkedEntity(type: .task, id: id)
        }
        if let idStr = dict["habitId"], let id = UUID(uuidString: idStr) {
            return LinkedEntity(type: .habit, id: id)
        }
        if let idStr = dict["thoughtId"], let id = UUID(uuidString: idStr) {
            return LinkedEntity(type: .thought, id: id)
        }

        return nil
    }

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
}
