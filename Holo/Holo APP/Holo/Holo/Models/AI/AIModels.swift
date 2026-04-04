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
enum AIIntent: String, Codable, CaseIterable {
    case recordExpense = "record_expense"
    case recordIncome = "record_income"
    case createTask = "create_task"
    case recordMood = "record_mood"
    case recordWeight = "record_weight"
    case checkIn = "check_in"
    case query = "query"
    case chat = "chat"
    case unknown = "unknown"
}

// MARK: - ParsedResult

/// AI 意图识别结果
struct ParsedResult: Codable {
    let intent: AIIntent
    let confidence: Double
    let extractedData: [String: String]?
    let needsClarification: Bool
    let clarificationQuestion: String?
    let responseText: String?

    /// 高置信度阈值
    static let highConfidenceThreshold = 0.7

    var isHighConfidence: Bool {
        confidence >= Self.highConfidenceThreshold
    }
}

// MARK: - API DTO

/// OpenAI 兼容 API 消息 DTO
struct ChatMessageDTO: Codable {
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

/// Chat Completion 请求
struct ChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatMessageDTO]
    let temperature: Double?
    let maxTokens: Int?
    let stream: Bool?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case maxTokens = "max_tokens"
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
struct SSEChunk: Codable {
    let id: String?
    let choices: [ChunkChoice]?

    struct ChunkChoice: Codable {
        let index: Int?
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Codable {
        let role: String?
        let content: String?
    }
}

// MARK: - InsightType

/// 洞察/总结类型
enum InsightType: String, CaseIterable {
    case dailySummary = "daily_summary"
    case weeklyReport = "weekly_report"
    case monthlyReport = "monthly_report"
    case habitAnalysis = "habit_analysis"
    case financeAnalysis = "finance_analysis"
}

// MARK: - UserContext

/// 用户上下文数据，传给 AI 构建个性化回复
struct UserContext {
    let todayDate: String
    let transactions: TransactionSummary
    let habits: HabitSummary
    let tasks: TaskSummary
    let thoughts: ThoughtSummary
}

/// 交易摘要
struct TransactionSummary {
    let todayExpense: String
    let todayIncome: String
    let recentTransactions: [String]
}

/// 习惯摘要
struct HabitSummary {
    let totalActive: Int
    let todayCompleted: Int
    let todayTotal: Int
    let recentCheckIns: [String]
}

/// 任务摘要
struct TaskSummary {
    let todayTotal: Int
    let todayCompleted: Int
    let overdueCount: Int
    let recentTasks: [String]
}

/// 观点摘要
struct ThoughtSummary {
    let recentThoughts: [String]
    let totalThoughts: Int
}
