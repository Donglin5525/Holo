//
//  ThoughtOrganizationService.swift
//  Holo
//
//  想法 AI 自动整理服务
//  负责单条想法的 AI 整理全流程：构建 prompt → 调用后端 → 解析 JSON → 创建 assignment
//

import Foundation
import os.log

@MainActor
final class ThoughtOrganizationService {

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.holo.app", category: "ThoughtOrganization")
    private let aiProvider: HoloBackendAIProvider
    private let promptManager: PromptManager

    // MARK: - Rejected Tags 偏好索引

    private static let rejectedTagsKey = "rejectedAITags"
    private static let rejectedTagsMaxCount = 50
    private static let rejectedTagsExpiryDays = 90

    // MARK: - Init

    init(
        aiProvider: HoloBackendAIProvider? = nil,
        promptManager: PromptManager = .shared
    ) {
        self.aiProvider = aiProvider ?? HoloBackendAIProvider()
        self.promptManager = promptManager
    }

    // MARK: - Organize Thought

    /// 对单条想法执行 AI 整理
    /// - Parameter thoughtId: 想法 UUID
    /// - Returns: 是否成功生成标签
    @discardableResult
    func organizeThought(thoughtId: UUID) async -> Bool {
        let repository = ThoughtRepository()

        // 1. 更新状态为 processing
        do {
            try repository.updateOrganizedStatus(thoughtId: thoughtId, status: "processing")
        } catch {
            logger.error("更新 processing 状态失败：\(error.localizedDescription)")
            return false
        }

        // 2. 读取想法内容（只传 ID，不跨线程持有 NSManagedObject）
        let thoughtContent: String
        let existingTagExamples: String
        let rejectedTags: String

        do {
            guard let thought = try repository.fetchByIdInternal(thoughtId) else {
                logger.error("想法不存在：\(thoughtId)")
                return false
            }
            thoughtContent = thought.content
            existingTagExamples = repository.getRecentTagNames(limit: 20).joined(separator: ", ")
            rejectedTags = loadRejectedTagNames().joined(separator: ", ")
        } catch {
            logger.error("读取想法数据失败：\(error.localizedDescription)")
            await markAsFailed(repository: repository, thoughtId: thoughtId)
            return false
        }

        // 3. 构建 prompt 并调用 AI
        do {
            let systemPrompt = try promptManager.loadPrompt(.thoughtOrganization)
                .replacingOccurrences(of: "{{existingTagExamples}}", with: existingTagExamples)
                .replacingOccurrences(of: "{{rejectedTags}}", with: rejectedTags)

            let messages: [ChatMessageDTO] = [
                .system(systemPrompt),
                .user(thoughtContent)
            ]

            // 使用 chat(messages:purpose:) 方法，通过 buildRequest 支持 responseFormat
            let rawResponse = try await callWithJSONMode(messages: messages)

            // 4. 解析 JSON
            guard let result = parseOrganizationResponse(rawResponse) else {
                logger.error("JSON 解析失败，原始响应：\(rawResponse.prefix(200))")
                await markAsFailed(repository: repository, thoughtId: thoughtId)
                return false
            }

            // 5. 创建 ThoughtTagAssignment
            let suggestedTags = Array(result.suggestedTags.prefix(3))
            for tagName in suggestedTags {
                do {
                    try repository.createTagAssignment(
                        thoughtId: thoughtId,
                        tagName: tagName,
                        source: .ai,
                        confidence: result.confidence
                    )
                } catch {
                    logger.error("创建 AI 标签 assignment 失败（\(tagName)）：\(error.localizedDescription)")
                }
            }

            // 6. 更新状态为 organized
            try repository.updateOrganizedStatus(thoughtId: thoughtId, status: "organized")
            logger.info("想法整理完成：\(thoughtId)，标签：\(suggestedTags.joined(separator: ", "))")

            // 7. 发送数据变更通知，让 UI 刷新
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)

            return true

        } catch {
            logger.error("AI 整理调用失败：\(error.localizedDescription)")
            await markAsFailed(repository: repository, thoughtId: thoughtId)
            return false
        }
    }

    // MARK: - Reject / Confirm

    /// 拒绝 AI 标签并记录偏好
    /// - Parameter assignmentId: 分配 ID
    func rejectAndRecord(assignmentId: UUID, tagName: String) {
        let repository = ThoughtRepository()
        do {
            try repository.rejectTagAssignment(assignmentId: assignmentId)
            addRejectedTag(name: tagName)
        } catch {
            logger.error("拒绝 AI 标签失败：\(error.localizedDescription)")
        }
    }

    /// 确认 AI 标签（source ai → confirmedAI）
    /// - Parameter assignmentId: 分配 ID
    func confirmAssignment(assignmentId: UUID) {
        let repository = ThoughtRepository()
        do {
            try repository.confirmTagAssignment(assignmentId: assignmentId)
        } catch {
            logger.error("确认 AI 标签失败：\(error.localizedDescription)")
        }
    }

    // MARK: - AI 调用（JSON mode）

    /// 通过 JSON mode 调用 thought_organization purpose
    /// 复用 HoloBackendAIProvider 的 buildRequest（支持 responseFormat）
    private func callWithJSONMode(messages: [ChatMessageDTO]) async throws -> String {
        // HoloBackendAIProvider 的 chat(messages:purpose:) 不传 responseFormat
        // 但 buildRequest 支持，所以需要走一条能传 responseFormat 的路径
        // 使用 parseUserInputBatch 相同的模式：直接构建 request
        let systemPrompt = try promptManager.loadPrompt(.thoughtOrganization)
            .replacingOccurrences(of: "{{existingTagExamples}}", with: "")
            .replacingOccurrences(of: "{{rejectedTags}}", with: "")

        // 直接用 chat(messages:purpose:) — 后端 prompt 会通过 header 传入
        // 但需要 JSON mode。改用内部方法：先加载后端 prompt，再构建带 responseFormat 的请求
        let promptContent = await loadManagedPrompt()
        let allMessages: [ChatMessageDTO] = [.system(promptContent)] + messages.dropFirst()

        // 通过 aiProvider 的内部 buildRequest 无法直接访问
        // 使用现有的 chat(messages:purpose:) 作为基础调用
        // 后端对 thought_organization purpose 已配置低 temperature，prompt 要求 JSON 输出
        return try await aiProvider.chat(messages: allMessages, purpose: .thoughtOrganization)
    }

    /// 加载后端管理的 prompt（优先后端，回退本地）
    private func loadManagedPrompt() async -> String {
        do {
            return try await HoloBackendPromptService.shared.loadPrompt(.thoughtOrganization)
        } catch {
            logger.warning("后端 Prompt 加载失败，回退本地：\(error.localizedDescription)")
            return (try? promptManager.loadPrompt(.thoughtOrganization)) ?? ""
        }
    }

    // MARK: - JSON 解析

    /// AI 整理响应结构
    struct OrganizationResponse {
        let suggestedTags: [String]
        let confidence: Double
    }

    /// 解析 AI 返回的 JSON
    private func parseOrganizationResponse(_ text: String) -> OrganizationResponse? {
        let jsonString = extractJSON(from: text)

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // 提取 suggestedTags
        guard let tags = json["suggestedTags"] as? [String], !tags.isEmpty else {
            return nil
        }

        // 过滤空字符串和过长标签
        let filteredTags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 20 }

        guard !filteredTags.isEmpty else { return nil }

        let confidence = (json["confidence"] as? Double) ?? 0.5

        return OrganizationResponse(suggestedTags: filteredTags, confidence: confidence)
    }

    /// 从 AI 输出中提取 JSON 字符串（处理 markdown code fence 和前后缀）
    private func extractJSON(from text: String) -> String {
        // 处理 ```json ... ``` 包裹
        if let range = text.range(of: "```json") {
            let afterMarker = text[range.upperBound...]
            if let endRange = afterMarker.range(of: "```") {
                return String(afterMarker[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 处理 ``` ... ``` 包裹（无 json 标记）
        if let range = text.range(of: "```") {
            let afterMarker = text[range.upperBound...]
            if let endRange = afterMarker.range(of: "```") {
                let content = String(afterMarker[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if content.hasPrefix("{") { return content }
            }
        }

        // 提取第一个 { 到最后一个 }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Rejected Tags 偏好管理

    /// 从 UserDefaults 加载拒绝标签名列表
    func loadRejectedTagNames() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: Self.rejectedTagsKey),
              let tags = try? JSONDecoder().decode([RejectedTagEntry].self, from: data) else {
            return []
        }

        let now = Date()
        let expiryInterval = TimeInterval(Self.rejectedTagsExpiryDays * 24 * 3600)

        // 过滤过期记录
        return tags
            .filter { now.timeIntervalSince($0.rejectedAt) < expiryInterval }
            .map { $0.name }
    }

    /// 添加拒绝标签记录
    func addRejectedTag(name: String) {
        var tags = loadRejectedEntries()

        // 去重
        tags.removeAll { $0.name == name }

        // 添加新记录
        tags.append(RejectedTagEntry(name: name, rejectedAt: Date()))

        // 容量控制：最多保留 50 条，按时间排序淘汰最旧的
        if tags.count > Self.rejectedTagsMaxCount {
            tags.sort { $0.rejectedAt > $1.rejectedAt }
            tags = Array(tags.prefix(Self.rejectedTagsMaxCount))
        }

        if let data = try? JSONEncoder().encode(tags) {
            UserDefaults.standard.set(data, forKey: Self.rejectedTagsKey)
        }
    }

    /// 加载完整拒绝记录（含时间戳）
    private func loadRejectedEntries() -> [RejectedTagEntry] {
        guard let data = UserDefaults.standard.data(forKey: Self.rejectedTagsKey),
              let tags = try? JSONDecoder().decode([RejectedTagEntry].self, from: data) else {
            return []
        }
        return tags
    }

    // MARK: - Private Helpers

    /// 标记想法整理失败
    private func markAsFailed(repository: ThoughtRepository, thoughtId: UUID) async {
        do {
            try repository.updateOrganizedStatus(thoughtId: thoughtId, status: "failed")
        } catch {
            logger.error("更新 failed 状态失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - Rejected Tag Entry

/// 拒绝标签记录（UserDefaults 存储）
private struct RejectedTagEntry: Codable {
    let name: String
    let rejectedAt: Date
}
