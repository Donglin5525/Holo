//
//  AIModels.swift
//  Holo
//
//  AI 模块值类型定义
//  包含意图枚举、解析结果、API DTO 和用户上下文
//

import Foundation

// MARK: - Intent

/// AI 识别的用户意图
nonisolated enum AIIntent: String, Codable, CaseIterable {
    // 记账类
    case recordExpense = "record_expense"
    case recordIncome = "record_income"
    // 任务类
    case createTask = "create_task"
    case completeTask = "complete_task"
    case updateTask = "update_task"
    case deleteTask = "delete_task"
    // 习惯类
    case checkIn = "check_in"
    // 笔记类
    case createNote = "create_note"
    // 健康类
    case recordMood = "record_mood"
    case recordWeight = "record_weight"
    // 查询类
    case queryTasks = "query_tasks"
    case queryHabits = "query_habits"
    case queryAnalysis = "query_analysis"
    case flexibleDataQuery = "flexible_data_query"
    case query = "query"
    // 记忆回放类
    case generateMemoryInsight = "generate_memory_insight"
    // 兜底
    case unknown = "unknown"
}

// MARK: - AIIntent Category Helpers

extension AIIntent {
    nonisolated static let queryIntents: Set<AIIntent> = [.query, .queryTasks, .queryHabits, .queryAnalysis, .flexibleDataQuery]
    nonisolated static let taskIntents: Set<AIIntent> = [.createTask, .completeTask, .updateTask]
    nonisolated static let financeIntents: Set<AIIntent> = [.recordExpense, .recordIncome]

    nonisolated var isQuery: Bool { Self.queryIntents.contains(self) }
    nonisolated var isTask: Bool { Self.taskIntents.contains(self) }
    nonisolated var isFinance: Bool { Self.financeIntents.contains(self) }

    nonisolated var chatDisplayLabel: String {
        switch self {
        case .recordExpense, .recordIncome: return "已记账"
        case .createTask: return "已创建任务"
        case .completeTask: return "已完成任务"
        case .updateTask: return "已更新任务"
        case .deleteTask: return "已删除任务"
        case .recordMood: return "已记录心情"
        case .recordWeight: return "已记录体重"
        case .checkIn: return "已打卡"
        case .createNote: return "已记录笔记"
        case .queryTasks: return "任务查询"
        case .queryHabits: return "习惯查询"
        case .queryAnalysis: return "分析卡片"
        case .flexibleDataQuery: return "查询卡片"
        case .generateMemoryInsight: return "已生成回放"
        case .unknown: return "未识别指令"
        case .query: return "查询"
        }
    }
}

// MARK: - LinkedEntity

/// 关联实体类型
enum LinkedEntityType: String, Codable {
    case transaction, task, habit, thought, memoryInsight, goal
}

/// 通用实体链接
struct LinkedEntity: Codable {
    let type: LinkedEntityType
    let id: UUID
}

// MARK: - ParsedResult

/// AI 意图识别结果
nonisolated struct ParsedResult: Codable {
    let intent: AIIntent
    let confidence: Double
    let extractedData: [String: String]?
    let needsClarification: Bool
    let clarificationQuestion: String?
    let responseText: String?

    /// 高置信度阈值
    nonisolated static let highConfidenceThreshold = 0.7

    var isHighConfidence: Bool {
        confidence >= Self.highConfidenceThreshold
    }

    // MARK: - Initializers

    init(
        intent: AIIntent,
        confidence: Double,
        extractedData: [String: String]?,
        needsClarification: Bool,
        clarificationQuestion: String?,
        responseText: String?
    ) {
        self.intent = intent
        self.confidence = confidence
        self.extractedData = extractedData
        self.needsClarification = needsClarification
        self.clarificationQuestion = clarificationQuestion
        self.responseText = responseText
    }

    // LLM 可能返回 null 值字段（如 "title": null），需要过滤
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intent = try container.decode(AIIntent.self, forKey: .intent)
        confidence = try container.decode(Double.self, forKey: .confidence)
        needsClarification = try container.decodeIfPresent(Bool.self, forKey: .needsClarification) ?? false
        clarificationQuestion = try container.decodeIfPresent(String.self, forKey: .clarificationQuestion)
        responseText = try container.decodeIfPresent(String.self, forKey: .responseText)

        // extractedData 中可能包含 null 值，先解码为 [String: String?] 再过滤
        if let rawDict = try? container.decodeIfPresent([String: String?].self, forKey: .extractedData) {
            extractedData = rawDict.compactMapValues { $0 }
        } else {
            extractedData = nil
        }
    }
}

