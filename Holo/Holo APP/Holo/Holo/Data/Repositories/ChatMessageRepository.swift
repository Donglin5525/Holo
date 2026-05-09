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
    @Published private(set) var hasEarlierSessions: Bool = false

    private let logger = Logger(subsystem: "com.holo.app", category: "ChatMessageRepository")
    private var liveMessageCache: [UUID: ChatMessage] = [:]
    private var oldestLoadedTimestamp: Date?
    private let sessionGap: TimeInterval = 4 * 60 * 60 // 4 小时会话边界

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
                        "executionBatchJSON",
                        "analysisContextJSON",
                        "rawLogJSON"
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

    /// 轻量加载消息：只读取渲染文本气泡所需的字段，不读取重 JSON 元数据
    func loadLightweightMessagesAsync(limit: Int = 30) async {
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
                        "analysisContextJSON"
                    ]
                    request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                    request.fetchLimit = limit

                    return try context.fetch(request)
                        .reversed()
                        .compactMap { ChatMessageViewData(lightweightDictionary: $0 as? [String: Any] ?? [:]) }
                }
            }.value
        } catch {
            logger.error("后台轻量加载消息快照失败：\(error.localizedDescription)")
            return
        }

        liveMessageCache.removeAll()
        messages = snapshots
    }

    /// 加载当前会话的轻量消息：从最新消息向前扫描，遇到 4 小时间隔则截断
    func loadCurrentSessionLightweightMessagesAsync(limit: Int = 50) async {
        await CoreDataStack.shared.waitUntilReady()

        let snapshots: [ChatMessageViewData]

        do {
            // 两步查询：先查 id+timestamp 确定会话边界，再查轻量字段
            let sessionIds: [UUID] = try await Task.detached(priority: .utility) {
                let context = CoreDataStack.shared.newBackgroundContext()
                return try await context.perform {
                    let request = NSFetchRequest<NSDictionary>(entityName: "ChatMessage")
                    request.resultType = .dictionaryResultType
                    request.propertiesToFetch = ["id", "timestamp"]
                    request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                    request.fetchLimit = limit

                    let rows = try context.fetch(request)
                    var ids: [UUID] = []
                    var prevTimestamp: Date?

                    for row in rows {
                        guard let id = row["id"] as? UUID,
                              let ts = row["timestamp"] as? Date else { continue }

                        if let prev = prevTimestamp, prev.timeIntervalSince(ts) > self.sessionGap {
                            break
                        }
                        ids.append(id)
                        prevTimestamp = ts
                    }
                    return ids
                }
            }.value

            guard !sessionIds.isEmpty else {
                liveMessageCache.removeAll()
                messages = []
                hasEarlierSessions = false
                return
            }

            snapshots = try await Task.detached(priority: .utility) {
                let context = CoreDataStack.shared.newBackgroundContext()
                return try await context.perform {
                    let request = NSFetchRequest<NSDictionary>(entityName: "ChatMessage")
                    request.resultType = .dictionaryResultType
                    request.propertiesToFetch = [
                        "id", "role", "content", "timestamp",
                        "intent", "extractedDataJSON", "isStreaming", "parentMessageId",
                        "analysisContextJSON"
                    ]
                    request.predicate = NSPredicate(format: "id IN %@", sessionIds)
                    request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

                    return try context.fetch(request)
                        .compactMap { ChatMessageViewData(lightweightDictionary: $0 as? [String: Any] ?? [:]) }
                }
            }.value

            // 检查是否还有更早的消息
            let earliestTimestamp = snapshots.first?.timestamp
            let hasEarlier = try await Task.detached(priority: .utility) {
                let context = CoreDataStack.shared.newBackgroundContext()
                return try await context.perform {
                    let countRequest = NSFetchRequest<NSNumber>(entityName: "ChatMessage")
                    countRequest.resultType = .countResultType
                    if let earliest = earliestTimestamp {
                        countRequest.predicate = NSPredicate(format: "timestamp < %@", earliest as NSDate)
                    }
                    let result = try context.fetch(countRequest)
                    return (result.first?.intValue ?? 0) > 0
                }
            }.value

            liveMessageCache.removeAll()
            messages = snapshots
            oldestLoadedTimestamp = snapshots.first?.timestamp
            hasEarlierSessions = hasEarlier
        } catch {
            logger.error("加载当前会话消息失败：\(error.localizedDescription)")
        }
    }

    /// 加载更早的会话，prepend 到 messages 前面。返回加载前首条消息的上一条消息 id（滚动锚点）
    func loadEarlierSessionLightweightMessagesAsync() async -> UUID? {
        guard let cursor = oldestLoadedTimestamp else { return nil }

        let anchorId = messages.first?.id

        do {
            // 查询 cursor 之前的一段消息
            let sessionIds: [UUID] = try await Task.detached(priority: .utility) {
                let context = CoreDataStack.shared.newBackgroundContext()
                return try await context.perform {
                    let request = NSFetchRequest<NSDictionary>(entityName: "ChatMessage")
                    request.resultType = .dictionaryResultType
                    request.propertiesToFetch = ["id", "timestamp"]
                    request.predicate = NSPredicate(format: "timestamp < %@", cursor as NSDate)
                    request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                    request.fetchLimit = 50

                    let rows = try context.fetch(request)
                    var ids: [UUID] = []
                    var prevTimestamp: Date?

                    for row in rows {
                        guard let id = row["id"] as? UUID,
                              let ts = row["timestamp"] as? Date else { continue }

                        if let prev = prevTimestamp, prev.timeIntervalSince(ts) > self.sessionGap {
                            break
                        }
                        ids.append(id)
                        prevTimestamp = ts
                    }
                    return ids
                }
            }.value

            guard !sessionIds.isEmpty else {
                hasEarlierSessions = false
                return anchorId
            }

            let newSnapshots: [ChatMessageViewData] = try await Task.detached(priority: .utility) {
                let context = CoreDataStack.shared.newBackgroundContext()
                return try await context.perform {
                    let request = NSFetchRequest<NSDictionary>(entityName: "ChatMessage")
                    request.resultType = .dictionaryResultType
                    request.propertiesToFetch = [
                        "id", "role", "content", "timestamp",
                        "intent", "extractedDataJSON", "isStreaming", "parentMessageId",
                        "analysisContextJSON"
                    ]
                    request.predicate = NSPredicate(format: "id IN %@", sessionIds)
                    request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

                    return try context.fetch(request)
                        .compactMap { ChatMessageViewData(lightweightDictionary: $0 as? [String: Any] ?? [:]) }
                }
            }.value

            // 去重
            let existingIds = Set(messages.map(\.id))
            let uniqueNew = newSnapshots.filter { !existingIds.contains($0.id) }

            guard !uniqueNew.isEmpty else {
                // 新查到的消息都已存在，更新 hasEarlierSessions
                if let newOldest = newSnapshots.first?.timestamp {
                    oldestLoadedTimestamp = newOldest
                }
                return anchorId
            }

            let scrollTargetId = uniqueNew.last?.id ?? anchorId
            messages = uniqueNew + messages
            oldestLoadedTimestamp = uniqueNew.first?.timestamp

            // 检查是否还有更早的消息
            let newEarliest = uniqueNew.first?.timestamp
            let hasEarlier = try await Task.detached(priority: .utility) {
                let context = CoreDataStack.shared.newBackgroundContext()
                return try await context.perform {
                    let countRequest = NSFetchRequest<NSNumber>(entityName: "ChatMessage")
                    countRequest.resultType = .countResultType
                    if let earliest = newEarliest {
                        countRequest.predicate = NSPredicate(format: "timestamp < %@", earliest as NSDate)
                    }
                    let result = try context.fetch(countRequest)
                    return (result.first?.intValue ?? 0) > 0
                }
            }.value
            hasEarlierSessions = hasEarlier

            return scrollTargetId
        } catch {
            logger.error("加载更早会话失败：\(error.localizedDescription)")
            return anchorId
        }
    }
    func loadRecentMessages(limit: Int = 50) -> [ChatMessageViewData] {
        Array(messages.suffix(limit))
    }

    /// 从数据库独立查询最近 N 条消息的 DTO，不依赖内存 messages 数组
    /// 用于 AI 上下文构建，UI 列表只加载当前会话时仍可获取全局历史
    func loadRecentDTOsAsync(limit: Int = 20) async -> [ChatMessageDTO] {
        await CoreDataStack.shared.waitUntilReady()

        do {
            return try await Task.detached(priority: .utility) {
                let context = CoreDataStack.shared.newBackgroundContext()
                return try await context.perform {
                    let request = NSFetchRequest<NSDictionary>(entityName: "ChatMessage")
                    request.resultType = .dictionaryResultType
                    request.propertiesToFetch = ["role", "content"]
                    request.predicate = NSPredicate(format: "role IN %@", ["user", "assistant"])
                    request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                    request.fetchLimit = limit

                    let dicts = try context.fetch(request)
                    return dicts.reversed().compactMap { dict -> ChatMessageDTO? in
                        guard let role = dict["role"] as? String,
                              let content = dict["content"] as? String else { return nil }
                        switch role {
                        case "user": return .user(content)
                        case "assistant": return .assistant(content)
                        default: return nil
                        }
                    }
                }
            }.value
        } catch {
            logger.error("后台加载历史 DTO 失败：\(error.localizedDescription)")
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
        executionBatchJSON: String?,
        analysisContextJSON: String? = nil,
        rawLogJSON: String? = nil
    ) {
        guard let message = liveMessageCache[messageId] else { return }

        // Core Data 写入（单次 save）
        message.content = finalContent
        message.isStreaming = false
        message.intent = intent
        message.extractedDataJSON = extractedDataJSON
        message.parsedBatchJSON = parsedBatchJSON
        message.executionBatchJSON = executionBatchJSON
        message.analysisContextJSON = analysisContextJSON
        message.rawLogJSON = rawLogJSON
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

        // 解码分析上下文
        let decodedAnalysisContext: AnalysisContext? = analysisContextJSON.flatMap { json in
            guard let data = json.data(using: .utf8) else { return nil }
            do {
                return try JSONDecoder().decode(AnalysisContext.self, from: data)
            } catch {
                logger.error("解析 analysisContextJSON 失败：\(error.localizedDescription)")
                return nil
            }
        }

        // 解码 LLM 日志
        let decodedRawLog: LLMLog? = rawLogJSON.flatMap { json in
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(LLMLog.self, from: data)
        }

        // 单次 snapshot 更新
        updateSnapshot(messageId) { snapshot in
            snapshot.content = finalContent
            snapshot.isStreaming = false
            snapshot.intent = intent
            snapshot.extractedDataJSON = extractedDataJSON
            snapshot.parsedBatch = decodedParsedBatch
            snapshot.executionBatch = decodedExecutionBatch
            snapshot.analysisContext = decodedAnalysisContext
            snapshot.rawLog = decodedRawLog
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

    /// 分析查询：立即设置 intent + analysisContext，保持 isStreaming 状态
    /// 用于在流式生成前渲染 loading 卡片，避免用户看到大段原始文字
    func setAnalysisLoadingState(
        _ messageId: UUID,
        intent: String?,
        analysisContext: AnalysisContext?
    ) {
        updateSnapshot(messageId) { snapshot in
            snapshot.intent = intent
            snapshot.analysisContext = analysisContext
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

    // MARK: - Metadata Lazy Load

    /// 批量加载消息的重元数据（卡片、日志等），只处理 .unloaded 状态的消息
    func loadMetadataForMessagesIfNeeded(_ ids: [UUID]) async {
        // 主线程过滤出需要加载的消息
        let toLoad = ids.filter { id in
            guard let msg = messages.first(where: { $0.id == id }) else { return false }
            return msg.metadataState == .unloaded
        }
        guard !toLoad.isEmpty else { return }

        // 先标记为 .loading 防止重复触发
        for id in toLoad {
            updateSnapshot(id) { snapshot in
                snapshot.metadataState = .loading
            }
        }

        // 后台批量查询重 JSON 字段
        do {
            let decoded: [(UUID, AIParseBatch?, AIExecutionBatch?, AnalysisContext?, LLMLog?)] = try await Task.detached(priority: .utility) {
                let context = CoreDataStack.shared.newBackgroundContext()
                return try await context.perform {
                    let request = NSFetchRequest<NSDictionary>(entityName: "ChatMessage")
                    request.resultType = .dictionaryResultType
                    request.propertiesToFetch = [
                        "id",
                        "parsedBatchJSON",
                        "executionBatchJSON",
                        "analysisContextJSON",
                        "rawLogJSON"
                    ]
                    request.predicate = NSPredicate(format: "id IN %@", toLoad)

                    return try context.fetch(request).compactMap { dict -> (UUID, AIParseBatch?, AIExecutionBatch?, AnalysisContext?, LLMLog?)? in
                        guard let id = dict["id"] as? UUID else { return nil }
                        let parsedBatch = ChatMessageViewData.decodeParseBatch(dict["parsedBatchJSON"] as? String)
                        let executionBatch = ChatMessageViewData.decodeExecutionBatch(dict["executionBatchJSON"] as? String)
                        let analysisContext = ChatMessageViewData.decodeAnalysisContext(dict["analysisContextJSON"] as? String)
                        let rawLog = ChatMessageViewData.decodeRawLog(dict["rawLogJSON"] as? String)
                        return (id, parsedBatch, executionBatch, analysisContext, rawLog)
                    }
                }
            }.value

            // 回到主线程更新 snapshot
            for (id, parsedBatch, executionBatch, analysisContext, rawLog) in decoded {
                updateSnapshot(id) { snapshot in
                    snapshot.enrichMetadata(
                        parsedBatch: parsedBatch,
                        executionBatch: executionBatch,
                        analysisContext: analysisContext,
                        rawLog: rawLog
                    )
                }
            }
        } catch {
            logger.error("批量加载元数据失败：\(error.localizedDescription)")
            // 失败时恢复为 unloaded，允许重试
            for id in toLoad {
                updateSnapshot(id) { snapshot in
                    if snapshot.metadataState == .loading {
                        snapshot.metadataState = .unloaded
                    }
                }
            }
        }
    }

    // MARK: - Private

    private func updateSnapshot(_ messageId: UUID, mutate: (inout ChatMessageViewData) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        var snapshot = messages[index]
        mutate(&snapshot)
        snapshot.recomputeLinkedEntityIds()
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
