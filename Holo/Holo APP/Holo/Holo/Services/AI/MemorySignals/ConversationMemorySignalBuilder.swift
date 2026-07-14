//
//  ConversationMemorySignalBuilder.swift
//  Holo
//
//  对话只记用户明确表达；AI 回复和普通闲聊永远不能成为记忆证据。
//

import Foundation

nonisolated enum ConversationMemoryRole: String, Sendable {
    case user
    case assistant
}

nonisolated enum ConversationMemoryStatementKind: String, Sendable {
    case explicitPreference
    case correction
    case commitment
    case importantContext
    case casual
}

nonisolated struct ConversationMemoryInput: Equatable, Sendable {
    var id: String
    var role: ConversationMemoryRole
    var statementKind: ConversationMemoryStatementKind
    var text: String
    var revisionDigest: String
    var createdAt: Date
    var profileAnchor: HoloMemoryAnchorRef?
}

nonisolated enum ConversationMemorySignalBuilder {
    static func build(from inputs: [ConversationMemoryInput]) -> [HoloDomainMemorySignal] {
        let allowed: Set<ConversationMemoryStatementKind> = [
            .explicitPreference, .correction, .commitment, .importantContext
        ]
        return inputs.compactMap { input in
            guard input.role == .user,
                  allowed.contains(input.statementKind),
                  !input.id.isEmpty,
                  !input.revisionDigest.isEmpty,
                  !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let conversationAnchor = try? HoloMemoryAnchorRef(
                    type: .conversation,
                    value: input.statementKind.rawValue
                  ) else { return nil }
            let evidence = HoloMemoryEvidenceRef(
                id: "conversation-\(input.id)-\(input.revisionDigest)",
                kind: .explicitUserStatement,
                sourceDomain: .conversation,
                lineageKey: "conversation:user:\(input.id)",
                sourceID: input.id,
                revisionDigest: input.revisionDigest,
                observedAt: input.createdAt
            )
            let anchors = [conversationAnchor, input.profileAnchor].compactMap { $0 }
            return try? HoloDomainSignalBuilder.make(
                id: "conversation-\(input.statementKind.rawValue)-\(input.id)",
                domain: .conversation,
                kind: .explicitUserText,
                evidence: evidence,
                anchors: anchors,
                prohibitedInferences: [
                    "AI 回复不得成为证据",
                    "普通闲聊不得升级为偏好、承诺或重要上下文",
                    "Profile 只能作为锚点和表达边界，后台不得静默改写 Profile"
                ],
                userText: input.text,
                explicitUserStance: input.statementKind == .explicitPreference ? input.text : nil
            )
        }.sorted { $0.id < $1.id }
    }
}
