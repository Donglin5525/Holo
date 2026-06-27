//
//  ThoughtTagConvergenceJob.swift
//  Holo
//
//  跨观点归并收敛任务（P2.2）
//  不复用单条 ThoughtOrganizationQueue（状态机不同）：收敛是「收集输入 → 调 AI → 产出建议数组」的一次性任务，
//  建议产出后交 UI 确认（P2.3），确认走 TopicRepository.applyConvergence（P2.4），拒绝走 ConvergenceRejectionRepository（P2.5）。
//  参考 ThoughtOrganizationQueue 的重试 / rateLimited 处理思想。
//  spec: docs/superpowers/specs/2026-06-23-thought-knowledge-tree-design.md §6.2
//

import Foundation
import Combine
import OSLog

@MainActor
final class ThoughtTagConvergenceJob: ObservableObject {

    // MARK: - State

    enum JobState: Equatable {
        case idle
        case generating
        case ready([ConvergenceSuggestion])
        case failed(String)
    }

    @Published private(set) var state: JobState = .idle
    @Published private(set) var isGenerating: Bool = false

    /// 收敛失败兜底错误（理论不可达：循环至少执行一次，失败必赋 lastError）
    private struct ConvergenceFallbackError: Error {}

    // MARK: - Dependencies

    /// AI 调用注入点（生产注入 aiProvider.chat(purpose:.thoughtTagConvergence)，测试可 mock）
    private let aiCall: ([ChatMessageDTO]) async throws -> String
    private let thoughtRepository: ThoughtRepository
    private let topicRepository: TopicRepository
    private let rejectionRepository: ConvergenceRejectionRepository
    private let promptManager: PromptManager
    private let logger = Logger(subsystem: "com.holo.app", category: "ConvergenceJob")

    // MARK: - 重试配置（参考 ThoughtOrganizationQueue：指数退避 5s→30s→120s）

    private let maxRetryCount: Int
    private let retryIntervals: [TimeInterval]

    init(
        aiCall: @escaping ([ChatMessageDTO]) async throws -> String,
        thoughtRepository: ThoughtRepository,
        topicRepository: TopicRepository,
        rejectionRepository: ConvergenceRejectionRepository,
        promptManager: PromptManager = .shared,
        maxRetryCount: Int = 3,
        retryIntervals: [TimeInterval] = [5, 30, 120]
    ) {
        self.aiCall = aiCall
        self.thoughtRepository = thoughtRepository
        self.topicRepository = topicRepository
        self.rejectionRepository = rejectionRepository
        self.promptManager = promptManager
        self.maxRetryCount = maxRetryCount
        self.retryIntervals = retryIntervals
    }

    // MARK: - Run

