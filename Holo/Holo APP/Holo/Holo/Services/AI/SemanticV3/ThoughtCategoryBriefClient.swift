//
//  ThoughtCategoryBriefClient.swift
//  Holo
//
//  归档类别理解器客户端（2026-10-12 主题双通道·零打扰）
//
//  成员证据（用户确认优先）+ 用户移出反证 → 类别定义/排除边界，存本机语义库
//  （AI 派生不进 CloudKit）。与 verifier/summary 同纪律：客户端二次校验
//  （definition 界限/exclusions 界限/evidence 逐字）后才落库。
//
//  铁律（对抗性审查 R1-1）：边界只由用户动作改写——
//  · 排除项只增不减：新版本 exclusions ⊇ 旧版本；
//  · 新增排除只允许发生在「用户有新移出」时；无新移出时 AI 提议的新排除一律丢弃。
//

import Foundation

// MARK: - 传输 DTO（与后端 categoryBriefSchema 契约对齐）

nonisolated struct ThoughtCategoryBriefRequestDTO: Codable {
    struct Member: Codable { let ref: String; let text: String; let source: String }
    struct Removal: Codable { let ref: String; let text: String }
    struct Topic: Codable {
        let title: String
        var userDefinition: String? = nil
        var currentBrief: String? = nil
    }
    let schemaVersion: Int
    let operationId: String
    let engineVersion: String
    let topic: Topic
    let members: [Member]
    let removals: [Removal]
}

nonisolated struct ThoughtCategoryBriefResponseDTO: Codable {
    struct Evidence: Codable { let ref: String; let quote: String }
    struct Brief: Codable { let definition: String; let exclusions: [String] }
    let schemaVersion: Int
    let operationId: String
    var brief: Brief? = nil
    var evidence: [Evidence]? = nil
    var outcome: String? = nil
    var reasonCode: String? = nil
}

/// 落库前的干净结果（逐字校验通过）
nonisolated struct ThoughtCategoryBriefContent: Equatable {
    var definition: String
    var exclusions: [String]
}

nonisolated enum ThoughtCategoryBriefClient {
    static let engineVersion = ThoughtTopicVerifier.engineVersion
    static let definitionMaxUTF16 = 240
    static let exclusionMaxUTF16 = 40
    static let exclusionMaxCount = 6
    static let quoteMaxUTF16 = 80

    enum BriefError: Error {
        case notEnoughEvidence
        case contractViolation(reason: String)
    }

    /// 组装请求：成员 ≤10（截断在调用方完成），removals ≤3。
    static func makeRequest(title: String,
                            userDefinition: String?,
                            currentBrief: String?,
                            members: [(ref: String, text: String, source: String)],
                            removals: [(ref: String, text: String)]) -> ThoughtCategoryBriefRequestDTO? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, members.count >= 3 else { return nil }
        return .init(
            schemaVersion: 1,
            operationId: UUID().uuidString.lowercased(),
            engineVersion: engineVersion,
            topic: .init(title: String(trimmedTitle.prefix(32)),
                         userDefinition: userDefinition,
                         currentBrief: currentBrief),
            members: members.map { .init(ref: $0.ref, text: $0.text, source: $0.source) },
            removals: removals.map { .init(ref: $0.ref, text: $0.text) })
    }

    /// 客户端二次校验（不信任网络层）：definition 界限、exclusions 界限、evidence 逐字回源。
    static func validatedContent(from response: ThoughtCategoryBriefResponseDTO,
                                 request: ThoughtCategoryBriefRequestDTO) -> ThoughtCategoryBriefContent? {
        guard response.schemaVersion == 1, response.operationId == request.operationId,
              let brief = response.brief else { return nil }
        let definition = brief.definition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !definition.isEmpty, definition.utf16.count <= definitionMaxUTF16 else { return nil }
        var exclusions: [String] = []
        for raw in brief.exclusions {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.utf16.count <= exclusionMaxUTF16 else { return nil }
            if !trimmed.isEmpty, !exclusions.contains(trimmed) { exclusions.append(trimmed) }
        }
        guard exclusions.count <= exclusionMaxCount else { return nil }
        let evidence = response.evidence ?? []
        guard (1...4).contains(evidence.count) else { return nil }
        let textByRef = Dictionary(request.members.map { ($0.ref, $0.text) },
                                   uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        for item in evidence {
            guard seen.insert(item.ref).inserted, let text = textByRef[item.ref],
                  !item.quote.isEmpty, item.quote.utf16.count <= quoteMaxUTF16,
                  text.contains(item.quote) else { return nil }
        }
        return .init(definition: definition, exclusions: exclusions)
    }

    /// 铁律合并（边界只由用户动作改写）：
    /// · 恒等：结果 ⊇ 旧排除项（永不删除、永不改写措辞）；
    /// · 无新移出（newRemovals == 0）→ 只保留旧排除项，AI 提议的新排除全部丢弃；
    /// · 有新移出 → 允许追加 AI 从移出反证归纳的新排除。
    static func mergedExclusions(previous: [String], proposed: [String], newRemovalCount: Int) -> [String] {
        var merged = previous
        guard newRemovalCount > 0 else { return merged }
        for item in proposed where !merged.contains(item) {
            if merged.count >= exclusionMaxCount { break }
            merged.append(item)
        }
        return merged
    }

    /// 端到端：请求 → 校验 → 铁律合并 → 落本机语义库（version 递增）。
    /// totalMemberCount/totalRemovalCount 是主题当前的证据总量（非样本数），
    /// 与上一版基数之差决定「是否有新移出」（新排除的唯一合法来源）。
    /// 任何失败抛错由调用方静默跳过本次维护（下一个节拍再试）。
    @discardableResult
    static func refreshBrief(topicID: UUID,
                             record: ThoughtSemanticStore.CategoryBriefRecord?,
                             title: String,
                             userDefinition: String?,
                             members: [(ref: String, text: String, source: String)],
                             removals: [(ref: String, text: String)],
                             totalMemberCount: Int,
                             totalRemovalCount: Int,
                             provider: HoloBackendAIProvider,
                             store: ThoughtSemanticStore) async throws -> ThoughtSemanticStore.CategoryBriefRecord {
        guard let request = makeRequest(title: title,
                                        userDefinition: userDefinition,
                                        currentBrief: record?.definition,
                                        members: members,
                                        removals: removals) else {
            throw BriefError.notEnoughEvidence
        }
        let newRemovalCount = max(0, totalRemovalCount - (record?.basisRemovalCount ?? 0))
        let response = try await provider.categoryBrief(request)
        guard let content = validatedContent(from: response, request: request) else {
            throw BriefError.contractViolation(reason: "content")
        }
        let merged = mergedExclusions(previous: record?.exclusions ?? [],
                                      proposed: content.exclusions,
                                      newRemovalCount: newRemovalCount)
        let saved = ThoughtSemanticStore.CategoryBriefRecord(
            topicID: topicID,
            version: (record?.version ?? 0) + 1,
            definition: content.definition,
            exclusions: merged,
            basisMemberCount: totalMemberCount,
            basisRemovalCount: totalRemovalCount,
            updatedAt: Date())
        try await store.saveCategoryBrief(saved)
        return saved
    }
}
