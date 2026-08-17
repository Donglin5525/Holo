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

    // MARK: - Rejected Tags 偏好索引

    private static let rejectedTagsKey = "rejectedAITags"
    private static let rejectedTagsMaxCount = 50
    private static let rejectedTagsExpiryDays = 90

    // MARK: - Init

    init(aiProvider: HoloBackendAIProvider? = nil) {
        self.aiProvider = aiProvider ?? HoloBackendAIProvider()
    }

    // MARK: - Organize Thought

    /// 对单条想法执行 AI 整理
    ///
    /// 错误契约（决定 Queue 如何处理）：
    /// - **不抛出**（return）：`notFound`/`parseFailed` 等「这条想法本身的问题」，已标记 failed，Queue 当作处理完毕跳过，不重试（避免浪费配额）
    /// - **抛出 `APIError.rateLimited`**：配额耗尽，Queue 应把当前条回退 pending + 当日整体暂停
    /// - **抛出其他错误**：网络/超时等可重试错误，Queue 按 5s/30s/120s 重试
    /// - Parameter thoughtId: 想法 UUID
    func organizeThought(thoughtId: UUID) async throws {
        let repository = ThoughtRepository()

        // 1. 更新状态为 processing
        do {
            try repository.updateOrganizedStatus(thoughtId: thoughtId, status: "processing")
        } catch {
            logger.error("更新 processing 状态失败：\(error.localizedDescription)")
            throw error
        }

        // 2. 读取想法内容（只传 ID，不跨线程持有 NSManagedObject）
        let thoughtContent: String
        let existingTagExamples: [String]
        let recentAITagLeaves: [String]
        let rejectedTags: [String]
        let activeTopicTitles: [String]

        do {
            guard let thought = try repository.fetchByIdInternal(thoughtId) else {
                logger.error("想法不存在：\(thoughtId)")
                try? repository.updateOrganizedStatus(thoughtId: thoughtId, status: "failed")
                return  // 想法已删除，标 failed 跳过，不重试
            }
            thoughtContent = thought.content
            existingTagExamples = repository.fetchUserRecognizedTagNames()
            recentAITagLeaves = (try? repository.fetchRecentAITagLeafNames()) ?? []
            rejectedTags = loadRejectedTagNames()
            activeTopicTitles = try TopicRepository().fetchClassificationTopics().map(\.title)
        } catch {
            logger.error("读取想法数据失败：\(error.localizedDescription)")
            throw error
        }

        // 3. 构建 prompt 并调用 AI
        let rawResponse: String
        do {
            // P2：语义候选召回（V3 教训：向量只进候选池，最终判断仍是 LLM + 白名单校验）
            // shadow 档计算并记录但不注入；off 档不计算
            let semanticCandidates: ThoughtSemanticCandidateEngine.SemanticCandidates? = await ThoughtSemanticCandidateEngine.candidates(
                for: thoughtId,
                content: thoughtContent
            )
            let injectSemanticTags = ThoughtSemanticCandidateMode.current == .inject
                && !(semanticCandidates?.neighborTags.isEmpty ?? true)
            if let semanticCandidates, !semanticCandidates.neighborTags.isEmpty {
                logger.info("语义候选（\(ThoughtSemanticCandidateMode.current.rawValue)）：\(semanticCandidates.neighborTags.joined(separator: ","))")
            }

            let messages: [ChatMessageDTO] = [.user(buildOrganizationPayload(
                thoughtContent: thoughtContent,
                activeTopics: activeTopicTitles,
                existingTags: existingTagExamples,
                recentAITags: recentAITagLeaves,
                rejectedTags: rejectedTags,
                semanticNeighborTags: injectSemanticTags ? semanticCandidates?.neighborTags ?? [] : nil
            ))]

            // rateLimited 等错误透传给 Queue（不在此 markAsFailed，由 Queue 决定回退 pending 或重试）
            rawResponse = try await callWithJSONMode(messages: messages)
        } catch {
            logger.error("AI 整理调用失败：\(error.localizedDescription)")
            throw error
        }

        // 4. 空响应判定为可重试错误（线上实测：推理模型思考吃满额度时 content 为空，
        //    约占 27% 调用；此前按 parseFailed 标 failed 不重试，是整理失败率高的主因）
        guard !rawResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.error("AI 返回空内容（推理思考吃满额度），想法：\(thoughtId)，转入重试")
            throw APIError.serverError("AI 整理返回空内容")
        }

        // 5. 解析 JSON
        guard let result = parseOrganizationResponse(rawResponse) else {
            logger.error("JSON 解析失败，原始响应：\(rawResponse.prefix(200))")
            try? repository.updateOrganizedStatus(thoughtId: thoughtId, status: "failed")
            return  // 解析失败标 failed，不重试（避免浪费配额）
        }

        // 6. 端侧强校验：主题只能来自约束池，未知前缀统一降级为虚拟“未分类”。
        let validated = ThoughtThemeConstraint.validate(
            selectedTopic: result.selectedTopic,
            suggestedTags: result.suggestedTags,
            activeTopics: activeTopicTitles
        )
        guard !validated.tagPaths.isEmpty else {
            // D-08′：调用成功但有效标签为空 = 正常空分类，不是失败。
            // 清旧未确认 AI 标签；主题独立判定（有效则照写，无效保持未分类）；写 organized。
            logger.info("AI 未形成有效标签（正常空分类），想法：\(thoughtId)，主题：\(validated.topicTitle ?? ThoughtThemeConstraint.unclassifiedTitle)")
            do {
                try repository.replaceUnconfirmedAITagAssignments(
                    thoughtId: thoughtId,
                    tagNames: [],
                    confidence: result.confidence
                )
                try TopicRepository().applyClassification(
                    thoughtId: thoughtId,
                    topicTitle: validated.topicTitle,
                    tagPaths: [],
                    confidence: result.confidence,
                    reason: result.reason
                )
                try repository.updateOrganizedStatus(thoughtId: thoughtId, status: "organized")
            } catch {
                logger.error("空分类结果写入失败：\(error.localizedDescription)")
                throw error
            }
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
            // 空分类想法同样进入语义召回池
            Task.detached(priority: .utility) {
                await ThoughtSemanticCandidateEngine.ensureEmbedded(thoughtId: thoughtId)
            }
            return
        }

        do {
            try repository.replaceUnconfirmedAITagAssignments(
                thoughtId: thoughtId,
                tagNames: validated.tagPaths,
                confidence: result.confidence
            )
            try TopicRepository().applyClassification(
                thoughtId: thoughtId,
                topicTitle: validated.topicTitle,
                tagPaths: validated.tagPaths,
                confidence: result.confidence,
                reason: result.reason
            )
        } catch {
            logger.error("写入主题分类结果失败：\(error.localizedDescription)")
            throw error
        }

        // 7. 更新状态为 organized
        do {
            try repository.updateOrganizedStatus(thoughtId: thoughtId, status: "organized")
        } catch {
            logger.error("更新 organized 状态失败：\(error.localizedDescription)")
        }
        logger.info("想法整理完成：\(thoughtId)，主题：\(validated.topicTitle ?? ThoughtThemeConstraint.unclassifiedTitle)，标签：\(validated.tagPaths.joined(separator: ", "))")

        // 7. 发送数据变更通知，让 UI 刷新
        NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)

        // 8. P2：分类成功后异步生成/更新该想法的语义向量（静默失败，不阻塞分类链路）
        Task.detached(priority: .utility) {
            await ThoughtSemanticCandidateEngine.ensureEmbedded(thoughtId: thoughtId)
        }
    }

    // MARK: - Reject / Confirm

    /// 仅拒绝本条（FR-06′）：assignment → rejectedAI，不写全局抑制偏好，不影响未来推荐
    /// - Parameter assignmentId: 分配 ID
    func rejectAssignmentCurrentOnly(assignmentId: UUID) {
        let repository = ThoughtRepository()
        do {
            try repository.rejectTagAssignment(assignmentId: assignmentId)
        } catch {
            logger.error("仅本条拒绝 AI 标签失败：\(error.localizedDescription)")
        }
    }

    /// 拒绝 AI 标签并写全局抑制偏好（原语义保留：仅「以后不要推荐」调用，90 天 / 最多 50 条）
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

    // MARK: - 全局标签管理

    /// 全局删除标签：所有想法上摘除 + 统一写拒绝偏好防 AI 再生
    /// 不 post 数据变更通知（与 rejectAndRecord 同惯例，由调用方负责 UI 刷新）
    /// - Parameters:
    ///   - name: 标签名
    ///   - repository: 数据仓储（默认主上下文，测试可注入内存仓储）
    /// - Returns: 删除结果（失败返回 nil 并记日志）
    @discardableResult
    func deleteTagEverywhere(name: String, repository: ThoughtRepository? = nil) -> TagDeletionResult? {
        let repository = repository ?? ThoughtRepository()
        do {
            let result = try repository.deleteTagGlobally(name: name)
            addRejectedTag(name: ThoughtTagNormalizer.displayName(name))
            logger.info("全局删除标签：\(name)，摘除 \(result.removedAssignmentCount) 条 assignment")
            return result
        } catch {
            logger.error("全局删除标签失败（\(name)）：\(error.localizedDescription)")
            return nil
        }
    }

    /// 全局重命名标签：旧名写拒绝偏好（防 AI 重打造成分裂），新名从拒绝偏好移除（避免与认可池信号矛盾）
    /// 多级标签走子树语义：「工作」改名会同步「工作/Holo」等全部子路径
    /// 不 post 数据变更通知（由调用方负责 UI 刷新）
    /// - Parameters:
    ///   - oldName: 原标签名
    ///   - newName: 新标签名
    ///   - repository: 数据仓储（默认主上下文，测试可注入内存仓储）
    /// - Returns: 重命名结果（renamed / merged，供 UI 反馈文案区分）
    @discardableResult
    func renameTagEverywhere(from oldName: String, to newName: String, repository: ThoughtRepository? = nil) throws -> TagRenameOutcome {
        let repository = repository ?? ThoughtRepository()
        // 子树重命名（含自身与全部子路径），返回根路径的 renamed/merged 语义
        let rootOutcome = try repository.renameTagPathPrefix(from: oldName, to: newName)
        let oldDisplay = ThoughtTagNormalizer.displayName(oldName)
        let newDisplay = ThoughtTagNormalizer.displayName(newName)
        // 归一化同 key（仅大小写差异改名）时新旧名同源，无需动拒绝偏好
        if ThoughtTagNormalizer.key(oldDisplay) != ThoughtTagNormalizer.key(newDisplay) {
            addRejectedTag(name: oldDisplay)
            removeRejectedTag(name: newDisplay)
        }
        logger.info("全局重命名标签：\(oldName) → \(newName)（\(rootOutcome == .merged ? "合并" : "改名")）")
        return rootOutcome
    }

    // MARK: - AI 调用（JSON mode）

    /// 通过 JSON mode 调用 thought_organization purpose
    /// 复用 HoloBackendAIProvider 的 buildRequest（支持 responseFormat）
    private func callWithJSONMode(messages: [ChatMessageDTO]) async throws -> String {
        // 后端按 purpose 注入 v3 system prompt；结构化主题/标签上下文已经放在 user JSON 中。
        return try await aiProvider.chat(messages: messages, purpose: .thoughtOrganization)
    }

    // MARK: - JSON 解析

    /// AI 整理响应结构
    struct OrganizationResponse {
        let selectedTopic: String?
        let suggestedTags: [String]
        let confidence: Double
        /// 一句话分类依据（后端 v4 prompt 100% 返回，线上 35/35 样本验证）
        let reason: String?
    }

    /// 解析 AI 返回的 JSON
    private func parseOrganizationResponse(_ text: String) -> OrganizationResponse? {
        let jsonString = extractJSON(from: text)

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // 提取 suggestedTags：允许空数组（D-08′ 正常空分类），但字段必须存在且类型合法
        guard let tags = json["suggestedTags"] as? [String] else {
            return nil
        }

        // 过滤空字符串和过长标签；过滤后为空同样视为有效空分类（非解析失败）
        let filteredTags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 60 }

        let confidence = (json["confidence"] as? Double) ?? 0.5

        let selectedTopic = (json["selectedTopic"] as? String)
            ?? (json["topic"] as? String)
            ?? (json["topicTitle"] as? String)

        let reasonTrimmed = (json["reason"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reason = reasonTrimmed.isEmpty ? nil : String(reasonTrimmed.prefix(120))

        return OrganizationResponse(
            selectedTopic: selectedTopic,
            suggestedTags: filteredTags,
            confidence: confidence,
            reason: reason
        )
    }

    /// 把用户数据编码成 JSON，避免正文中的自然语言被误当成 Prompt 指令。
    /// recentAITags：近 90 天 AI 标签叶段池，后端 v4 复用硬约束的原料（不传则历史 AI 标签不参与复用，标签易发散）
    /// semanticNeighborTags：P2 语义近邻标签（可选，后端 v5 prompt 才读取；不传不影响旧版后端）
    private func buildOrganizationPayload(
        thoughtContent: String,
        activeTopics: [String],
        existingTags: [String],
        recentAITags: [String],
        rejectedTags: [String],
        semanticNeighborTags: [String]? = nil
    ) -> String {
        var payload: [String: Any] = [
            "activeTopics": activeTopics,
            "existingTags": existingTags,
            "recentAITags": recentAITags,
            "rejectedTags": rejectedTags,
            "thoughtContent": thoughtContent
        ]
        if let semanticNeighborTags, !semanticNeighborTags.isEmpty {
            payload["semanticNeighborTags"] = semanticNeighborTags
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"activeTopics\":[],\"thoughtContent\":\"\"}"
        }
        return json
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

    /// 添加拒绝标签记录（按归一化 key 去重，防 "ai能力"/"AI能力" 变体重复）
    func addRejectedTag(name: String) {
        var tags = loadRejectedEntries()
        let key = ThoughtTagNormalizer.key(name)

        // 去重
        tags.removeAll { ThoughtTagNormalizer.key($0.name) == key }

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

    /// 从拒绝偏好移除标签名（按归一化 key 匹配）
    func removeRejectedTag(name: String) {
        var tags = loadRejectedEntries()
        let key = ThoughtTagNormalizer.key(name)
        let beforeCount = tags.count
        tags.removeAll { ThoughtTagNormalizer.key($0.name) == key }
        guard tags.count != beforeCount else { return }

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