    /// 触发跨观点收敛：收集输入 → 调 AI → 产出建议（交 UI 确认）
    func run() async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }

        // 1. 收集输入
        let input: ConvergenceInput
        do {
            input = try collectInput()
        } catch {
            logger.error("收集收敛输入失败：\(error.localizedDescription)")
            state = .failed("数据读取失败，请重试")
            return
        }

        // 数据不足：静默回 idle（spec §6.2 prompt 规则1：至少 3 条指向同方向才建议，不勉强凑主题）
        guard input.candidates.count >= 3 else {
            logger.info("收敛输入不足（\(input.candidates.count) < 3），跳过")
            state = .idle
            return
        }

        // 2. 调 AI
        state = .generating
        do {
            let suggestions = try await callConvergenceWithRetry(input: input)
            // 过滤已被建议级拒绝的（spec §6.2 prompt 规则5：不建议已拒绝过的）
            let filtered = suggestions.filter { !isRejected($0) }
            state = .ready(filtered)
            logger.info("收敛完成：\(filtered.count) 条建议")
        } catch let error as APIError {
            if case .rateLimited = error {
                state = .failed("今日 AI 整理配额已用完，请稍后再试")
            } else {
                state = .failed("AI 整理失败，请稍后重试")
            }
        } catch {
            state = .failed("AI 整理失败，请稍后重试")
        }
    }

    /// 消费建议后重置（UI 关闭确认页调用）
    func reset() {
        state = .idle
    }

    // MARK: - 收集输入

    /// 收敛输入（序列化为 user message 传给 AI）
    struct ConvergenceInput {
        let candidates: [ThoughtRepository.ConvergenceCandidate]
        let existingTopics: [(id: UUID, title: String)]
        let rejectedTopicTitles: [String]
    }

    private func collectInput() throws -> ConvergenceInput {
        let candidates = try thoughtRepository.fetchConvergenceCandidates(maxCount: 50)
        let topics = try topicRepository.fetchVisibleTopics()
        let existingTopics = topics.map { ($0.id, $0.title) }
        let rejections = try rejectionRepository.fetchActiveRejections()
        let rejectedTopicTitles = rejections.map { $0.topicTitle }
        return ConvergenceInput(
            candidates: candidates,
            existingTopics: existingTopics,
            rejectedTopicTitles: rejectedTopicTitles
        )
    }

    // MARK: - 调 AI（带重试）

    private func callConvergenceWithRetry(input: ConvergenceInput) async throws -> [ConvergenceSuggestion] {
        let systemPrompt = await loadManagedPrompt()
        let userMessage = buildUserMessage(input: input)
        let messages: [ChatMessageDTO] = [.system(systemPrompt), .user(userMessage)]

        var lastError: Error?
        for attempt in 0...maxRetryCount {
            do {
                let raw = try await aiCall(messages)
                return parseSuggestions(raw)
            } catch let error as APIError {
                // rateLimited 不重试，直接抛（配额耗尽，重试无意义）
                if case .rateLimited = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
            // 重试前等待（指数退避）
            if attempt < maxRetryCount {
                let interval = retryIntervals[min(attempt, retryIntervals.count - 1)]
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        // 循环结束必有 lastError（成功已 return）
        throw lastError ?? ConvergenceFallbackError()
    }

    /// 加载后端管理的 prompt（优先后端，回退本地后备，spec 双端同步）
    private func loadManagedPrompt() async -> String {
        do {
            return try await HoloBackendPromptService.shared.loadPrompt(.thoughtTagConvergence)
        } catch {
            logger.warning("后端 convergence prompt 加载失败，回退本地：\(error.localizedDescription)")
            return (try? promptManager.loadPrompt(.thoughtTagConvergence)) ?? ""
        }
    }

    // MARK: - 构建 user message

    private func buildUserMessage(input: ConvergenceInput) -> String {
        var thoughts: [[String: Any]] = []
        for c in input.candidates {
            thoughts.append([
                "id": c.id.uuidString,
                "summary": String(c.summary.prefix(120)),
                "tags": c.tags
            ])
        }
        let topics: [[String: String]] = input.existingTopics.map {
            ["id": $0.id.uuidString, "title": $0.title]
        }
        let payload: [String: Any] = [
            "thoughts": thoughts,
            "existingTopics": topics,
            "rejectedSuggestions": input.rejectedTopicTitles
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    // MARK: - 解析

    private func parseSuggestions(_ text: String) -> [ConvergenceSuggestion] {
        let jsonString = extractJSON(from: text)
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["suggestions"] as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { ConvergenceSuggestion(json: $0) }
    }

    /// 从 AI 输出提取 JSON（处理 markdown code fence 和前后缀）
    private func extractJSON(from text: String) -> String {
        if let range = text.range(of: "```json") {
            let after = text[range.upperBound...]
            if let end = after.range(of: "```") {
                return String(after[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let range = text.range(of: "```") {
            let after = text[range.upperBound...]
            if let end = after.range(of: "```") {
                let content = String(after[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if content.hasPrefix("{") { return content }
            }
        }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 已拒绝过滤

    private func isRejected(_ suggestion: ConvergenceSuggestion) -> Bool {
        rejectionRepository.isRejected(topicTitle: suggestion.topicTitle, sourceTerms: suggestion.sourceTerms)
    }
}
