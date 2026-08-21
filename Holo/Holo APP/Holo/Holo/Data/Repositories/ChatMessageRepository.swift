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
                        "insightResultJSON",
                        "messageType",
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
        prefillDeletionStates()
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
                        "insightResultJSON",
                        "messageType",
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
        prefillDeletionStates()
    }

    /// 加载当前会话的轻量消息：从最新消息向前扫描，遇到 4 小时间隔则截断
    func loadCurrentSessionLightweightMessagesAsync(limit: Int = 50) async {
        await CoreDataStack.shared.waitUntilReady()

        do {
            // 单次查询：按时间倒序取 limit+1 条轻量字段，多取 1 条用于判断是否还有更早消息。
            // 会话边界（4h gap）截断在内存里完成，避免原先的 3 次串行往返。
            let (sessionSnapshots, hasEarlier) = try await Task.detached(priority: .utility) {
                let context = CoreDataStack.shared.newBackgroundContext()
                return try await context.perform {
                    let request = NSFetchRequest<NSDictionary>(entityName: "ChatMessage")
                    request.resultType = .dictionaryResultType
                    request.propertiesToFetch = [
                        "id", "role", "content", "timestamp",
                        "intent", "extractedDataJSON", "isStreaming", "parentMessageId",
                        "messageType", "analysisContextJSON", "agentResultJSON",
                        "insightResultJSON", "executionBatchJSON", "rawLogJSON"
                    ]
                    request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                    request.fetchLimit = limit + 1

                    let rows = try context.fetch(request)
                    var sessionRows: [[String: Any]] = []
                    var prevTimestamp: Date?
                    var hitGap = false

                    for row in rows {
                        guard let dict = row as? [String: Any],
                              let ts = dict["timestamp"] as? Date else { continue }
                        if let prev = prevTimestamp, prev.timeIntervalSince(ts) > self.sessionGap {
                            hitGap = true
                            break
                        }
                        sessionRows.append(dict)
                        prevTimestamp = ts
                    }
                    // 取满 limit+1 条且未被 gap 截断，说明还有更早消息；否则 hasEarlier 以是否触及 gap 为准
                    let hasEarlier = hitGap || rows.count > sessionRows.count

                    let snapshots = sessionRows
                        .compactMap { ChatMessageViewData(lightweightDictionary: $0) }
                        .sorted { $0.timestamp < $1.timestamp } // 恢复正序（旧→新）
                    return (snapshots, hasEarlier)
                }
            }.value

            guard !sessionSnapshots.isEmpty else {
                liveMessageCache.removeAll()
                messages = []
                hasEarlierSessions = false
                return
            }

            liveMessageCache.removeAll()
            messages = sessionSnapshots
            oldestLoadedTimestamp = sessionSnapshots.first?.timestamp
            hasEarlierSessions = hasEarlier
            prefillDeletionStates()
        } catch {
            logger.error("加载当前会话消息失败：\(error.localizedDescription)")
        }
    }

    /// 加载更早的一页消息并 prepend 到 messages 前面。
    /// 每页只取 16 条，配合顶部预取形成连续滚动，避免一次插入 30 条复杂卡片造成掉帧。
    /// 具体视口位置由 ChatScrollController 按真实 contentSize 增量保持。
    func loadEarlierSessionLightweightMessagesAsync(
        limit: Int = 16
    ) async -> ChatHistoryPageResult {
        guard let cursor = oldestLoadedTimestamp else {
            hasEarlierSessions = false
            return .loaded(0, hasEarlierMessages: false)
        }

        let fetchBatch = max(1, min(limit, 24))

        do {
            // 查询 cursor 之前最近一小页（跨会话，不截断）
            let sessionIds: [UUID] = try await Task.detached(priority: .utility) {
                let context = CoreDataStack.shared.newBackgroundContext()
                return try await context.perform {
                    let request = NSFetchRequest<NSDictionary>(entityName: "ChatMessage")
                    request.resultType = .dictionaryResultType
                    request.propertiesToFetch = ["id", "timestamp"]
                    request.predicate = NSPredicate(format: "timestamp < %@", cursor as NSDate)
                    request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                    request.fetchLimit = fetchBatch

                    let rows = try context.fetch(request)
                    return rows.compactMap { $0["id"] as? UUID }
                }
            }.value

            guard !sessionIds.isEmpty else {
                hasEarlierSessions = false
                return .loaded(0, hasEarlierMessages: false)
            }

            let newSnapshots: [ChatMessageViewData] = try await Task.detached(priority: .utility) {
                let context = CoreDataStack.shared.newBackgroundContext()
                return try await context.perform {
                    let request = NSFetchRequest<NSDictionary>(entityName: "ChatMessage")
                    request.resultType = .dictionaryResultType
                    request.propertiesToFetch = [
                        "id", "role", "content", "timestamp",
                        "intent", "extractedDataJSON", "isStreaming", "parentMessageId",
                        "messageType", "analysisContextJSON", "agentResultJSON",
                        "insightResultJSON", "executionBatchJSON", "rawLogJSON"
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
                return .loaded(0, hasEarlierMessages: hasEarlierSessions)
            }

            messages = uniqueNew + messages
            oldestLoadedTimestamp = uniqueNew.first?.timestamp
            prefillDeletionStates(for: uniqueNew.map(\.id))

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

            return .loaded(
                uniqueNew.count,
                hasEarlierMessages: hasEarlier
            )
        } catch {
            logger.error("加载更早会话失败：\(error.localizedDescription)")
            return .failed(hasEarlierMessages: hasEarlierSessions)
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
    func addStreamingMessage(
        role: String,
        parentMessageId: UUID? = nil,
        messageType: ChatMessageType = .normal,
        extractedDataJSON: String? = nil
    ) -> UUID {
        let message = ChatMessage(context: context)
        message.id = UUID()
        message.role = role
        message.content = ""
        message.timestamp = Date()
        message.isStreaming = true
        message.parentMessageId = parentMessageId
        message.messageType = messageType.rawValue
        message.extractedDataJSON = extractedDataJSON

        save()

        liveMessageCache[message.id] = message
        messages.append(ChatMessageViewData(message: message))
        return message.id
    }

    /// 更新周期回放任务状态。任务状态和聊天消息共用一次持久化，
    /// 这样 App 被系统结束后仍能从原消息恢复，不会另起一条重复回放。
    func updatePeriodReplayJob(
        _ messageId: UUID,
        job: HoloPeriodReplayJob,
        content: String? = nil,
        isStreaming: Bool? = nil
    ) {
        guard let message = messageForUpdate(messageId) else { return }
        let jobJSON = job.json
        message.extractedDataJSON = jobJSON
        if let content {
            message.content = content
        }
        if let isStreaming {
            message.isStreaming = isStreaming
        }
        save()

        updateSnapshot(messageId) { snapshot in
            snapshot.setExtractedDataJSON(jobJSON)
            if let content {
                snapshot.content = content
            }
            if let isStreaming {
                snapshot.isStreaming = isStreaming
            }
        }
    }

    /// 查询所有仍可恢复的周期回放消息，供冷启动保护与续跑。
    func recoverablePeriodReplayJobs() -> [(messageId: UUID, job: HoloPeriodReplayJob)] {
        let request = ChatMessage.fetchRequest()
        request.predicate = NSPredicate(
            format: "messageType == %@",
            ChatMessageType.periodReplay.rawValue
        )
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        let messages = (try? context.fetch(request)) ?? []
        return messages.compactMap { message in
            guard let job = HoloPeriodReplayJob(json: message.extractedDataJSON),
                  job.state.isRecoverable else {
                return nil
            }
            return (message.id, job)
        }
    }

    /// 找到同一周期尚未结束的回放，避免重复点击创建多条任务。
    func recoverablePeriodReplayJob(
        periodType: MemoryInsightPeriodType,
        start: Date,
        end: Date
    ) -> (messageId: UUID, job: HoloPeriodReplayJob)? {
        recoverablePeriodReplayJobs().last { record in
            record.job.periodType == periodType
                && abs(record.job.periodStart.timeIntervalSince(start)) < 1
                && abs(record.job.periodEnd.timeIntervalSince(end)) < 1
        }
    }

    func periodReplayJob(messageId: UUID) -> HoloPeriodReplayJob? {
        guard let message = messageForUpdate(messageId) else { return nil }
        return HoloPeriodReplayJob(json: message.extractedDataJSON)
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

    /// 查询单条消息的类型；不存在返回 nil。
    /// 供回前台恢复逻辑判断消息是否已是额度卡片，避免被普通进度文案覆盖。
    func messageType(for messageId: UUID) -> ChatMessageType? {
        guard let message = messageForUpdate(messageId) else { return nil }
        return ChatMessageType(rawValue: message.messageType)
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
    /// messageType 非 nil 时一并写入（如 .userCancelled），作为持久标记供 Agent 状态同步识别。
    func finishStreaming(
        _ messageId: UUID,
        finalContent: String,
        messageType: ChatMessageType? = nil
    ) {
        guard let message = messageForUpdate(messageId) else { return }
        message.content = finalContent
        message.isStreaming = false
        if let messageType {
            message.messageType = messageType.rawValue
        }
        save()
        updateSnapshot(messageId) { snapshot in
            snapshot.content = finalContent
            snapshot.isStreaming = false
            if let messageType {
                snapshot.messageType = messageType
            }
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
        agentResultJSON: String? = nil,
        insightResultJSON: String? = nil,
        messageType: ChatMessageType? = nil
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
        message.insightResultJSON = insightResultJSON
        if let messageType {
            message.messageType = messageType.rawValue
        }
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
        let decodedInsightResult = ChatMessageViewData.decodeInsightResult(insightResultJSON)

        // 单次 snapshot 更新
        updateSnapshot(messageId) { snapshot in
            snapshot.content = finalContent
            snapshot.isStreaming = false
            snapshot.intent = intent
            snapshot.setExtractedDataJSON(extractedDataJSON)
            snapshot.parsedBatch = decodedParsedBatch
            snapshot.executionBatch = decodedExecutionBatch
            snapshot.analysisContext = decodedAnalysisContext
            snapshot.rawLog = nil
            snapshot.agentResult = decodedAgentResult
            snapshot.insightResult = decodedInsightResult
            if let messageType {
                snapshot.messageType = messageType
            }
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
        // 1. 找到关联此交易的消息（多卡消息按全量 ID 匹配，消息级缓存只有最后一个）
        guard let messageIndex = messages.firstIndex(where: { msg in
            msg.allLinkedEntityIds(for: .finance).contains(transactionId)
        }) else { return }

        let messageId = messages[messageIndex].id

        // 2. 获取更新后的交易
        guard let transaction = FinanceRepository.shared.findTransaction(by: transactionId),
              let category = transaction.category else { return }

        let (primaryCategory, subCategory) = FinanceRepository.shared.resolveCategoryNames(from: category)

        // 同步金额、类型、日期。
        // 日期必须写 NLDateParser 可回解的标准格式（yyyy-MM-dd HH:mm）：
        // "M月d日" 无年份回解失败，卡片会整行丢日期显示
        let updatedAmount = transaction.amount.stringValue
        let updatedType = transaction.type // "expense" / "income"
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
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

    /// 刷新任务卡片显示数据（任务在任务页被改名/改期后调用），与 refreshTransactionCard 对称
    func refreshTaskCard(taskId: UUID) {
        guard let messageIndex = messages.firstIndex(where: { msg in
            msg.allLinkedEntityIds(for: .task).contains(taskId)
        }) else { return }

        let messageId = messages[messageIndex].id
        guard let task = TodoRepository.shared.findTask(by: taskId) else { return }

        let titleText = task.title
        let dueDateText = Self.taskCardDateText(task.dueDate, isAllDay: task.isAllDay)

        let request = ChatMessage.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", messageId as CVarArg)
        request.fetchLimit = 1
        guard let message = try? context.fetch(request).first else { return }

        var updatedBatch: AIExecutionBatch?
        var updatedExtractedJSON: String?

        if let batchJSON = message.executionBatchJSON,
           let batchData = batchJSON.data(using: .utf8),
           let batch = try? JSONDecoder().decode(AIExecutionBatch.self, from: batchData) {
            let taskIdStr = taskId.uuidString
            let newItems = batch.items.map { item in
                guard item.linkedEntityId == taskIdStr else { return item }
                var rd = item.renderData ?? [:]
                rd["title"] = titleText
                if let dueDateText { rd["dueDate"] = dueDateText } else { rd.removeValue(forKey: "dueDate") }
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

        if let json = message.extractedDataJSON,
           let data = json.data(using: .utf8),
           var dict = try? JSONDecoder().decode([String: String].self, from: data),
           dict["taskId"] == taskId.uuidString || dict["entityId"] == taskId.uuidString {
            dict["title"] = titleText
            if let dueDateText { dict["dueDate"] = dueDateText } else { dict.removeValue(forKey: "dueDate") }
            if let data = try? JSONEncoder().encode(dict),
               let str = String(data: data, encoding: .utf8) {
                message.extractedDataJSON = str
                updatedExtractedJSON = str
            }
        }

        save()

        updateSnapshot(messageId) { snapshot in
            if let batch = updatedBatch { snapshot.executionBatch = batch }
            if let json = updatedExtractedJSON { snapshot.extractedDataJSON = json }
        }
    }

    /// 任务卡日期文本：全天任务「M月d日」，含时间任务「M月d日 HH:mm」；无日期返回 nil
    private static func taskCardDateText(_ date: Date?, isAllDay: Bool) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = isAllDay ? "M月d日" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    /// 启动对账：确认路由执行期间 App 被杀，消息会停留在 confirming 中间态。
    /// 依据实体上的 AI 来源标记判断上次是否已落库：
    /// 已建实体 → 补 confirmed + 实体 ID（不重复入账）；未建 → 回 pending 供用户重新确认。
    func reconcileInterruptedConfirmations() {
        for message in messages {
            guard let batch = message.executionBatch else { continue }
            guard batch.items.contains(where: { $0.renderData?["confirmationStatus"] == "confirming" }) else { continue }

            let messageId = message.id
            let request = ChatMessage.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", messageId as CVarArg)
            request.fetchLimit = 1
            guard let stored = try? context.fetch(request).first else { continue }

            var changed = false
            let newItems = batch.items.map { item -> AIExecutionItem in
                guard var rd = item.renderData,
                      rd["confirmationStatus"] == "confirming" else { return item }

                if let tx = FinanceRepository.shared.findTransactionByAISource(
                    messageId: messageId.uuidString, itemId: item.id) {
                    rd["confirmationStatus"] = "confirmed"
                    rd["entityType"] = "finance"
                    rd["entityId"] = tx.id.uuidString
                    rd["transactionId"] = tx.id.uuidString
                    changed = true
                    return AIExecutionItem(
                        id: item.id, parseItemId: item.parseItemId, intent: item.intent,
                        status: .success, summaryText: "已记录", renderData: rd,
                        linkedEntityType: "finance", linkedEntityId: tx.id.uuidString,
                        errorText: nil
                    )
                }

                if let task = TodoRepository.shared.findTaskByAISource(
                    messageId: messageId.uuidString, itemId: item.id) {
                    rd["confirmationStatus"] = "confirmed"
                    rd["taskId"] = task.id.uuidString
                    changed = true
                    return AIExecutionItem(
                        id: item.id, parseItemId: item.parseItemId, intent: item.intent,
                        status: .success, summaryText: "已创建任务", renderData: rd,
                        linkedEntityType: "task", linkedEntityId: task.id.uuidString,
                        errorText: nil
                    )
                }

                // 实体未建：上次路由没跑完，回待确认让用户重新点
                rd["confirmationStatus"] = "pending"
                changed = true
                return AIExecutionItem(
                    id: item.id, parseItemId: item.parseItemId, intent: item.intent,
                    status: item.status, summaryText: item.summaryText, renderData: rd,
                    linkedEntityType: item.linkedEntityType, linkedEntityId: item.linkedEntityId,
                    errorText: item.errorText
                )
            }

            guard changed else { continue }
            let newBatch = AIExecutionBatch(mode: batch.mode, items: newItems, finalText: batch.finalText)
            if let data = try? JSONEncoder().encode(newBatch),
               let str = String(data: data, encoding: .utf8) {
                stored.executionBatchJSON = str
            }
            save()
            updateSnapshot(messageId) { snapshot in
                snapshot.executionBatch = newBatch
            }
            logger.info("对账完成：消息 \(messageId.uuidString, privacy: .public) 的中断确认已恢复")
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

    /// 删除一份报告对应的对话消息（回答消息 + 它的提问气泡），并发布快照
    /// 驱动聊天页同步移除。报告 Tab 的档案列表由调用方先行移除（界面先清、库后删）。
    func deleteReportMessages(reportMessageID: UUID) {
        guard let message = messageForUpdate(reportMessageID) else { return }
        let parentID = message.parentMessageId

        var removedIDs: Set<UUID> = [reportMessageID]
        context.delete(message)
        liveMessageCache.removeValue(forKey: reportMessageID)

        if let parentID, let parent = messageForUpdate(parentID) {
            context.delete(parent)
            liveMessageCache.removeValue(forKey: parentID)
            removedIDs.insert(parentID)
        }

        save()
        messages.removeAll { removedIDs.contains($0.id) }
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
            let decoded: [(UUID, AIParseBatch?, AIExecutionBatch?, AnalysisContext?, LLMLog?, HoloRenderedAgentResult?, MemoryInsightPayload?)] = try await Task.detached(priority: .utility) {
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
                        "agentResultJSON",
                        "insightResultJSON"
                    ]
                    request.predicate = NSPredicate(format: "id IN %@", toLoad)

                    return try context.fetch(request).compactMap { dict -> (UUID, AIParseBatch?, AIExecutionBatch?, AnalysisContext?, LLMLog?, HoloRenderedAgentResult?, MemoryInsightPayload?)? in
                        guard let id = dict["id"] as? UUID else { return nil }
                        let parsedBatch = ChatMessageViewData.decodeParseBatch(dict["parsedBatchJSON"] as? String)
                        let executionBatch = ChatMessageViewData.decodeExecutionBatch(dict["executionBatchJSON"] as? String)
                        let analysisContext = ChatMessageViewData.decodeAnalysisContext(dict["analysisContextJSON"] as? String)
                        let rawLog = ChatMessageViewData.decodeRawLog(dict["rawLogJSON"] as? String)
                        let agentResult = ChatMessageViewData.decodeAgentResult(dict["agentResultJSON"] as? String)
                        let insightResult = ChatMessageViewData.decodeInsightResult(dict["insightResultJSON"] as? String)
                        return (id, parsedBatch, executionBatch, analysisContext, rawLog, agentResult, insightResult)
                    }
                }
            }.value

            // 回到主线程更新 snapshot
            for (id, parsedBatch, executionBatch, analysisContext, rawLog, agentResult, insightResult) in decoded {
                updateSnapshot(id) { snapshot in
                    snapshot.enrichMetadata(
                        parsedBatch: parsedBatch,
                        executionBatch: executionBatch,
                        analysisContext: analysisContext,
                        rawLog: rawLog,
                        agentResult: agentResult,
                        insightResult: insightResult
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
    private nonisolated static let orphanCleanupGraceInterval: TimeInterval = 180

    /// 清理残留的 isStreaming 消息（app 启动 / 页面进入时调用）。
    ///
    /// 这些消息通常是异常残留（app 在 streaming 期间被杀或崩溃）；但刚启动的 Agent 深度分析消息
    /// 受 `orphanCleanupGraceInterval` 宽限期保护——其 job 在 Coordinator 意图识别（LLM，数秒）后才落盘，
    /// 此刻 `syncRecoverableChatMessages` 可能读不到关联 job，导致该消息不在 preserve 集合。
    /// 若立即清理，正在后台跑的 Agent 会被误判为「中断」。宽限期内跳过，留给 job 落盘与 runLoop 推进。
    ///
    /// 实现上走后台 context 的 `perform`，避免首屏期间在主线程 viewContext 上 fetch 阻塞 UI；
    /// 写回完成后回到主线程同步内存 snapshot。
    ///
    /// - Parameter now: 当前时间，默认 `Date()`；测试可注入以模拟「近期 / 超期」场景。
    func cleanupOrphanedStreamingMessagesOffMain(preserveMessageIDs: Set<UUID> = [], now: Date = Date()) async {
        await CoreDataStack.shared.waitUntilReady()
        let cleanedIDs: [UUID] = await Task.detached(priority: .utility) {
            let context = CoreDataStack.shared.newBackgroundContext()
            return await context.perform {
                let request = ChatMessage.fetchRequest()
                request.predicate = NSPredicate(format: "isStreaming == YES")
                do {
                    let orphans = try context.fetch(request)
                    let cleanable = orphans.filter { message in
                        !preserveMessageIDs.contains(message.id)
                            && now.timeIntervalSince(message.timestamp) >= Self.orphanCleanupGraceInterval
                    }
                    guard !cleanable.isEmpty else { return [] }
                    var ids: [UUID] = []
                    for message in cleanable {
                        message.isStreaming = false
                        if message.content.isEmpty {
                            message.content = "抱歉，处理时意外中断了"
                        }
                        ids.append(message.id)
                    }
                    try? context.save()
                    return ids
                } catch {
                    return []
                }
            }
        }.value

        guard !cleanedIDs.isEmpty else { return }
        // 写回已完成，回到主线程更新内存 snapshot
        let cleanedSet = Set(cleanedIDs)
        for id in cleanedSet {
            updateSnapshot(id) { snapshot in
                snapshot.isStreaming = false
                if snapshot.content.isEmpty {
                    snapshot.content = "抱歉，处理时意外中断了"
                }
            }
        }
        logger.info("孤儿 streaming 清理（后台）：清理 \(cleanedIDs.count) 条")
    }

    // MARK: - Deletion State Prefill

    /// 批量预填消息卡片的删除态缓存。
    /// 收集当前消息里关联的 finance / task 实体 ID，用 2 次查询（不存在的 Transaction、软删除的 TodoTask）
    /// 一次性算好哪些卡片对应的实体已被删除，回填到各 snapshot，避免渲染期逐条查 Core Data。
    func prefillDeletionStates(for snapshots: [UUID]? = nil) {
        let idFilter = snapshots.map(Set.init)
        var financeIDs: Set<UUID> = []
        var taskIDs: Set<UUID> = []
        for message in messages {
            if let filter = idFilter, !filter.contains(message.id) { continue }
            if let id = message.resolveLinkedEntityId(for: .finance) { financeIDs.insert(id) }
            if let id = message.resolveLinkedEntityId(for: .task) { taskIDs.insert(id) }
        }
        guard !financeIDs.isEmpty || !taskIDs.isEmpty else { return }

        let existingFinanceIDs = Self.fetchExistingTransactionIDs(financeIDs)
        let existingTaskIDs = Self.fetchExistingNonDeletedTaskIDs(taskIDs)

        var updatedMessages = messages
        var didChange = false
        for index in updatedMessages.indices {
            if let filter = idFilter, !filter.contains(updatedMessages[index].id) { continue }
            if let financeId = updatedMessages[index].resolveLinkedEntityId(for: .finance), financeIDs.contains(financeId) {
                let isDeleted = !existingFinanceIDs.contains(financeId)
                if updatedMessages[index].isEntityDeleted(for: .finance) != isDeleted {
                    updatedMessages[index].setDeletionState(isDeleted, for: .finance)
                    didChange = true
                }
            }
            if let taskId = updatedMessages[index].resolveLinkedEntityId(for: .task), taskIDs.contains(taskId) {
                let isDeleted = !existingTaskIDs.contains(taskId)
                if updatedMessages[index].isEntityDeleted(for: .task) != isDeleted {
                    updatedMessages[index].setDeletionState(isDeleted, for: .task)
                    didChange = true
                }
            }
        }
        // 删除态也属于消息快照的一部分，必须通过整体赋值触发 @Published，
        // 否则 Core Data 已经删除，HoloAI 卡片却不会立即重绘。
        if didChange {
            publishMessages(updatedMessages)
        }
    }

    /// 刷新单条消息的删除态缓存（Core Data 变更命中关联实体后调用）。
    func refreshDeletionState(for messageId: UUID, affectedCategories: [EntityCategory]) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        var snapshot = messages[index]
        var didChange = false
        for category in affectedCategories {
            guard let entityId = snapshot.resolveLinkedEntityId(for: category) else { continue }
            let exists: Bool
            switch category {
            case .finance:
                exists = Self.fetchExistingTransactionIDs([entityId]).contains(entityId)
            case .task:
                exists = Self.fetchExistingNonDeletedTaskIDs([entityId]).contains(entityId)
            default:
                exists = true
            }
            let isDeleted = !exists
            if snapshot.isEntityDeleted(for: category) != isDeleted {
                snapshot.setDeletionState(isDeleted, for: category)
                didChange = true
            }
        }
        // 不能只修改 messages[index] 内部字段：Repository 的发布契约是替换快照，
        // 这样 ChatViewModel 才能收到变更并让 SwiftUI 立即更新卡片。
        if didChange {
            var updatedMessages = messages
            updatedMessages[index] = snapshot
            publishMessages(updatedMessages)
        }
    }

    /// 返回给定 Transaction ID 集合中「确实存在」的子集（硬删除判定：不存在即已删除）
    nonisolated private static func fetchExistingTransactionIDs(_ ids: Set<UUID>) -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let context = CoreDataStack.shared.viewContext
        let request = NSFetchRequest<NSDictionary>(entityName: "Transaction")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["id"]
        request.predicate = NSPredicate(format: "id IN %@", ids)
        let rows = (try? context.fetch(request)) ?? []
        return Set(rows.compactMap { $0["id"] as? UUID })
    }

    /// 返回给定 TodoTask ID 集合中「存在且未软删除」的子集
    nonisolated private static func fetchExistingNonDeletedTaskIDs(_ ids: Set<UUID>) -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let context = CoreDataStack.shared.viewContext
        let request = NSFetchRequest<NSDictionary>(entityName: "TodoTask")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["id"]
        request.predicate = NSPredicate(format: "id IN %@ AND deletedFlag == NO", ids)
        let rows = (try? context.fetch(request)) ?? []
        return Set(rows.compactMap { $0["id"] as? UUID })
    }

    // MARK: - Private

    private func updateSnapshot(_ messageId: UUID, mutate: (inout ChatMessageViewData) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        var snapshot = messages[index]
        mutate(&snapshot)
        // 任何消息源数据变化都必须同步刷新卡片缓存，否则首屏和返回页面后的
        // ChatMessageViewData 会对同一条消息渲染出不同状态。
        snapshot.refreshDerivedState()
        var updatedMessages = messages
        updatedMessages[index] = snapshot
        publishMessages(updatedMessages)
    }

    /// 统一发布消息快照。
    ///
    /// ChatMessageViewData 是值类型，不能通过修改数组中的一个元素来可靠地
    /// 驱动 @Published。所有卡片状态、关联 ID 和派生数据的更新都必须走整体赋值。
    private func publishMessages(_ updatedMessages: [ChatMessageViewData]) {
        messages = updatedMessages
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

    // MARK: - 报告档案（Holo AI「报告」Tab）

    /// 报告档案行的轻量 DTO：只携带列表所需字段。
    /// 深度分析的完整结果（含证据链的大 JSON）在后台解码为摘要后立即丢弃，
    /// 完整报告延迟到进详情页时再按消息 ID 取。
    struct ReportArchiveDTO: Identifiable, Equatable, Sendable {
        enum Kind: String, Sendable {
            case deepAnalysis
            case periodReplay
        }

        let id: UUID
        let kind: Kind
        let timestamp: Date
        let title: String?
        /// 用户发起时的原始提问（深度分析；回放为 nil）。档案卡先显示提问再显示结论。
        let question: String?
        /// 摘要三级退让：keyInsight → narrativeSummary → directAnswer
        let summary: String?
        /// 深度分析的查询范围文案；回放为周期文案
        let scopeLabel: String?
        let observationCount: Int
        let evidenceCount: Int
        /// 正常完成但结论为空的提示文案；有结论时为 nil。
        /// 失败的分析不进档案——失败态由聊天流的消息卡承载，档案只收真报告。
        let issueText: String?
    }

    /// 归档只收已完成的报告；生成中的卡片由 ChatViewModel 的消息流派生（冷启动可恢复）。
    func loadReportArchiveAsync(limit: Int = 20, offset: Int = 0) async -> [ReportArchiveDTO] {
        await CoreDataStack.shared.waitUntilReady()

        let queryAnalysisIntent = "query_analysis"
        let replayType = ChatMessageType.periodReplay.rawValue
        do {
            return try await Task.detached(priority: .utility) {
                let context = CoreDataStack.shared.newBackgroundContext()
                return try await context.perform {
                    let request = NSFetchRequest<NSDictionary>(entityName: "ChatMessage")
                    request.resultType = .dictionaryResultType
                    request.propertiesToFetch = [
                        "id", "timestamp", "messageType", "agentResultJSON",
                        "extractedDataJSON", "content"
                    ]
                    request.predicate = NSPredicate(
                        format: "((intent == %@ AND agentResultJSON != nil) OR messageType == %@) AND isStreaming == NO",
                        queryAnalysisIntent, replayType
                    )
                    request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                    request.fetchLimit = limit
                    request.fetchOffset = offset

                    let dicts = try context.fetch(request)
                    return dicts.compactMap { dict -> ReportArchiveDTO? in
                        guard let id = dict["id"] as? UUID,
                              let timestamp = dict["timestamp"] as? Date else { return nil }

                        if (dict["messageType"] as? String) == replayType {
                            return Self.makeReplayArchiveDTO(
                                id: id,
                                timestamp: timestamp,
                                jobJSON: dict["extractedDataJSON"] as? String,
                                content: dict["content"] as? String
                            )
                        }

                        guard let json = dict["agentResultJSON"] as? String,
                              let data = json.data(using: .utf8),
                              let rendered = try? JSONDecoder().decode(HoloRenderedAgentResult.self, from: data),
                              // 失败（额度耗尽/出错/被中断）不是报告，不进档案
                              rendered.failure == nil
                        else { return nil }

                        let summary = rendered.keyInsight
                            ?? rendered.narrativeSummary
                            ?? rendered.directAnswer
                        return ReportArchiveDTO(
                            id: id,
                            kind: .deepAnalysis,
                            timestamp: timestamp,
                            title: rendered.title.isEmpty ? nil : rendered.title,
                            question: ChatMessageRepository.cleanOptionalText(rendered.question ?? rendered.rootUserQuestion),
                            summary: summary?.isEmpty == true ? nil : summary,
                            scopeLabel: rendered.scope?.displayLabel,
                            observationCount: rendered.sections.count,
                            evidenceCount: rendered.evidenceReferences.count,
                            issueText: rendered.emptyReason.map(Self.emptyReasonText)
                        )
                    }
                }
            }.value
        } catch {
            logger.error("加载报告档案失败：\(error.localizedDescription)")
            return []
        }
    }

    /// 报告详情入口：按消息 ID 取完整消息快照（含完整分析结果）。
    /// 单行按索引 ID 查询，直接走主上下文（ViewData 的初始化限定 MainActor）。
    @MainActor
    func loadMessageViewData(id: UUID) -> ChatMessageViewData? {
        let request = ChatMessage.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        guard let message = try? context.fetch(request).first else { return nil }
        return ChatMessageViewData(message: message)
    }

    private static func makeReplayArchiveDTO(
        id: UUID,
        timestamp: Date,
        jobJSON: String?,
        content: String?
    ) -> ReportArchiveDTO? {
        let summary = content?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == true ? nil : content
        return ReportArchiveDTO(
            id: id,
            kind: .periodReplay,
            timestamp: timestamp,
            title: "周期回放",
            question: nil,
            summary: summary,
            scopeLabel: HoloPeriodReplayJob(json: jobJSON).map { Self.replayPeriodLabel($0) },
            observationCount: 0,
            evidenceCount: 0,
            issueText: nil
        )
    }

    private static func cleanOptionalText(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// 报告搜索：SQLite 层先用 CONTAINS 粗筛（agentResultJSON/content 含关键词），
    /// 再在内存里对解码后的报告做精确匹配——覆盖 提问/标题/摘要/正文（观察与建议全文）。
    /// 回放按消息 content 匹配。命中正文时该报告仍按列表卡展示（摘要是核心发现）。
    func searchReportArchive(keyword: String) async -> [ReportArchiveDTO] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        await CoreDataStack.shared.waitUntilReady()

        let queryAnalysisIntent = "query_analysis"
        let replayType = ChatMessageType.periodReplay.rawValue
        do {
            return try await Task.detached(priority: .utility) {
                let context = CoreDataStack.shared.newBackgroundContext()
                return try await context.perform {
                    let request = NSFetchRequest<NSDictionary>(entityName: "ChatMessage")
                    request.resultType = .dictionaryResultType
                    request.propertiesToFetch = [
                        "id", "timestamp", "messageType", "agentResultJSON",
                        "extractedDataJSON", "content"
                    ]
                    request.predicate = NSPredicate(
                        format: "((intent == %@ AND agentResultJSON CONTAINS[C] %@) OR (messageType == %@ AND content CONTAINS[C] %@)) AND isStreaming == NO",
                        queryAnalysisIntent, trimmed, replayType, trimmed
                    )
                    request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                    request.fetchLimit = 50

                    let dicts = try context.fetch(request)
                    return dicts.compactMap { dict -> ReportArchiveDTO? in
                        guard let id = dict["id"] as? UUID,
                              let timestamp = dict["timestamp"] as? Date else { return nil }

                        if (dict["messageType"] as? String) == replayType {
                            guard let content = dict["content"] as? String,
                                  content.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                            else { return nil }
                            return Self.makeReplayArchiveDTO(
                                id: id,
                                timestamp: timestamp,
                                jobJSON: dict["extractedDataJSON"] as? String,
                                content: content
                            )
                        }

                        guard let json = dict["agentResultJSON"] as? String,
                              let data = json.data(using: .utf8),
                              let rendered = try? JSONDecoder().decode(HoloRenderedAgentResult.self, from: data),
                              rendered.failure == nil,
                              Self.reportMatches(rendered, keyword: trimmed)
                        else { return nil }

                        let summary = rendered.keyInsight
                            ?? rendered.narrativeSummary
                            ?? rendered.directAnswer
                        return ReportArchiveDTO(
                            id: id,
                            kind: .deepAnalysis,
                            timestamp: timestamp,
                            title: rendered.title.isEmpty ? nil : rendered.title,
                            question: ChatMessageRepository.cleanOptionalText(rendered.question ?? rendered.rootUserQuestion),
                            summary: summary?.isEmpty == true ? nil : summary,
                            scopeLabel: rendered.scope?.displayLabel,
                            observationCount: rendered.sections.count,
                            evidenceCount: rendered.evidenceReferences.count,
                            issueText: rendered.emptyReason.map(Self.emptyReasonText)
                        )
                    }
                }
            }.value
        } catch {
            logger.error("搜索报告档案失败：\(error.localizedDescription)")
            return []
        }
    }

    /// 报告文本匹配范围：提问 / 标题 / 摘要三级 / 正文（观察小节标题+全文）。
    private static func reportMatches(_ rendered: HoloRenderedAgentResult, keyword: String) -> Bool {
        var haystacks: [String] = [
            rendered.question ?? "",
            rendered.rootUserQuestion ?? "",
            rendered.title,
            rendered.keyInsight ?? "",
            rendered.narrativeSummary ?? "",
            rendered.directAnswer ?? "",
            rendered.summary
        ]
        haystacks.append(contentsOf: rendered.sections.map { "\($0.title) \($0.body)" })
        return haystacks.contains { text in
            text.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private static func replayPeriodLabel(_ job: HoloPeriodReplayJob) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        let range = "\(formatter.string(from: job.periodStart))–\(formatter.string(from: job.periodEnd))"
        switch job.periodType {
        case .daily: return "日回放 · \(range)"
        case .weekly: return "上周 · \(range)"
        case .monthly: return "上月 · \(range)"
        case .quarterly: return "上季度 · \(range)"
        case .custom: return range
        }
    }

    private static func emptyReasonText(_ reason: HoloAgentEmptyReason) -> String {
        switch reason {
        case .noData:
            return "所选范围内没有可用数据"
        case .unverifiable:
            return "数据未通过校验，暂无可靠结论"
        }
    }
}
