//
//  ThoughtTopicSummaryClient.swift
//  Holo
//
//  主题摘要客户端（语义图谱 V3 Phase 5，方案 §4.5/§5.2）
//
//  一次请求：主题标题 + ≤12 条代表片段（最近优先，脱敏后 ≤240 UTF-16）→
//  摘要 + ≤4 条反复观点。与 verifier 同纪律：客户端二次校验（ref 白名单/
//  quote 逐字/range 对齐）后才落库；失败静默降级为「无摘要区」，不影响详情页。
//  摘要是 AI 派生数据，只存本机语义库（不进 CloudKit，随销毁入口清除）。
//

import Foundation
import OSLog

// MARK: - 传输 DTO（与后端 topicInsightSchema 契约对齐）

struct ThoughtTopicSummaryRequestDTO: Codable {
    struct Representative: Codable { let ref: String; let text: String }
    struct Topic: Codable { let title: String }
    let schemaVersion: Int
    let operationId: String
    let engineVersion: String
    let topic: Topic
    let representatives: [Representative]
}

struct ThoughtTopicSummaryResponseDTO: Codable {
    struct Viewpoint: Codable {
        let ref: String
        let quote: String
        let rangeUTF16: [Int]?
    }
    let schemaVersion: Int
    let operationId: String
    let summary: String
    let viewpoints: [Viewpoint]?
}

/// 落库前的干净结果（ref 已解析回想法 UUID，逐字校验通过）
struct ThoughtTopicSummaryContent: Codable, Equatable {
    struct Viewpoint: Codable, Equatable {
        var thoughtID: UUID
        var quote: String
    }
    var summary: String
    var viewpoints: [Viewpoint]
}

enum ThoughtTopicSummaryClient {

    static let engineVersion = ThoughtTopicVerifier.engineVersion
    private static let logger = Logger(subsystem: "com.holo.Holo", category: "ThoughtTopicSummary")
    static let representativeMaxCount = 12
    private static let representativeTextMaxUTF16 = 240

    /// 组装请求（脱敏 + 截断）。代表片段按 createdAt 降序（最近优先，方案 §5.2 分层摘要首版口径）。
    static func makeRequest(title: String, thoughts: [Thought]) -> ThoughtTopicSummaryRequestDTO? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        let representatives: [ThoughtTopicSummaryRequestDTO.Representative] = thoughts
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            .prefix(representativeMaxCount)
            .compactMap { thought in
                let plain = (thought.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let redacted = ThoughtIndexV2Policy.redactedText(forUpload: plain)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !redacted.isEmpty else { return nil }
                return .init(ref: thought.id.uuidString,
                             text: String(redacted.prefix(representativeTextMaxUTF16)))
            }
        guard !representatives.isEmpty else { return nil }
        return ThoughtTopicSummaryRequestDTO(
            schemaVersion: 1,
            operationId: UUID().uuidString.lowercased(),
            engineVersion: engineVersion,
            topic: .init(title: String(trimmedTitle.prefix(32))),
            representatives: representatives)
    }

    /// 客户端二次校验（后端已校验，此处不信任网络层）：ref 必须能解析回请求里的想法，
    /// quote 必须是该想法脱敏原文的逐字子串且 range 对齐。任何一条违反=整体拒绝。
    static func validatedContent(from response: ThoughtTopicSummaryResponseDTO,
                                 request: ThoughtTopicSummaryRequestDTO) -> ThoughtTopicSummaryContent? {
        guard !response.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var textByRef: [String: String] = [:]
        for rep in request.representatives { textByRef[rep.ref] = rep.text }
        var viewpoints: [ThoughtTopicSummaryContent.Viewpoint] = []
        var seenRefs = Set<String>()
        for raw in response.viewpoints ?? [] {
            guard let text = textByRef[raw.ref], !seenRefs.contains(raw.ref),
                  let thoughtID = UUID(uuidString: raw.ref) else { return nil }
            seenRefs.insert(raw.ref)
            let quote = raw.quote
            guard !quote.isEmpty, quote.count <= 120 else { return nil }
            guard let start = text.indexOfUTF16(quote) else { return nil }
            if let range = raw.rangeUTF16 {
                guard range.count == 2, range[0] == start, range[1] == start + quote.utf16.count else { return nil }
            }
            viewpoints.append(.init(thoughtID: thoughtID, quote: quote))
        }
        return .init(summary: response.summary, viewpoints: viewpoints)
    }

    /// 端到端：请求 → 校验 → 落本机语义库。任何失败抛错由调用方降级（隐藏摘要区）。
    @discardableResult
    static func refreshSummary(topicID: UUID,
                               title: String,
                               thoughts: [Thought],
                               basisRevision: Int64,
                               provider: HoloBackendAIProvider,
                               store: ThoughtSemanticStore) async throws -> ThoughtTopicSummaryContent {
        guard let request = makeRequest(title: title, thoughts: thoughts) else {
            throw SummaryError.notEnoughContent
        }
        let response = try await provider.topicSummary(request)
        guard let content = validatedContent(from: response, request: request) else {
            throw SummaryError.contractViolation
        }
        let viewpointsJSON = (try? JSONEncoder().encode(content.viewpoints)).flatMap { data in
            String(data: data, encoding: .utf8)
        } ?? "[]"
        try await store.saveTopicSummary(topicID: topicID,
                                         modelVersion: engineVersion,
                                         basisRevision: basisRevision,
                                         summary: content.summary,
                                         viewpointsJSON: viewpointsJSON)
        return content
    }

    enum SummaryError: Error {
        case notEnoughContent
        case contractViolation
    }
}

extension String {
    /// UTF-16 单位下的逐字子串查找（JS indexOf 语义，与后端 rangeUTF16 对齐）。
    func indexOfUTF16(_ needle: String) -> Int? {
        guard let range = range(of: needle),
              let lower = range.lowerBound.samePosition(in: utf16) else { return nil }
        return utf16.distance(from: utf16.startIndex, to: lower)
    }
}
