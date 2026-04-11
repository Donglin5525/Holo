//
//  ChatMessageRepository.swift
//  Holo
//
//  ChatMessage 数据仓库
//  管理 AI 对话消息的 CRUD 操作
//

import Foundation
import CoreData
import Combine
import os.log

@MainActor
final class ChatMessageRepository: ObservableObject {

    static let shared = ChatMessageRepository()

    @Published var messages: [ChatMessage] = []

    private let logger = Logger(subsystem: "com.holo.app", category: "ChatMessageRepository")
    private let context: NSManagedObjectContext

    private init(context: NSManagedObjectContext = CoreDataStack.shared.viewContext) {
        self.context = context
        loadMessages()
    }

    // MARK: - Load

    /// 加载消息（按时间排序，限制最近 200 条）
    func loadMessages() {
        let request = ChatMessage.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchLimit = 200

        do {
            messages = try context.fetch(request).reversed()
        } catch {
            logger.error("加载消息失败：\(error.localizedDescription)")
        }
    }

    /// 加载最近的 N 条消息
    func loadRecentMessages(limit: Int = 50) -> [ChatMessage] {
        let request = ChatMessage.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchLimit = limit

        do {
            let result = try context.fetch(request)
            return result.reversed()
        } catch {
            logger.error("加载最近消息失败：\(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Add

    /// 添加消息
    @discardableResult
    func addMessage(
        role: String,
        content: String,
        intent: String? = nil,
        extractedDataJSON: String? = nil,
        parentMessageId: UUID? = nil
    ) -> ChatMessage {
        let message = ChatMessage(context: context)
        message.id = UUID()
        message.role = role
        message.content = content
        message.timestamp = Date()
        message.intent = intent
        message.extractedDataJSON = extractedDataJSON
        message.isStreaming = false
        message.parentMessageId = parentMessageId

        save()

        messages.append(message)
        return message
    }

    /// 添加流式占位消息
    @discardableResult
    func addStreamingMessage(role: String, parentMessageId: UUID? = nil) -> ChatMessage {
        let message = ChatMessage(context: context)
        message.id = UUID()
        message.role = role
        message.content = ""
        message.timestamp = Date()
        message.isStreaming = true
        message.parentMessageId = parentMessageId

        save()

        messages.append(message)
        return message
    }

    // MARK: - Update

    /// 更新消息内容
    func updateMessage(_ message: ChatMessage, content: String) {
        message.content = content
        save()
    }

    /// 结束流式状态
    func finishStreaming(_ message: ChatMessage, finalContent: String) {
        message.content = finalContent
        message.isStreaming = false
        save()
    }

    /// 更新消息的意图和提取数据
    func updateMessageMetadata(_ message: ChatMessage, intent: String?, extractedDataJSON: String?) {
        message.intent = intent
        message.extractedDataJSON = extractedDataJSON
        save()
    }

    // MARK: - Delete

    /// 删除单条消息
    func deleteMessage(_ message: ChatMessage) {
        context.delete(message)
        save()
        messages.removeAll { $0.id == message.id }
    }

    /// 清除所有消息
    func clearAllMessages() {
        for message in messages {
            context.delete(message)
        }
        save()
        messages.removeAll()
        logger.info("已清除所有对话消息")
    }

    // MARK: - Convert to DTO

    /// 将消息列表转换为 ChatMessageDTO 数组（用于 API 调用）
    func toDTOs(from messages: [ChatMessage]) -> [ChatMessageDTO] {
        messages.compactMap { message in
            switch message.role {
            case "user": return .user(message.content)
            case "assistant": return .assistant(message.content)
            case "system": return .system(message.content)
            default: return nil
            }
        }
    }

    // MARK: - Private

    private func save() {
        do {
            if context.hasChanges {
                try context.save()
            }
        } catch {
            logger.error("保存消息失败：\(error.localizedDescription)")
        }
    }
}
