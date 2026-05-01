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

    @Published private(set) var messages: [ChatMessageViewData] = []

    private let logger = Logger(subsystem: "com.holo.app", category: "ChatMessageRepository")
    private var liveMessageCache: [UUID: ChatMessage] = [:]

    /// 延迟初始化 context，避免 init 时触发 CoreDataStack 懒加载
    /// CoreDataStack 在 HoloApp.init() 中异步启动，store 后台加载
    /// HomeView.task 中 await waitUntilReady() 后再通过 lazy var 访问 context
    /// 使用 lazy 确保只在真正需要读/写消息时才触发
    private lazy var context: NSManagedObjectContext = CoreDataStack.shared.viewContext

    /// init 不做任何 I/O 操作，避免阻塞主线程
    private init() {}

    // MARK: - Load

    /// 加载消息（按时间排序，限制最近 200 条）
    func loadMessages() {
        let request = ChatMessage.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchLimit = 200

        do {
            let fetched = try context.fetch(request)
            liveMessageCache = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
            messages = fetched.reversed().map(ChatMessageViewData.init)
        } catch {
            logger.error("加载消息失败：\(error.localizedDescription)")
        }
    }

    /// 异步加载消息：
    /// 在后台上下文中直接转成值类型快照，避免界面持有 Core Data 对象。
    func loadMessagesAsync(limit: Int = 200) async {
        await CoreDataStack.shared.waitUntilReady()

        let snapshots: [ChatMessageViewData]

        do {
            snapshots = try await Task.detached(priority: .utility) {
                let context = CoreDataStack.shared.newBackgroundContext()
                return try await context.perform {
                    let request = NSFetchRequest<NSDictionary>(entityName: "ChatMessage")
                    request.resultType = .dictionaryResultType
                    request.propertiesToFetch = [
                        "id",
                        "role",
                        "content",
                        "timestamp",
                        "intent",
                        "extractedDataJSON",
                        "isStreaming",
                        "parentMessageId",
                        "parsedBatchJSON",
                        "executionBatchJSON"
                    ]
                    request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                    request.fetchLimit = limit

                    return try context.fetch(request)
                        .reversed()
                        .compactMap { ChatMessageViewData(dictionary: $0 as? [String: Any] ?? [:]) }
                }
            }.value
        } catch {
            logger.error("后台加载消息快照失败：\(error.localizedDescription)")
            return
        }

        liveMessageCache.removeAll()
        messages = snapshots
    }

    /// 加载最近的 N 条消息
    func loadRecentMessages(limit: Int = 50) -> [ChatMessageViewData] {
        Array(messages.suffix(limit))
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
    ) -> UUID {
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

        liveMessageCache[message.id] = message
        messages.append(ChatMessageViewData(message: message))
        return message.id
    }

    /// 添加流式占位消息
    @discardableResult
    func addStreamingMessage(role: String, parentMessageId: UUID? = nil) -> UUID {
        let message = ChatMessage(context: context)
        message.id = UUID()
        message.role = role
        message.content = ""
        message.timestamp = Date()
        message.isStreaming = true
        message.parentMessageId = parentMessageId

        save()

        liveMessageCache[message.id] = message
        messages.append(ChatMessageViewData(message: message))
        return message.id
    }

    // MARK: - Update

    /// 更新消息内容
    func updateMessage(_ messageId: UUID, content: String) {
        guard let message = liveMessageCache[messageId] else { return }
        message.content = content
        save()
        updateSnapshot(messageId) { snapshot in
            snapshot.content = content
        }
    }

    /// 结束流式状态
    func finishStreaming(_ messageId: UUID, finalContent: String) {
        guard let message = liveMessageCache[messageId] else { return }
        message.content = finalContent
        message.isStreaming = false
        save()
        updateSnapshot(messageId) { snapshot in
            snapshot.content = finalContent
            snapshot.isStreaming = false
        }
    }

    /// 原子化最终写入：结束流式 + 写入元数据，单次 save + 单次 snapshot 更新
    func finalizeMessage(
        _ messageId: UUID,
        finalContent: String,
        intent: String?,
        extractedDataJSON: String?,
        parsedBatchJSON: String?,
        executionBatchJSON: String?
    ) {
        guard let message = liveMessageCache[messageId] else { return }

        // Core Data 写入（单次 save）
        message.content = finalContent
        message.isStreaming = false
        message.intent = intent
        message.extractedDataJSON = extractedDataJSON
        message.parsedBatchJSON = parsedBatchJSON
        message.executionBatchJSON = executionBatchJSON
        save()

        // 解码 batch 数据（绕过 associated object 缓存）
        let decodedParsedBatch: AIParseBatch? = parsedBatchJSON.flatMap { json in
            guard let data = json.data(using: .utf8) else { return nil }
            do {
                return try JSONDecoder().decode(AIParseBatch.self, from: data)
            } catch {
                logger.error("解析 parsedBatchJSON 失败：\(error.localizedDescription)")
                return nil
            }
        }
        let decodedExecutionBatch: AIExecutionBatch? = executionBatchJSON.flatMap { json in
            guard let data = json.data(using: .utf8) else { return nil }
            do {
                return try JSONDecoder().decode(AIExecutionBatch.self, from: data)
            } catch {
                logger.error("解析 executionBatchJSON 失败：\(error.localizedDescription)")
                return nil
            }
        }

        // 单次 snapshot 更新
        updateSnapshot(messageId) { snapshot in
            snapshot.content = finalContent
            snapshot.isStreaming = false
            snapshot.intent = intent
            snapshot.extractedDataJSON = extractedDataJSON
            snapshot.parsedBatch = decodedParsedBatch
            snapshot.executionBatch = decodedExecutionBatch
        }
    }

    /// 更新消息的意图和提取数据（含批量字段）
    func updateMessageMetadata(
        _ messageId: UUID,
        intent: String?,
        extractedDataJSON: String?,
        parsedBatchJSON: String? = nil,
        executionBatchJSON: String? = nil
    ) {
        guard let message = liveMessageCache[messageId] else { return }
        message.intent = intent
        message.extractedDataJSON = extractedDataJSON
        message.parsedBatchJSON = parsedBatchJSON
        message.executionBatchJSON = executionBatchJSON
        save()

        // 直接从 JSON 解码 batch 数据，绕过 ChatMessage 的 associated object 缓存
        // （finishStreaming 先于本方法执行，首次访问时 JSON 为 nil 会缓存 NSNull）
        let decodedParsedBatch: AIParseBatch? = parsedBatchJSON.flatMap { json in
            guard let data = json.data(using: .utf8) else { return nil }
            do {
                return try JSONDecoder().decode(AIParseBatch.self, from: data)
            } catch {
                logger.error("解析 parsedBatchJSON 失败：\(error.localizedDescription)")
                return nil
            }
        }
        let decodedExecutionBatch: AIExecutionBatch? = executionBatchJSON.flatMap { json in
            guard let data = json.data(using: .utf8) else { return nil }
            do {
                return try JSONDecoder().decode(AIExecutionBatch.self, from: data)
            } catch {
                logger.error("解析 executionBatchJSON 失败：\(error.localizedDescription)")
                return nil
            }
        }

        updateSnapshot(messageId) { snapshot in
            snapshot.intent = intent
            snapshot.extractedDataJSON = extractedDataJSON
            snapshot.parsedBatch = decodedParsedBatch
            snapshot.executionBatch = decodedExecutionBatch
        }
    }

    // MARK: - Delete

    /// 删除单条消息
    func deleteMessage(_ messageId: UUID) {
        guard let message = liveMessageCache[messageId] else { return }
        context.delete(message)
        save()
        liveMessageCache.removeValue(forKey: messageId)
        messages.removeAll { $0.id == messageId }
    }

    /// 清除所有消息
    func clearAllMessages() {
        let request = ChatMessage.fetchRequest()

        do {
            let storedMessages = try context.fetch(request)
            for message in storedMessages {
                context.delete(message)
            }
        } catch {
            logger.error("清除消息前加载失败：\(error.localizedDescription)")
        }

        save()
        liveMessageCache.removeAll()
        messages.removeAll()
        logger.info("已清除所有对话消息")
    }

    // MARK: - Convert to DTO

    /// 将消息列表转换为 ChatMessageDTO 数组（用于 API 调用）
    func toDTOs(from messages: [ChatMessageViewData]) -> [ChatMessageDTO] {
        messages.compactMap(\.dto)
    }

    // MARK: - Private

    private func updateSnapshot(_ messageId: UUID, mutate: (inout ChatMessageViewData) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        var snapshot = messages[index]
        mutate(&snapshot)
        messages[index] = snapshot
    }

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