// MARK: - Batch Models

/// 交互模式
nonisolated enum AIInteractionMode: String, Codable, Equatable {
    case singleAction = "single_action"
    case multiAction = "multi_action"
    case query = "query"
    case clarification = "clarification"
    case unknown = "unknown"
}

/// 执行状态
nonisolated enum AIExecutionStatus: String, Codable, Equatable {
    case success
    case failed
    case skipped
}

/// 单个解析项
nonisolated struct AIParseItem: Codable, Identifiable, Equatable {
    let id: String
    let intent: AIIntent
    let confidence: Double
    let extractedData: [String: String]?
    let responseText: String?

    var isHighConfidence: Bool {
        confidence >= ParsedResult.highConfidenceThreshold
    }

    init(
        id: String = UUID().uuidString,
        intent: AIIntent,
        confidence: Double,
        extractedData: [String: String]? = nil,
        responseText: String? = nil
    ) {
        self.id = id
        self.intent = intent
        self.confidence = confidence
        self.extractedData = extractedData
        self.responseText = responseText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        intent = try container.decode(AIIntent.self, forKey: .intent)
        confidence = try container.decode(Double.self, forKey: .confidence)
        responseText = try container.decodeIfPresent(String.self, forKey: .responseText)

        if let rawDict = try? container.decodeIfPresent([String: String?].self, forKey: .extractedData) {
            extractedData = rawDict.compactMapValues { $0 }
        } else {
            extractedData = nil
        }
    }
}

/// 批量解析结果
nonisolated struct AIParseBatch: Codable, Equatable {
    let mode: AIInteractionMode
    let items: [AIParseItem]
    let needsClarification: Bool
    let clarificationQuestion: String?
    let fallbackResponseText: String?

    init(
        mode: AIInteractionMode,
        items: [AIParseItem],
        needsClarification: Bool = false,
        clarificationQuestion: String? = nil,
        fallbackResponseText: String? = nil
    ) {
        self.mode = mode
        self.items = items
        self.needsClarification = needsClarification
        self.clarificationQuestion = clarificationQuestion
        self.fallbackResponseText = fallbackResponseText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(AIInteractionMode.self, forKey: .mode)
        needsClarification = try container.decodeIfPresent(Bool.self, forKey: .needsClarification) ?? false
        clarificationQuestion = try container.decodeIfPresent(String.self, forKey: .clarificationQuestion)
        fallbackResponseText = try container.decodeIfPresent(String.self, forKey: .fallbackResponseText)

        if let rawItems = try? container.decodeIfPresent([AIParseItem].self, forKey: .items) {
            items = rawItems
        } else {
            items = []
        }
    }

    var first: AIParseItem? { items.first }
    var isEmpty: Bool { items.isEmpty }
}

/// 单个执行结果
nonisolated struct AIExecutionItem: Codable, Identifiable, Equatable {
    let id: String
    let parseItemId: String
    let intent: AIIntent
    let status: AIExecutionStatus
    let summaryText: String
    let renderData: [String: String]?
    let linkedEntityType: String?
    let linkedEntityId: String?
    let errorText: String?
}

/// 批量执行结果
nonisolated struct AIExecutionBatch: Codable, Equatable {
    let mode: AIInteractionMode
    let items: [AIExecutionItem]
    let finalText: String
}

// MARK: - ParsedResult <-> AIParseItem Conversions

extension ParsedResult {
    var asParseItem: AIParseItem {
        AIParseItem(
            id: UUID().uuidString,
            intent: intent,
            confidence: confidence,
            extractedData: extractedData,
            responseText: responseText
        )
    }
}

extension AIParseItem {
    var asParsedResult: ParsedResult {
        ParsedResult(
            intent: intent,
            confidence: confidence,
            extractedData: extractedData,
            needsClarification: false,
            clarificationQuestion: nil,
            responseText: responseText
        )
    }
}

// MARK: - API DTO

/// OpenAI 兼容 API 消息 DTO
nonisolated struct ChatMessageDTO: Codable, Equatable {
    let role: String
    let content: String

    static func system(_ content: String) -> ChatMessageDTO {
        ChatMessageDTO(role: "system", content: content)
    }

    static func user(_ content: String) -> ChatMessageDTO {
        ChatMessageDTO(role: "user", content: content)
    }

    static func assistant(_ content: String) -> ChatMessageDTO {
        ChatMessageDTO(role: "assistant", content: content)
    }
}

