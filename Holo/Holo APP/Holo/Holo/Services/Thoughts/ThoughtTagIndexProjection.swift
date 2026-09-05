//
//  ThoughtTagIndexProjection.swift
//  Holo
//
//  想法自动整理 V2 统一有效关系投影（2026-09-05 方案 §7.3）
//
//  所有展示、筛选、计数、词表构造和 AI 数据查询都通过本投影得到有效关系；
//  不再各自直接读 source/isVisible 或「用户认可标签查询」单口径。
//
//  纯逻辑组件：输入值类型快照，不持有 NSManagedObject，可独立测试。
//

import Foundation
import CryptoKit

// MARK: - 快照值类型

/// ThoughtTag 的索引语义快照（从托管对象一次性读出）
struct ThoughtTagIndexSnapshot: Equatable {
    let id: UUID
    let name: String
    let semanticName: String?
    let semanticDefinition: String?
    let aliases: [String]
    let indexKind: ThoughtTagIndexKind?
    let nameLockedByUser: Bool
    let mergedIntoTagID: UUID?
    let autoSuggestionBlocked: Bool
    let autoCollectionHidden: Bool

    /// V2 平面展示名：语义名优先，缺失回落旧路径叶子段
    var displayName: String {
        if let semanticName, !semanticName.isEmpty { return semanticName }
        return ThoughtTagNormalizer.lastSegment(name)
    }
}

/// ThoughtTagAssignment 的索引状态快照
struct ThoughtAssignmentIndexSnapshot: Equatable {
    let id: UUID
    let thoughtId: UUID
    let tagId: UUID
    let source: ThoughtTagAssignment.Source
    let indexVersion: Int16
    let indexState: ThoughtIndexState?
    let basisTextHash: String?
    let evidenceQuote: String?
}

// MARK: - 枚举

/// 词条身份来源（ThoughtTag.indexKind）
enum ThoughtTagIndexKind: String, CaseIterable {
    case user         // 用户手动标签 / 已确认 AI 标签（可复用、可改名锁定）
    case auto         // V2 完整对齐产生的自动概念（可复用）
    case provisional  // 仅经名称召回路径产生的新概念（本条可用，不进全局词典）
    case legacy       // V1 旧 AI 词条（不进 V2 词典与合集，逐条重验证）
}

/// 关系索引状态（ThoughtTagAssignment.indexState）
enum ThoughtIndexState: String {
    case active
    case superseded
    case legacy
}

// MARK: - 投影结果

/// 一条「当前有效」的想法-概念关系（canonical 去重后）
struct EffectiveTagProjection: Equatable, Identifiable {
    let canonicalTagId: UUID
    let displayName: String
    /// 用户明确决定（manual/inline/confirmedAI）——AI 无权覆盖
    let isUserDecision: Bool
    /// V2 有效自动索引（两阶段+校验通过且正文版本一致）
    let isAutoIndex: Bool
    let evidenceQuote: String?

    var id: UUID { canonicalTagId }
}

// MARK: - 投影

