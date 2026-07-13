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
                        "agentResultJSON",
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
                        "analysisContextJSON",
                        "agentResultJSON",
                        "executionBatchJSON",
                        "rawLogJSON"
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
                        "analysisContextJSON", "agentResultJSON", "executionBatchJSON", "rawLogJSON"
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
                        "analysisContextJSON", "agentResultJSON", "executionBatchJSON", "rawLogJSON"
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
                    request.propertiesToFetch = ["role", "content", "isStreaming"]
                    request.predicate = NSPredicate(format: "role IN %@ AND isStreaming == NO", ["user", "assistant"])
                    request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                    request.fetchLimit = limit

                    let dicts = try context.fetch(request)
                    return dicts.reversed().compactMap { dict -> ChatMessageDTO? in
                        guard let role = dict["role"] as? String,
                              let content = dict["content"] as? String,
                              !content.isEmpty else { return nil }
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
        parentMessageId: UUID? = nil,
        messageType: ChatMessageType = .normal
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
        message.messageType = messageType.rawValue

        save()

        liveMessageCache[message.id] = message
        messages.append(ChatMessageViewData(message: message))
        return message.id
    }

    /// 添加流式占位消息
    @discardableResult
    func addStreamingMessage(role: String, parentMessageId: UUID? = nil, messageType: ChatMessageType = .normal) -> UUID {
        let message = ChatMessage(context: context)
        message.id = UUID()
        message.role = role
        message.content = ""
        message.timestamp = Date()
        message.isStreaming = true
        message.parentMessageId = parentMessageId
        message.messageType = messageType.rawValue

        save()

        liveMessageCache[message.id] = message
        messages.append(ChatMessageViewData(message: message))
        return message.id
    }

    // MARK: - Update

    private func messageForUpdate(_ messageId: UUID) -> ChatMessage? {
        if let message = liveMessageCache[messageId] {
            return message
        }

        let request = ChatMessage.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", messageId as CVarArg)
        request.fetchLimit = 1

        guard let message = try? context.fetch(request).first else {
            return nil
        }

        liveMessageCache[messageId] = message
        return message
    }

    /// 更新消息内容
    func updateMessage(_ messageId: UUID, content: String) {
        guard let message = messageForUpdate(messageId) else { return }
        message.content = content
        save()
        updateSnapshot(messageId) { snapshot in
            snapshot.content = content
        }
    }

    /// 结束流式状态
    func finishStreaming(_ messageId: UUID, finalContent: String) {
        guard let message = messageForUpdate(messageId) else { return }
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
        rawLogJSON: String? = nil,
        agentResultJSON: String? = nil
    ) {
        guard let message = messageForUpdate(messageId) else { return }

        // Core Data 写入（单次 save）
        message.content = finalContent
        message.isStreaming = false
        message.intent = intent
        message.extractedDataJSON = extractedDataJSON
        message.parsedBatchJSON = parsedBatchJSON
        message.executionBatchJSON = executionBatchJSON
        message.analysisContextJSON = analysisContextJSON
        // 原始 LLM 日志不得进入 Core Data / CloudKit；内部日志使用独立本机仓库。
        message.rawLogJSON = nil
        message.agentResultJSON = agentResultJSON
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

        // 解码 Agent 结果
        let decodedAgentResult: HoloRenderedAgentResult? = agentResultJSON.flatMap { json in
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(HoloRenderedAgentResult.self, from: data)
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
            snapshot.rawLog = nil
            snapshot.agentResult = decodedAgentResult
            // finalizeMessage 已收到并解析完整元数据，当前快照可立即渲染结构化卡片。
            snapshot.metadataState = .loaded
        }
    }

    /// Agent 恢复回填：按 message id 结束原 streaming 消息，并写入结构化 Agent 结果。
    func finalizeAgentMessage(_ messageId: UUID,
                              rendered: HoloRenderedAgentResult,
                              intent: String? = "query_analysis") {
        let fallbackText = [rendered.title, rendered.summary]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let agentResultJSON: String?
        if let data = try? JSONEncoder().encode(rendered) {
            agentResultJSON = String(data: data, encoding: .utf8)
        } else {
            agentResultJSON = nil
        }

        let message: ChatMessage?
        if let cached = liveMessageCache[messageId] {
            message = cached
        } else {
            let request = ChatMessage.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", messageId as CVarArg)
            request.fetchLimit = 1
            message = try? context.fetch(request).first
        }
        guard let message else { return }

        liveMessageCache[messageId] = message
        message.content = fallbackText
        message.isStreaming = false
        message.intent = intent
        message.agentResultJSON = agentResultJSON
        save()

        updateSnapshot(messageId) { snapshot in
            snapshot.content = fallbackText
            snapshot.isStreaming = false
            snapshot.intent = intent
            snapshot.agentResult = rendered
            snapshot.metadataState = .loaded
        }
    }

    /// Agent 进度同步：用持久化 job 的真实状态更新原 streaming 消息。
    func updateAgentMessageProgress(_ messageId: UUID, status: HoloAgentChatStatus) {
        let message: ChatMessage?
        if let cached = liveMessageCache[messageId] {
            message = cached
        } else {
            let request = ChatMessage.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", messageId as CVarArg)
            request.fetchLimit = 1
            message = try? context.fetch(request).first
        }
        guard let message else { return }

        liveMessageCache[messageId] = message
        message.content = status.messageContent
        message.isStreaming = status.keepsMessageStreaming
        message.intent = "query_analysis"
        if !status.keepsMessageStreaming {
            message.agentResultJSON = nil
        }
        save()

        updateSnapshot(messageId) { snapshot in
            snapshot.content = status.messageContent
            snapshot.isStreaming = status.keepsMessageStreaming
            snapshot.intent = "query_analysis"
            if !status.keepsMessageStreaming {
                snapshot.agentResult = nil
                snapshot.metadataState = .loaded
            }
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
        guard let message = messageForUpdate(messageId) else { return }
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
        if let message = liveMessageCache[messageId] {
            message.intent = intent
            if let analysisContext,
               let data = try? JSONEncoder().encode(analysisContext) {
                message.analysisContextJSON = String(data: data, encoding: .utf8)
            }
            save()
        }
        updateSnapshot(messageId) { snapshot in
            snapshot.intent = intent
            snapshot.analysisContext = analysisContext
        }
    }

    // MARK: - Transaction Card Refresh

    /// 刷新交易卡片显示数据（用户编辑交易后调用）
    /// 同步 Core Data 中的 executionBatchJSON + extractedDataJSON，并刷新内存快照
    func refreshTransactionCard(transactionId: UUID) {
        // 1. 找到关联此交易的消息
        guard let messageIndex = messages.firstIndex(where: { msg in
            msg.resolveLinkedEntityId(for: .finance) == transactionId
        }) else { return }

        let messageId = messages[messageIndex].id

        // 2. 获取更新后的交易
        guard let transaction = FinanceRepository.shared.findTransaction(by: transactionId),
              let category = transaction.category else { return }

        let (primaryCategory, subCategory) = FinanceRepository.shared.resolveCategoryNames(from: category)

        // 同步金额、类型、日期
        let updatedAmount = transaction.amount.stringValue
        let updatedType = transaction.type // "expense" / "income"
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "M月d日"
        let updatedDate = dateFormatter.string(from: transaction.date)

        // 3. 从 Core Data 读取 ChatMessage
        let request = ChatMessage.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", messageId as CVarArg)
        request.fetchLimit = 1
        guard let message = try? context.fetch(request).first else { return }

        var updatedBatch: AIExecutionBatch?
        var updatedExtractedJSON: String?

        // 4. 更新 executionBatchJSON（新路径）
        if let batchJSON = message.executionBatchJSON,
           let batchData = batchJSON.data(using: .utf8),
           let batch = try? JSONDecoder().decode(AIExecutionBatch.self, from: batchData) {
            let txIdStr = transactionId.uuidString
            let newItems = batch.items.map { item in
                guard item.linkedEntityId == txIdStr else { return item }
                var rd = item.renderData ?? [:]
                rd["amount"] = updatedAmount
                rd["type"] = updatedType
                rd["date"] = updatedDate
                rd["primaryCategory"] = primaryCategory
                if let sub = subCategory { rd["subCategory"] = sub } else { rd.removeValue(forKey: "subCategory") }
                if let note = transaction.note, !note.isEmpty { rd["note"] = note } else { rd.removeValue(forKey: "note") }
                return AIExecutionItem(
                    id: item.id, parseItemId: item.parseItemId, intent: item.intent,
                    status: item.status, summaryText: item.summaryText, renderData: rd,
                    linkedEntityType: item.linkedEntityType, linkedEntityId: item.linkedEntityId,
                    errorText: item.errorText
                )
            }
            let newBatch = AIExecutionBatch(mode: batch.mode, items: newItems, finalText: batch.finalText)
            updatedBatch = newBatch
            if let data = try? JSONEncoder().encode(newBatch),
               let str = String(data: data, encoding: .utf8) {
                message.executionBatchJSON = str
            }
        }

        // 5. 更新 extractedDataJSON（旧路径兜底）
        if let json = message.extractedDataJSON,
           let data = json.data(using: .utf8),
           var dict = try? JSONDecoder().decode([String: String].self, from: data) {
            dict["amount"] = updatedAmount
            dict["type"] = updatedType
            dict["date"] = updatedDate
            dict["primaryCategory"] = primaryCategory
            if let sub = subCategory { dict["subCategory"] = sub } else { dict.removeValue(forKey: "subCategory") }
            if let note = transaction.note, !note.isEmpty { dict["note"] = note } else { dict.removeValue(forKey: "note") }
            if let data = try? JSONEncoder().encode(dict),
               let str = String(data: data, encoding: .utf8) {
                message.extractedDataJSON = str
                updatedExtractedJSON = str
            }
        }

        save()

        // 6. 单次 snapshot 更新
        updateSnapshot(messageId) { snapshot in
            if let batch = updatedBatch { snapshot.executionBatch = batch }
            if let json = updatedExtractedJSON { snapshot.extractedDataJSON = json }
        }
    }

    // MARK: - Delete

    /// 删除单条消息
    func deleteMessage(_ messageId: UUID) {
        guard let message = messageForUpdate(messageId) else { return }
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
            let decoded: [(UUID, AIParseBatch?, AIExecutionBatch?, AnalysisContext?, LLMLog?, HoloRenderedAgentResult?)] = try await Task.detached(priority: .utility) {
                let context = CoreDataStack.shared.newBackgroundContext()
                return try await context.perform {
                    let request = NSFetchRequest<NSDictionary>(entityName: "ChatMessage")
                    request.resultType = .dictionaryResultType
                    request.propertiesToFetch = [
                        "id",
                        "parsedBatchJSON",
                        "executionBatchJSON",
                        "analysisContextJSON",
                        "rawLogJSON",
                        "agentResultJSON"
                    ]
                    request.predicate = NSPredicate(format: "id IN %@", toLoad)

                    return try context.fetch(request).compactMap { dict -> (UUID, AIParseBatch?, AIExecutionBatch?, AnalysisContext?, LLMLog?, HoloRenderedAgentResult?)? in
                        guard let id = dict["id"] as? UUID else { return nil }
                        let parsedBatch = ChatMessageViewData.decodeParseBatch(dict["parsedBatchJSON"] as? String)
                        let executionBatch = ChatMessageViewData.decodeExecutionBatch(dict["executionBatchJSON"] as? String)
                        let analysisContext = ChatMessageViewData.decodeAnalysisContext(dict["analysisContextJSON"] as? String)
                        let rawLog = ChatMessageViewData.decodeRawLog(dict["rawLogJSON"] as? String)
                        let agentResult = ChatMessageViewData.decodeAgentResult(dict["agentResultJSON"] as? String)
                        return (id, parsedBatch, executionBatch, analysisContext, rawLog, agentResult)
                    }
                }
            }.value

            // 回到主线程更新 snapshot
            for (id, parsedBatch, executionBatch, analysisContext, rawLog, agentResult) in decoded {
                updateSnapshot(id) { snapshot in
                    snapshot.enrichMetadata(
                        parsedBatch: parsedBatch,
                        executionBatch: executionBatch,
                        analysisContext: analysisContext,
                        rawLog: rawLog,
                        agentResult: agentResult
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

    // MARK: - Orphan Cleanup

    /// 孤儿清理宽限期，对齐 Agent normalDeep budget 上限（maxWallTimeSeconds 120s）+ 安全余量。
    /// 宽限期内即使消息仍 isStreaming 也保留，避免误杀「刚启动、job 尚未落盘」的 Agent 深度分析消息。
    private static let orphanCleanupGraceInterval: TimeInterval = 180

    /// 清理残留的 isStreaming 消息（app 启动 / 页面进入时调用）。
    ///
    /// 这些消息通常是异常残留（app 在 streaming 期间被杀或崩溃）；但刚启动的 Agent 深度分析消息
    /// 受 `orphanCleanupGraceInterval` 宽限期保护——其 job 在 Coordinator 意图识别（LLM，数秒）后才落盘，
    /// 此刻 `syncRecoverableChatMessages` 可能读不到关联 job，导致该消息不在 preserve 集合。
    /// 若立即清理，正在后台跑的 Agent 会被误判为「中断」。宽限期内跳过，留给 job 落盘与 runLoop 推进。
    ///
    /// - Parameter now: 当前时间，默认 `Date()`；测试可注入以模拟「近期 / 超期」场景。
    func cleanupOrphanedStreamingMessages(preserveMessageIDs: Set<UUID> = [], now: Date = Date()) {
        let request = ChatMessage.fetchRequest()
        request.predicate = NSPredicate(format: "isStreaming == YES")

        do {
            let orphans = try context.fetch(request)
            guard !orphans.isEmpty else { return }

            // 仅清理：未 preserve 且已过宽限期的消息（真孤儿）。
            let cleanable = orphans.filter { message in
                !preserveMessageIDs.contains(message.id)
                && now.timeIntervalSince(message.timestamp) >= Self.orphanCleanupGraceInterval
            }
            guard !cleanable.isEmpty else {
                logger.info("孤儿 streaming 清理：命中 \(orphans.count) 条，均已 preserve 或在宽限期内，跳过")
                return
            }

            for message in cleanable {
                message.isStreaming = false
                if message.content.isEmpty {
                    message.content = "抱歉，处理时意外中断了"
                }
            }
            save()

            // 同步刷新内存中的 snapshot（仅实际被清理的消息，避免误碰宽限期内消息）
            for orphan in cleanable {
                liveMessageCache[orphan.id] = orphan
                updateSnapshot(orphan.id) { snapshot in
                    snapshot.isStreaming = false
                    if snapshot.content.isEmpty {
                        snapshot.content = "抱歉，处理时意外中断了"
                    }
                }
            }

            logger.info("孤儿 streaming 清理：命中 \(orphans.count) 条，清理 \(cleanable.count)，其余 preserve 或宽限期内保留")
        } catch {
            logger.error("清理残留 streaming 消息失败：\(error.localizedDescription)")
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