/// JSON Mode 响应格式控制
struct ResponseFormat: Codable, Equatable {
    let type: String

    static let jsonObject = ResponseFormat(type: "json_object")
}

/// Chat Completion 请求
struct ChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatMessageDTO]
    let temperature: Double?
    let maxTokens: Int?
    let stream: Bool?
    let responseFormat: ResponseFormat?

    init(model: String, messages: [ChatMessageDTO], temperature: Double? = nil, maxTokens: Int? = nil, stream: Bool? = nil, responseFormat: ResponseFormat? = nil) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stream = stream
        self.responseFormat = responseFormat
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }
}

/// Chat Completion 响应
struct ChatCompletionResponse: Codable {
    let id: String?
    let choices: [Choice]?
    let usage: Usage?

    struct Choice: Codable {
        let index: Int?
        let message: ChatMessageDTO?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, message
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Codable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

/// SSE 流式响应块
nonisolated struct SSEChunk: Codable {
    let id: String?
    let choices: [ChunkChoice]?

    nonisolated struct ChunkChoice: Codable {
        let index: Int?
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }
    }

    nonisolated struct Delta: Codable {
        let role: String?
        let content: String?
    }
}

// MARK: - InsightType

/// 洞察/总结类型
enum InsightType: String, CaseIterable {
    case memoryDailyReview = "memory_daily_review"
    case memoryWeeklyReplay = "memory_weekly_replay"
    case memoryMonthlyReplay = "memory_monthly_replay"
}

// MARK: - UserRecentTrend

/// 近期趋势数据，让 AI 感知历史对比
struct UserRecentTrend {
    let weekExpenseTotal: String
    let weekExpenseChange: String?
    let weekHabitCompletionRate: String?
    let weekTaskCompletedCount: Int
    let topExpenseCategory: String?
    let dailyInsightSummary: String?
}

// MARK: - UserContext

/// 用户上下文数据，传给 AI 构建个性化回复
struct UserContext {
    let todayDate: String
    let transactions: TransactionSummary
    let habits: HabitSummary
    let tasks: TaskSummary
    let thoughts: ThoughtSummary
    let accounts: AccountSummary
    let profileContext: String?
    /// 结构化 profile snapshot（由 HoloProfileSnapshotBuilder 解析）
    let profileSnapshot: HoloProfileSnapshot?
    let recentTrend: UserRecentTrend?
    let goalContext: String?
    var dataCoverage: HoloMemoryDataCoverage?
    var memorySummary: HoloMemoryPromptSummary?

    /// 空上下文（分析查询不需要即时上下文）
    static let empty = UserContext(
        todayDate: "",
        transactions: TransactionSummary(todayExpense: "", todayIncome: "", recentTransactions: []),
        habits: HabitSummary(totalActive: 0, todayCompleted: 0, todayTotal: 0, recentCheckIns: [], activeHabitNames: [], focusSummaries: [], focusTopicLines: []),
        tasks: TaskSummary(todayTotal: 0, todayCompleted: 0, overdueCount: 0, recentTasks: [], activeTaskSummaries: []),
        thoughts: ThoughtSummary(recentThoughts: [], totalThoughts: 0),
        accounts: AccountSummary(accountList: "", defaultAccountName: ""),
        profileContext: nil,
        profileSnapshot: nil,
        recentTrend: nil,
        goalContext: nil,
        dataCoverage: nil,
        memorySummary: nil
    )
}

/// 交易摘要
struct TransactionSummary {
    let todayExpense: String
    let todayIncome: String
    let recentTransactions: [String]
}

/// 账户摘要
struct AccountSummary {
    /// 可读的账户列表，如 "现金(默认)、微信、支付宝、储蓄卡"
    let accountList: String
    /// 默认账户名称
    let defaultAccountName: String
}

/// 习惯摘要
struct HabitSummary {
    let totalActive: Int
    let todayCompleted: Int
    let todayTotal: Int
    let recentCheckIns: [String]
    let activeHabitNames: [String]
    let focusSummaries: [HabitFocusSummary]
    let focusTopicLines: [String]
}

/// 任务摘要
struct TaskSummary {
    let todayTotal: Int
    let todayCompleted: Int
    let overdueCount: Int
    let recentTasks: [String]
    let activeTaskSummaries: [String]
}

/// 观点摘要
struct ThoughtSummary {
    let recentThoughts: [String]
    let totalThoughts: Int
}
