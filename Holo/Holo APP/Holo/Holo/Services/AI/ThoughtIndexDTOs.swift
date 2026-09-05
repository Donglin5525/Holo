//
//  ThoughtIndexDTOs.swift
//  Holo
//
//  想法自动整理 V2 协议 DTO 与目录构造器（2026-09-05 方案 §6.1/§5.5）
//

import Foundation

// MARK: - 请求

struct ThoughtOrganizeRequestDTO: Encodable {
    let schemaVersion: Int
    let operationId: String
    let textRevision: String
    let catalogRevision: String
    let text: String
    let catalog: [CatalogEntry]
    let blockedRefs: [Int]
    let blockedNames: [String]

    struct CatalogEntry: Encodable {
        let ref: Int
        let name: String
        let definition: String?
        let aliases: [String]
        let path: String?
        let userNamed: Bool
    }
}

// MARK: - 响应

struct ThoughtOrganizeResponseDTO: Decodable {
    let schemaVersion: Int
    let operationId: String
    let textRevision: String
    let catalogRevision: String
    /// tagged / no_evidence / deferred
    let outcome: String
    /// full / names_recalled / none
    let catalogCoverage: String?
    /// deferred 的固定原因码（moderation_blocked / catalog_budget_exceeded / budget_exceeded）
    let reasonCode: String?
    let assignments: [Assignment]?
    let policyVersion: String?

    struct Assignment: Decodable {
        let anchorRef: Int?
        let existingRef: Int?
        let newConcept: NewConcept?
        let relation: String?
        let quote: String?
        /// [location, length]，UTF-16 单位，针对上传的脱敏文本
        let rangeUTF16: [Int]?
    }

    struct NewConcept: Decodable {
        let name: String
        let definition: String?
    }
}

// MARK: - 目录构造器

/// 从词条快照构造请求目录：ref 编号映射、用户拒绝约束、版本指纹。
/// 纯逻辑，不触碰 Core Data。
nonisolated enum ThoughtIndexCatalogBuilder {

    struct Result {
        let entries: [ThoughtOrganizeRequestDTO.CatalogEntry]
        /// ref → 本地 ThoughtTag UUID（仅手机内存中保存，不上传）
        let refToTagId: [Int: UUID]
        let blockedRefs: [Int]
        let blockedNames: [String]
        let revision: String
    }

    /// - Parameters:
    ///   - snapshots: 全库词条快照
    ///   - legacyRejectedNames: V1 遗留拒绝偏好名（UserDefaults rejectedAITags；
    ///           有对应词条的映射为 blockedRefs，无词条的进入 blockedNames）
    static func build(
        snapshots: [ThoughtTagIndexSnapshot],
        legacyRejectedNames: [String]
    ) -> Result {
        // 词条资格：user/auto；排序稳定（用户词条在前，名称升序）
        let eligible = snapshots
            .filter { ThoughtTagIndexProjection.isEligibleForCatalog($0) }
            .sorted { lhs, rhs in
                let lhsUser = lhs.indexKind == .user
                let rhsUser = rhs.indexKind == .user
                if lhsUser != rhsUser { return lhsUser }
                return lhs.displayName < rhs.displayName
            }

        var entries: [ThoughtOrganizeRequestDTO.CatalogEntry] = []
        var refToTagId: [Int: UUID] = [:]
        var nameToRef: [String: Int] = [:]
        var fingerprintParts: [String] = []

        for (index, snapshot) in eligible.enumerated() {
            let ref = index + 1
            let hasPath = snapshot.name.contains("/")
            let entry = ThoughtOrganizeRequestDTO.CatalogEntry(
                ref: ref,
                name: snapshot.displayName,
                definition: snapshot.semanticDefinition,
                aliases: Array(snapshot.aliases.prefix(3)),
                path: hasPath ? snapshot.name : nil,
                userNamed: snapshot.indexKind == .user
            )
            entries.append(entry)
            refToTagId[ref] = snapshot.id
            nameToRef[normalized(entry.name)] = ref
            for alias in entry.aliases {
                nameToRef[normalized(alias)] = ref
            }
            fingerprintParts.append("\(snapshot.id.uuidString)|\(entry.name)|\(snapshot.indexKind?.rawValue ?? "")")
        }

        // 全局拒绝约束：autoSuggestionBlocked 词条进目录并显式标注（模型不得复用）
        var blockedRefs = Set<Int>()
        for snapshot in eligible where snapshot.autoSuggestionBlocked {
            if let ref = refToTagId.first(where: { $0.value == snapshot.id })?.key {
                blockedRefs.insert(ref)
            }
        }
        // V1 遗留拒绝名单：映射到词条 ref；无词条的表达进 blockedNames（仅约束，不拼日志）
        var blockedNames = Set<String>()
        for name in legacyRejectedNames {
            let key = normalized(name)
            if let ref = nameToRef[key] {
                blockedRefs.insert(ref)
            } else if !key.isEmpty {
                blockedNames.insert(key)
            }
        }

        let revision = ThoughtIndexV2Policy.catalogRevision(
            entryCount: entries.count,
            fingerprint: fingerprintParts.joined(separator: ",")
        )
        return Result(
            entries: entries,
            refToTagId: refToTagId,
            blockedRefs: blockedRefs.sorted(),
            blockedNames: Array(blockedNames.sorted().prefix(50)),
            revision: revision
        )
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
