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

    init(
        id: UUID,
        role: String,
        content: String,
        timestamp: Date,
        intent: String?,
        extractedDataJSON: String?,
        isStreaming: Bool,
        parentMessageId: UUID?
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.intent = intent
        self.extractedDataJSON = extractedDataJSON
        self.isStreaming = isStreaming
        self.parentMessageId = parentMessageId
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
            parentMessageId: message.parentMessageId
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
