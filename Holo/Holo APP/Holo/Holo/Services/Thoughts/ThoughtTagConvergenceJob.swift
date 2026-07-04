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

    static let shared: ThoughtTagConvergenceJob = {
        let provider = HoloBackendAIProvider()
        return ThoughtTagConvergenceJob(
            aiCall: { messages in try await provider.chat(messages: messages, purpose: .thoughtTagConvergence) },
            thoughtRepository: ThoughtRepository(),
            topicRepository: TopicRepository(),
            rejectionRepository: ConvergenceRejectionRepository()
        )
    }()

    // MARK: - State

    enum JobState: Equatable {
        case idle
        case generating
        case unchanged
        case ready([ConvergenceSuggestion])
        case applied(Int)
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
    private let jobStore: ThoughtTagConvergenceJobStore
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
        jobStore: ThoughtTagConvergenceJobStore? = nil,
        promptManager: PromptManager = .shared,
        maxRetryCount: Int = 3,
        retryIntervals: [TimeInterval] = [5, 30, 120]
    ) {
        self.aiCall = aiCall
        self.thoughtRepository = thoughtRepository
        self.topicRepository = topicRepository
        self.rejectionRepository = rejectionRepository
        self.jobStore = jobStore ?? ThoughtTagConvergenceJobStore.shared
        self.promptManager = promptManager
        self.maxRetryCount = maxRetryCount
        self.retryIntervals = retryIntervals
    }

    // MARK: - Run

    /// 触发跨观点收敛：收集输入 → 调 AI → 产出建议（交 UI 确认）
    func run(autoApply: Bool = false, persist: Bool = false) async {
        guard !isGenerating else { return }
        if persist {
            jobStore.upsert(autoApply: autoApply)
        }
        isGenerating = true
        if persist {
            jobStore.markRunning()
        }
        let backgroundLease = HoloBackgroundTaskLease(name: "HoloThoughtConvergence") { [weak self] in
            self?.logger.warning("观点主题归纳后台执行时间已到期")
        }
        defer {
            backgroundLease.end()
            isGenerating = false
        }

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
            if persist { jobStore.clear() }
            return
        }

        let inputSignature = makeInputSignature(input)
        if jobStore.lastCompletedInputSignature() == inputSignature {
            logger.info("收敛输入未变化，跳过重复 AI 调用")
            state = .unchanged
            if persist { jobStore.clear() }
            return
        }

        // 2. 调 AI
        state = .generating
        do {
            let suggestions = try await callConvergenceWithRetry(input: input)
            // 过滤已被建议级拒绝的（spec §6.2 prompt 规则5：不建议已拒绝过的）
            let resolved = suggestions.isEmpty ? buildFallbackSuggestions(input: input) : suggestions
            let filtered = resolved.filter { !isRejected($0) }
            if autoApply {
                let appliedCount = applySuggestions(filtered)
                state = appliedCount > 0 ? .applied(appliedCount) : .ready([])
                markCurrentInputCompleted(fallbackSignature: inputSignature)
                if persist { jobStore.clear() }
                logger.info("收敛完成并自动应用：\(appliedCount)/\(filtered.count) 条建议")
            } else {
                state = .ready(filtered)
                jobStore.markInputCompleted(signature: inputSignature)
                if persist { jobStore.clear() }
                logger.info("收敛完成：\(filtered.count) 条建议")
            }
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

    func resumePersistedJobIfNeeded() async {
        guard let record = jobStore.load() else { return }
        await run(autoApply: record.autoApply, persist: true)
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
        let candidates = try thoughtRepository.fetchConvergenceCandidates(maxCount: 200)
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

    private func markCurrentInputCompleted(fallbackSignature: String) {
        do {
            let refreshedInput = try collectInput()
            jobStore.markInputCompleted(signature: makeInputSignature(refreshedInput))
        } catch {
            logger.warning("刷新收敛输入签名失败，使用调用前签名：\(error.localizedDescription)")
            jobStore.markInputCompleted(signature: fallbackSignature)
        }
    }

    private func makeInputSignature(_ input: ConvergenceInput) -> String {
        let thoughts = input.candidates
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { candidate in
                [
                    candidate.id.uuidString,
                    candidate.summary,
                    candidate.tags.map { ThoughtTagNormalizer.key($0) }.sorted().joined(separator: ",")
                ].joined(separator: "|")
            }
            .joined(separator: "\n")

        let topics = input.existingTopics
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { "\($0.id.uuidString)|\(ThoughtTagNormalizer.key($0.title))" }
            .joined(separator: "\n")

        let rejections = input.rejectedTopicTitles
            .map { ThoughtTagNormalizer.key($0) }
            .sorted()
            .joined(separator: "\n")

        return [
            "thoughts:\(thoughts)",
            "topics:\(topics)",
            "rejections:\(rejections)"
        ].joined(separator: "\n---\n")
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
                "summary": String(c.summary.prefix(240)),
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
              let arr = (obj["suggestions"] as? [[String: Any]])
                    ?? (obj["topics"] as? [[String: Any]])
                    ?? (obj["themeSuggestions"] as? [[String: Any]]) else {
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

    // MARK: - 本地兜底

    /// 当 LLM 没给主题但标签信号已经足够明确时，给出可确认的本地建议，避免入口看起来无效。
    private func buildFallbackSuggestions(input: ConvergenceInput) -> [ConvergenceSuggestion] {
        let normalizedCandidates = input.candidates.map { candidate in
            let tags = Array(Set(candidate.tags.map { ThoughtTagNormalizer.displayName($0) }.filter { !$0.isEmpty }))
            return ThoughtRepository.ConvergenceCandidate(id: candidate.id, summary: candidate.summary, tags: tags)
        }

        var grouped: [String: (displayName: String, candidates: [ThoughtRepository.ConvergenceCandidate])] = [:]
        for candidate in normalizedCandidates {
            let uniqueTags = Set(candidate.tags)
            for tag in uniqueTags {
                let key = ThoughtTagNormalizer.key(tag)
                var group = grouped[key] ?? (displayName: tag, candidates: [])
                group.candidates.append(candidate)
                grouped[key] = group
            }
        }

        let tagSuggestions = grouped
            .filter { _, value in value.candidates.count >= 2 }
            .sorted {
                if $0.value.candidates.count == $1.value.candidates.count { return $0.value.displayName < $1.value.displayName }
                return $0.value.candidates.count > $1.value.candidates.count
            }
            .prefix(5)
            .map { _, value in
                makeFallbackSuggestion(
                    topicTitle: Self.topicTitle(from: value.displayName),
                    candidates: value.candidates,
                    sourceTerms: [value.displayName],
                    input: input,
                    confidence: 0.66,
                    reason: "\(value.candidates.count) 条观点都带有「\(value.displayName)」线索，可先收纳成一个主题。"
                )
            }

        let usedThoughtIds = Set(tagSuggestions.flatMap(\.thoughtIds))
        let familySuggestions = buildKeywordFamilyFallbackSuggestions(
            candidates: normalizedCandidates,
            excluding: usedThoughtIds,
            input: input
        )

        var seenTopicKeys: Set<String> = []
        return (tagSuggestions + familySuggestions).compactMap { suggestion in
            let key = Self.normalizedTopicTitle(suggestion.topicTitle)
            guard !seenTopicKeys.contains(key) else { return nil }
            seenTopicKeys.insert(key)
            return suggestion
        }
    }

    private static func topicTitle(from tagName: String) -> String {
        String(ThoughtTagNormalizer.displayName(tagName).prefix(8))
    }

    private static func normalizedTopicTitle(_ value: String) -> String {
        ThoughtTagNormalizer.key(value)
    }

    private func makeFallbackSuggestion(
        topicTitle: String,
        candidates: [ThoughtRepository.ConvergenceCandidate],
        sourceTerms: [String],
        input: ConvergenceInput,
        confidence: Double,
        reason: String
    ) -> ConvergenceSuggestion {
        let matchedTopicId = input.existingTopics.first {
            Self.normalizedTopicTitle($0.title) == Self.normalizedTopicTitle(topicTitle)
        }?.id
        return ConvergenceSuggestion(
            topicTitle: topicTitle,
            matchedTopicId: matchedTopicId,
            thoughtIds: candidates.map(\.id),
            sourceTerms: sourceTerms,
            confidence: confidence,
            reason: reason
        )
    }

    private func buildKeywordFamilyFallbackSuggestions(
        candidates: [ThoughtRepository.ConvergenceCandidate],
        excluding usedThoughtIds: Set<UUID>,
        input: ConvergenceInput
    ) -> [ConvergenceSuggestion] {
        let families: [(title: String, keywords: [String])] = [
            ("AI能力", ["ai", "人工智能", "模型", "prompt", "提示词", "agent", "智能体", "gpt", "glm", "claude"]),
            ("产品思考", ["产品", "需求", "用户", "体验", "商业", "付费", "增长", "设计"]),
            ("开发实践", ["代码", "开发", "编程", "工程", "bug", "架构", "测试", "debug", "swift", "后端", "前端"]),
            ("内容创作", ["写作", "文章", "自媒体", "小红书", "公众号", "表达", "文案", "发布"]),
            ("生活健康", ["睡眠", "健康", "运动", "情绪", "状态", "身体", "饮食", "疲惫"]),
            ("工作计划", ["工作", "任务", "计划", "项目", "复盘", "会议", "目标"])
        ]

        return families.compactMap { family in
            let matched = candidates.filter { candidate in
                guard !usedThoughtIds.contains(candidate.id) else { return false }
                let haystack = (candidate.summary + " " + candidate.tags.joined(separator: " ")).lowercased()
                return family.keywords.contains { haystack.contains($0.lowercased()) }
            }
            guard matched.count >= 3 else { return nil }

            let sourceTerms = topSourceTerms(from: matched, fallback: family.keywords)
            return makeFallbackSuggestion(
                topicTitle: family.title,
                candidates: Array(matched.prefix(20)),
                sourceTerms: sourceTerms,
                input: input,
                confidence: 0.58,
                reason: "\(matched.count) 条观点在内容或标签上集中指向「\(family.title)」，可先作为一级主题收纳。"
            )
        }
    }

    private func topSourceTerms(
        from candidates: [ThoughtRepository.ConvergenceCandidate],
        fallback: [String]
    ) -> [String] {
        var counts: [String: Int] = [:]
        for tag in candidates.flatMap(\.tags) {
            let displayName = ThoughtTagNormalizer.displayName(tag)
            guard !displayName.isEmpty else { continue }
            counts[displayName, default: 0] += 1
        }
        let tags = counts.sorted {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value > $1.value
        }
        .prefix(5)
        .map(\.key)
        if !tags.isEmpty { return tags }
        return Array(fallback.prefix(3))
    }

    private func applySuggestions(_ suggestions: [ConvergenceSuggestion]) -> Int {
        var appliedCount = 0
        for suggestion in suggestions {
            do {
                _ = try topicRepository.applyConvergence(
                    matchedTopicId: suggestion.matchedTopicId,
                    topicTitle: suggestion.topicTitle,
                    thoughtIds: suggestion.thoughtIds,
                    sourceTerms: suggestion.sourceTerms
                )
                appliedCount += 1
            } catch {
                logger.error("自动应用主题归并失败：\(error.localizedDescription)")
            }
        }
        if appliedCount > 0 {
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        }
        return appliedCount
    }

    // MARK: - 已拒绝过滤

    private func isRejected(_ suggestion: ConvergenceSuggestion) -> Bool {
        rejectionRepository.isRejected(topicTitle: suggestion.topicTitle, sourceTerms: suggestion.sourceTerms)
    }
}