nonisolated enum ThoughtTagIndexProjection {

    /// V2 索引版本常量：只有 indexVersion==2 的自动关系参与有效集（方案 §7.2）
    static let currentIndexVersion: Int16 = 2

    /// canonical 解析最大跳数（mergedIntoTagID 链防环）
    private static let maxRedirectHops = 8

    /// 正文版本标记：可见纯文本的 SHA-256 前 16 位 hex。
    /// 打标签本身不改变 content，不能用 updatedAt 代替（方案 §7.5）。
    static func textHash(_ content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// 正文 hash 进程内缓存（列表/合集批量判定用；容量截断防膨胀）
    private static var hashCache: [String: String] = [:]
    private static let hashCacheLimit = 800
    static func cachedTextHash(_ content: String) -> String {
        if let cached = hashCache[content] { return cached }
        let value = textHash(content)
        if hashCache.count >= hashCacheLimit {
            hashCache.removeAll(keepingCapacity: true)
        }
        hashCache[content] = value
        return value
    }

    /// 概念 canonical 身份：沿 mergedIntoTagID 链解析到最终目标；环/断链回落自身（方案 §7.4）
    static func canonicalTagId(_ tagId: UUID, tags: [UUID: ThoughtTagIndexSnapshot]) -> UUID {
        var current = tagId
        var hops = 0
        while hops < maxRedirectHops,
              let redirect = tags[current]?.mergedIntoTagID,
              redirect != current,
              tags[redirect] != nil {
            current = redirect
            hops += 1
        }
        return current
    }

    /**
     * 统一有效关系读取（方案 §7.3 规则）：
     * 1. manual/inline/confirmedAI 有效（用户明确决定，AI 无权覆盖）；
     * 2. source=ai 且 indexVersion=2、indexState=active、basisTextHash==当前正文 hash 才是有效自动索引；
     * 3. 旧 source=ai（indexVersion<2）一律 legacy，不进有效集；
     * 4. 相同 canonical 概念只保留一次（用户决定优先于自动）；
     * 5. 被全局拒绝（autoSuggestionBlocked）或已重定向的词条不产生自动入口。
     */
    static func effectiveTags(
        assignments: [ThoughtAssignmentIndexSnapshot],
        tags: [UUID: ThoughtTagIndexSnapshot],
        currentTextHash: String
    ) -> [EffectiveTagProjection] {
        var byCanonical: [UUID: EffectiveTagProjection] = [:]

        func userWeight(_ projection: EffectiveTagProjection) -> Int {
            projection.isUserDecision ? 1 : 0
        }

        for assignment in assignments {
            guard let tag = tags[assignment.tagId] else { continue }
            let canonical = canonicalTagId(assignment.tagId, tags: tags)
            guard let canonicalTag = tags[canonical] else { continue }

            let projection: EffectiveTagProjection?
            switch assignment.source {
            case .manual, .inline, .confirmedAI:
                projection = EffectiveTagProjection(
                    canonicalTagId: canonical,
                    displayName: canonicalTag.displayName,
                    isUserDecision: true,
                    isAutoIndex: false,
                    evidenceQuote: nil
                )
            case .ai:
                // V2 有效自动索引四要素 + 词条可用性
                let isValidAuto = assignment.indexVersion == currentIndexVersion
                    && assignment.indexState == .active
                    && assignment.basisTextHash == currentTextHash
                    && !canonicalTag.autoSuggestionBlocked
                    && tag.mergedIntoTagID == nil
                guard isValidAuto else { continue }
                projection = EffectiveTagProjection(
                    canonicalTagId: canonical,
                    displayName: canonicalTag.displayName,
                    isUserDecision: false,
                    isAutoIndex: true,
                    evidenceQuote: assignment.evidenceQuote
                )
            case .rejectedAI:
                // 拒绝事实本身不产生有效关系；对自动复加的抑制在目录构造/落库校验中执行
                continue
            }

            guard let candidate = projection else { continue }
            if let existing = byCanonical[candidate.canonicalTagId] {
                // 同概念双来源：用户决定胜出；同为自动保留先到的（去重语义稳定）
                if userWeight(candidate) > userWeight(existing) {
                    byCanonical[candidate.canonicalTagId] = candidate
                }
            } else {
                byCanonical[candidate.canonicalTagId] = candidate
            }
        }

        return byCanonical.values.sorted { $0.displayName < $1.displayName }
    }

    /**
     * 自动合集统计（方案 §8.3）：同一 canonical 概念的有效自动关系
     * 按「不同 Thought ID」计数；≥ minCount（默认 3）且未被隐藏才成为合集入口。
     * 输入为全库有效自动关系与其所属想法的当前正文 hash。
     */
    struct AutoCollection: Identifiable, Equatable {
        let canonicalTagId: UUID
        let displayName: String
        /// canonical 词条的完整路径名（ThoughtTag.name 原值，供标签筛选通道使用）
        let tagName: String
        let thoughtIds: Set<UUID>
        /// 最近一条关联想法的创建时间（合集排序用，不按 AI 重跑时间刷新）
        let latestThoughtAt: Date?

        var id: UUID { canonicalTagId }
        var count: Int { thoughtIds.count }
    }

    static func autoCollections(
        effectiveAutoRelations: [ThoughtAssignmentIndexSnapshot],
        thoughtContentHashes: [UUID: String],   // thoughtId → hash(content)
        thoughtCreatedAt: [UUID: Date],
        tags: [UUID: ThoughtTagIndexSnapshot],
        minCount: Int = 3
    ) -> [AutoCollection] {
        var byCanonical: [UUID: Set<UUID>] = [:]
        var latest: [UUID: Date] = [:]
        var names: [UUID: String] = [:]
        var tagNames: [UUID: String] = [:]

        for relation in effectiveAutoRelations {
            let canonical = canonicalTagId(relation.tagId, tags: tags)
            guard let canonicalTag = tags[canonical] else { continue }
            guard !canonicalTag.autoCollectionHidden else { continue }
            guard !canonicalTag.autoSuggestionBlocked else { continue }
            // 该想法正文已变（关系失效）则不计入
            guard let currentHash = thoughtContentHashes[relation.thoughtId],
                  currentHash == relation.basisTextHash else { continue }

            byCanonical[canonical, default: []].insert(relation.thoughtId)
            if let createdAt = thoughtCreatedAt[relation.thoughtId] {
                if let existing = latest[canonical] {
                    latest[canonical] = max(existing, createdAt)
                } else {
                    latest[canonical] = createdAt
                }
            }
            names[canonical] = canonicalTag.displayName
            tagNames[canonical] = canonicalTag.name
        }

        return byCanonical.compactMap { canonical, thoughtIds in
            guard thoughtIds.count >= minCount else { return nil }
            return AutoCollection(
                canonicalTagId: canonical,
                displayName: names[canonical] ?? "",
                tagName: tagNames[canonical] ?? names[canonical] ?? "",
                thoughtIds: thoughtIds,
                latestThoughtAt: latest[canonical]
            )
        }
        .sorted { lhs, rhs in
            if let l = lhs.latestThoughtAt, let r = rhs.latestThoughtAt, l != r {
                return l > r
            }
            return lhs.displayName < rhs.displayName
        }
    }

    /// V2 可复用词典词条资格（目录构造用，方案 §5.5/§8.2）：
    /// legacy 词条与被重定向词条不进目录；provisional 不进目录（未完成完整对齐）。
    static func isEligibleForCatalog(_ tag: ThoughtTagIndexSnapshot) -> Bool {
        guard tag.mergedIntoTagID == nil else { return false }
        switch tag.indexKind {
        case .user, .auto:
            return true
        case .provisional, .legacy, nil:
            return false
        }
    }
}
