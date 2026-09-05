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

    /// 对单条想法执行 V2 自动整理（2026-09-05 方案 §5/§6/§7）。
    ///
    /// 流程：本地跳过判定 → 目录构造 → 脱敏 → 版本标记 → 调用无状态端点
    /// → 响应逐字复核 → 事务落库（版本一致性校验）。不做主题分类（Topic 体系保留为手动功能）。
    ///
    /// 错误契约（决定 Queue 如何处理）：
    /// - **不抛出**（return）：终态完成（no_evidence / deferred 终态 / 想法不存在 / 协议错位标 failed）
    /// - **抛出 `APIError.rateLimited`**：日预算耗尽或 V2 端点未开放，Queue 当日暂停
    /// - **抛出其他错误**：网络/超时等可重试错误，Queue 按重试规则处理
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

        // 2. 读取想法（只传 ID，不跨线程持有 NSManagedObject）
        let content: String
        do {
            guard let thought = try repository.fetchByIdInternal(thoughtId) else {
                logger.error("想法不存在：\(thoughtId)")
                try? repository.updateOrganizedStatus(thoughtId: thoughtId, status: "failed")
                return  // 想法已删除，标 failed 跳过，不重试
            }
            content = thought.content
        } catch {
            logger.error("读取想法数据失败：\(error.localizedDescription)")
            throw error
        }

        // 3. 本地跳过：正文超限（不截断后假装完整理解）与无可分析内容（方案 §5.4）
        if ThoughtIndexV2Policy.isTooLarge(content) || ThoughtIndexV2Policy.shouldSkipLocally(content) {
            try? repository.updateOrganizedStatus(thoughtId: thoughtId, status: "skipped")
            return
        }

        // 4. 版本判定：同正文版本已完成且引擎未升级 → 不重跑（方案 §7.5）
        let textHash = ThoughtTagIndexProjection.textHash(content)
        do {
            guard let thought = try repository.fetchByIdInternal(thoughtId) else { return }
            if thought.indexCompletedHash == textHash,
               thought.indexEngineVersion == ThoughtIndexV2Policy.engineVersion {
                try repository.updateOrganizedStatus(thoughtId: thoughtId, status: "organized")
                return
            }
        } catch {
            throw error
        }

        // 5. 构造目录与请求（脱敏只作用于上传文本；hash 一律基于原文）
        let catalog: ThoughtIndexCatalogBuilder.Result
        do {
            let snapshots = try repository.fetchTagIndexSnapshots()
            catalog = ThoughtIndexCatalogBuilder.build(
                snapshots: snapshots,
                legacyRejectedNames: loadRejectedTagNames()
            )
        } catch {
            logger.error("构造整理目录失败：\(error.localizedDescription)")
            throw error
        }
        let redactedText = ThoughtIndexV2Policy.redactedText(forUpload: content)
        let operationId = UUID()

        do {
            try repository.markIndexRequested(
                thoughtId: thoughtId, textHash: textHash, operationId: operationId
            )
        } catch {
            throw error
        }

        // 6. 调用无状态整理端点
        let response: ThoughtOrganizeResponseDTO
        do {
            response = try await aiProvider.organizeThoughtIndex(ThoughtOrganizeRequestDTO(
                schemaVersion: ThoughtIndexV2Policy.schemaVersion,
                operationId: operationId.uuidString,
                textRevision: ThoughtIndexV2Policy.textRevision(forRedactedText: redactedText),
                catalogRevision: catalog.revision,
                text: redactedText,
                catalog: catalog.entries,
                blockedRefs: catalog.blockedRefs,
                blockedNames: catalog.blockedNames
            ))
        } catch let error as APIError {
            // 服务端语义错误的定向映射（网络类错误原样透传给 Queue 重试）
            switch error {
            case .backendError(_, let code, _, _) where code == "PRIVACY_ROUTE_UNVERIFIED" || code == "THOUGHT_ORGANIZE_DISABLED":
                // V2 隐私路由未核实/端点未开放：复用配额暂停通道当日挂起（App 重启再探），
                // 不降级到旧的含内容日志整理通道（方案 §11.1）
                logger.warning("V2 整理端点未开放（\(code ?? "")），当日挂起")
                throw APIError.rateLimited(code)
            default:
                throw error
            }
        }

        // 7. 响应协议校验
        guard response.schemaVersion == ThoughtIndexV2Policy.schemaVersion,
              response.operationId == operationId.uuidString else {
            logger.error("整理响应协议错位，想法：\(thoughtId)")
            try? repository.updateOrganizedStatus(thoughtId: thoughtId, status: "failed")
            return
        }

        // 8. deferred 分支（方案 §6.1：固定 reasonCode 的合法完成态）
        if response.outcome == "deferred" {
            switch response.reasonCode {
            case "moderation_blocked", "catalog_budget_exceeded":
                // 终态：写完成标记防重跑；保留无标签状态
                try? repository.completeIndexWithoutTags(thoughtId: thoughtId, textHash: textHash)
                logger.info("整理按终态暂缓（\(response.reasonCode ?? "")）：\(thoughtId)")
                return
            case "budget_exceeded":
                // 主体级日预算耗尽：当日暂停（Queue 沿 rateLimited 通道）
                throw APIError.rateLimited("budget_exceeded")
            default:
                // 未知暂缓原因：作为可重试错误交给队列统一规则
                throw APIError.serverError("整理暂缓：\(response.reasonCode ?? "unknown")")
            }
        }

        // 9. quote 逐字复核（UTF-16 范围核验；失败的 assignment 丢弃，不整体失败）
        let outcomes = Self.validatedOutcomes(from: response, redactedText: redactedText, catalog: catalog)

        // 10. 原子落库（事务内校验想法仍存在、正文版本一致、授权有效）
        let applied: Bool
        do {
            applied = try repository.applyThoughtIndexV2Result(
                thoughtId: thoughtId,
                textHash: textHash,
                outcome: ThoughtIndexTaskOutcome(
                    assignments: outcomes,
                    catalogCoverage: response.catalogCoverage ?? "full"
                ),
                engineVersion: ThoughtIndexV2Policy.engineVersion
            )
        } catch {
            logger.error("整理结果落库失败：\(error.localizedDescription)")
            throw error
        }
        guard applied else {
            // 正文在请求期间被编辑：丢弃结果，按最新正文回 pending 重排（方案 §7.5）
            logger.info("正文版本已变，丢弃迟到结果并回 pending：\(thoughtId)")
            try? repository.updateOrganizedStatus(thoughtId: thoughtId, status: "pending")
            return
        }

        logger.info("想法整理完成：\(thoughtId)，标签 \(outcomes.count) 个（coverage: \(response.catalogCoverage ?? "full")）")
        NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
    }

    /// 响应 → 落库结果：existingRef 经映射还原本地词条；newConcept 做名称约束；
    /// quote 按上传文本逐字复核（UTF-16 范围优先，缺失范围时全文包含校验）
    private static func validatedOutcomes(
        from response: ThoughtOrganizeResponseDTO,
        redactedText: String,
        catalog: ThoughtIndexCatalogBuilder.Result
    ) -> [ThoughtIndexAssignmentOutcome] {
        var outcomes: [ThoughtIndexAssignmentOutcome] = []
        for assignment in response.assignments ?? [] {
            guard let quote = assignment.quote, !quote.isEmpty, quote.utf16.count <= 80 else { continue }

            if let range = assignment.rangeUTF16, range.count == 2 {
                let location = range[0]
                let length = range[1]
                guard location >= 0, length >= 0,
                      location + length <= redactedText.utf16.count else { continue }
                let start = redactedText.index(redactedText.startIndex, offsetBy: location)
                let end = redactedText.index(start, offsetBy: length)
                guard redactedText[start..<end] == Substring(quote) else { continue }
            } else if !redactedText.contains(quote) {
                continue
            }

            if let ref = assignment.existingRef, let tagId = catalog.refToTagId[ref] {
                outcomes.append(ThoughtIndexAssignmentOutcome(
                    concept: .existing(tagId: tagId),
                    evidenceQuote: quote
                ))
            } else if let concept = assignment.newConcept {
                let name = concept.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 32, !name.contains("/") else { continue }
                outcomes.append(ThoughtIndexAssignmentOutcome(
                    concept: .newConcept(name: name, definition: concept.definition ?? ""),
                    evidenceQuote: quote
                ))
            }
        }
        return outcomes
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

    /// 拒绝 AI 标签并全局禁止自动使用该概念（V2 方案 §1.2：不设 90 天自动过期）
    /// 落在词条 autoSuggestionBlocked 上（手动添加不受影响）；词条不存在时回落 V1 偏好名单
    /// - Parameter assignmentId: 分配 ID
    func rejectAndRecord(assignmentId: UUID, tagName: String) {
        let repository = ThoughtRepository()
        do {
            try repository.rejectTagAssignment(assignmentId: assignmentId)
            if let tagId = repository.fetchTagIdByName(tagName) {
                try repository.setAutoSuggestionBlocked(tagId: tagId, blocked: true)
            } else {
                addRejectedTag(name: tagName)
            }
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

    // MARK: - Rejected Tags 偏好管理

    /// 从 UserDefaults 加载拒绝标签名列表
    /// V2 语义：作为目录构造的 blockedNames/blockedRefs 输入（用户明确拒绝过的概念不复加）
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
