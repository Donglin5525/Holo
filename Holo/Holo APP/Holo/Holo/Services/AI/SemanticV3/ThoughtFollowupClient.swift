//
//  ThoughtFollowupClient.swift
//  Holo
//
//  想法脉络核对客户端（W2，2026-11-16 方案 §6 C2）
//
//  · GET /v1/thoughts/organization-capabilities 的封套 DTO + 5 分钟内存缓存
//    （仅当前主体；授权撤回/切身份/试点关闭/到期/功能禁用响应立即清，§6 C2）；
//  · POST /v1/thoughts/verify-followup 的请求 DTO/编码与响应校验：
//    六关系枚举、四成立关系双侧证据逐字回窗核对（Swift 按同一窗口核对范围
//    与逐字内容）、none/insufficient 三字段全 null、thread 成员 3–5 含锚点、
//    envelope 与请求 operationId 一致；协议错 = 失败态，绝不降级 no_result。
//
//  DTO 与校验是对后端 followupSchema.js 的逐字段对齐（fixture：
//  docs/thoughts/plans/2026-11-16-想法主题与脉络/fixtures/verify-followup-*.json）。
//  网络段用 #if 隔离：standalone 直编（-DHOLO_FOLLOWUP_STANDALONE）只保留纯
//  DTO/校验，供脚本化契约测试；生产构建两者都在。
//

import Foundation

// MARK: - 常量（与后端 FOLLOWUP_LIMITS / THOUGHT_FOLLOWUP_POLICY_VERSION 对齐）

nonisolated enum ThoughtFollowupContract {
    static let schemaVersion = 1
    static let policyVersion = "thought-followup-1"
    static let requestBodyMaxBytes = 32 * 1024
    static let notesMinCount = 2
    static let notesMaxCount = 5
    static let scopeTitleMaxUTF16 = 32
    static let refMaxUTF16 = 64
    static let windowsPerNoteMax = 2
    static let windowTextMaxUTF16 = 600
    static let totalTextMaxUTF16 = 6000
    static let quoteMaxUTF16 = 120
    static let reasonMaxUTF16 = 100
    static let threadTitleMinUTF16 = 2
    static let threadTitleMaxUTF16 = 32
    static let threadQuestionMinUTF16 = 4
    static let threadQuestionMaxUTF16 = 100
    static let threadMembersMin = 3
    static let threadMembersMax = 5

    static let relations: Set<String> = [
        "continues", "adds_example", "contrasts", "revises", "none", "insufficient",
    ]
    /// 四种成立关系（§6 C1）：双侧证据必填；none/insufficient 三字段必须全 null。
    static let establishedRelations: Set<String> = [
        "continues", "adds_example", "contrasts", "revises",
    ]

    /// 能力封套 followupVersion=0 表示对应能力关闭（§6 C2）。
    static let followupSupportedVersion = 1
}

// MARK: - 传输 DTO

nonisolated struct ThoughtOrganizationCapabilitiesDTO: Codable, Equatable {
    let schemaVersion: Int
    let categoryRulesVersion: Int
    let followupVersion: Int
    let policyVersion: String

    /// followup 能力当前对本主体可用（版本 1 且 policyVersion 与本客户端一致）。
    var isFollowupSupported: Bool {
        followupVersion == ThoughtFollowupContract.followupSupportedVersion
            && policyVersion == ThoughtFollowupContract.policyVersion
    }
}

nonisolated struct ThoughtFollowupRequestDTO: Codable, Equatable {
    struct Window: Codable, Equatable {
        let ref: String
        let text: String
    }
    struct Note: Codable, Equatable {
        let ref: String
        let createdAtMs: Int
        let windows: [Window]
    }
    let schemaVersion: Int
    let operationId: String
    let policyVersion: String
    let scopeTitle: String
    let anchorRef: String
    let notes: [Note]
}

nonisolated struct ThoughtFollowupResponseDTO: Codable, Equatable {
    struct Evidence: Codable, Equatable {
        var windowRef: String
        var quote: String
        var rangeUTF16: [Int]
    }
    struct Decision: Codable, Equatable {
        var otherRef: String
        var relation: String
        var reason: String?
        var anchorEvidence: Evidence?
        var otherEvidence: Evidence?
    }
    struct Thread: Codable, Equatable {
        var title: String
        var question: String
        var memberRefs: [String]
    }
    var schemaVersion: Int
    var operationId: String
    var policyVersion: String
    var decisions: [Decision]
    var thread: Thread?
}

// MARK: - 校验产物（ref → 本机 thoughtID 的映射在落库前完成，§6 C3）

/// 已核对证据：thoughtID 与窗口在脱敏全文中的 UTF-16 起点随证据落库，
/// 显示句柄只从本机 source 映射绑定。
nonisolated struct ThoughtFollowupVerifiedEvidence: Equatable {
    var thoughtID: UUID
    var windowRef: String
    var windowOffsetUTF16: Int
    var quote: String
    var rangeUTF16: [Int]
}

nonisolated struct ThoughtFollowupVerifiedDecision: Equatable {
    var otherThoughtID: UUID
    var relation: String
    var reason: String?
    var anchorEvidence: ThoughtFollowupVerifiedEvidence?
    var otherEvidence: ThoughtFollowupVerifiedEvidence?
}

nonisolated struct ThoughtFollowupVerifiedThread: Equatable {
    var title: String
    var question: String
    var memberThoughtIDs: [UUID]
}

nonisolated struct ThoughtFollowupVerifiedContent: Equatable {
    var decisions: [ThoughtFollowupVerifiedDecision]
    var thread: ThoughtFollowupVerifiedThread?
    /// 至少一条成立关系（thread 为 nil 时相关区仍可用，主题脉络为空，§6 C2）
    var hasEstablishedRelation: Bool
}

// MARK: - 纯校验（不信任网络层，§6 C2「Swift 再按同一窗口核对」）

nonisolated enum ThoughtFollowupValidator {

    enum Outcome: Equatable {
        /// 200 且全部非命中：终态空结果（§6 C2）
        case noResult
        case verified(ThoughtFollowupVerifiedContent)
        /// 结构/证据协议错：整批失败，禁止把畸形响应标为 no_result（§6 C2）
        case contractViolation(reason: String)
    }

    /// 组装请求前的本地界限校验（镜像后端 validateFollowupRequest，防白打）。
    /// 返回 nil 表示输入不合约（调用方不得发出请求）。
    static func makeRequest(operationId: String,
                            scopeTitle: String,
                            anchorRef: String,
                            notes: [(ref: String, createdAtMs: Int, windows: [(ref: String, text: String)])]) -> ThoughtFollowupRequestDTO? {
        let title = String(scopeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(ThoughtFollowupContract.scopeTitleMaxUTF16))
        guard (ThoughtFollowupContract.notesMinCount...ThoughtFollowupContract.notesMaxCount).contains(notes.count),
              notes.allSatisfy({ $0.createdAtMs >= 0 }) else { return nil }
        var seenRefs = Set<String>()
        var noteDTOs: [ThoughtFollowupRequestDTO.Note] = []
        var totalText = 0
        for note in notes {
            guard isCleanShortString(note.ref, maxLength: ThoughtFollowupContract.refMaxUTF16),
                  seenRefs.insert(note.ref).inserted,
                  (1...ThoughtFollowupContract.windowsPerNoteMax).contains(note.windows.count) else { return nil }
            var windowDTOs: [ThoughtFollowupRequestDTO.Window] = []
            var seenWindowRefs = Set<String>()
            for window in note.windows {
                guard isCleanShortString(window.ref, maxLength: ThoughtFollowupContract.refMaxUTF16),
                      seenWindowRefs.insert(window.ref).inserted,
                      isBoundedText(window.text, maxLength: ThoughtFollowupContract.windowTextMaxUTF16) else { return nil }
                totalText += window.text.utf16.count
                windowDTOs.append(.init(ref: window.ref, text: window.text))
            }
            noteDTOs.append(.init(ref: note.ref, createdAtMs: note.createdAtMs, windows: windowDTOs))
        }
        guard totalText <= ThoughtFollowupContract.totalTextMaxUTF16,
              isCleanShortString(anchorRef, maxLength: ThoughtFollowupContract.refMaxUTF16),
              notes.contains(where: { $0.ref == anchorRef }) else { return nil }
        let dto = ThoughtFollowupRequestDTO(
            schemaVersion: ThoughtFollowupContract.schemaVersion,
            operationId: operationId,
            policyVersion: ThoughtFollowupContract.policyVersion,
            scopeTitle: title,
            anchorRef: anchorRef,
            notes: noteDTOs)
        guard let encoded = try? JSONEncoder().encode(dto),
              encoded.count <= ThoughtFollowupContract.requestBodyMaxBytes else { return nil }
        return dto
    }

    /// 响应校验：envelope 与请求一致、决定逐条、证据逐字回窗、thread 形状。
    /// noteIDByRef / windowOffsetByNoteRef 由请求组装方提供（本机 source 映射）。
    static func validate(response: ThoughtFollowupResponseDTO,
                         request: ThoughtFollowupRequestDTO,
                         noteIDByRef: [String: UUID],
                         windowOffsetByNoteRef: [String: [String: Int]]) -> Outcome {
        guard response.schemaVersion == request.schemaVersion,
              response.operationId == request.operationId,
              response.policyVersion == request.policyVersion else {
            return .contractViolation(reason: "envelope_mismatch")
        }
        let anchorNote = request.notes.first(where: { $0.ref == request.anchorRef })
        let otherNotes = request.notes.filter { $0.ref != request.anchorRef }
        guard let anchorNote else { return .contractViolation(reason: "anchor_missing_in_request") }
        guard response.decisions.count == otherNotes.count else {
            return .contractViolation(reason: "decisions_incomplete")
        }
        var relationByRef: [String: String] = [:]
        var seenRefs = Set<String>()
        var verifiedDecisions: [ThoughtFollowupVerifiedDecision] = []
        for decision in response.decisions {
            let otherRef = decision.otherRef
            guard otherNotes.contains(where: { $0.ref == otherRef }),
                  seenRefs.insert(otherRef).inserted else {
                return .contractViolation(reason: "other_ref_not_allowed")
            }
            guard ThoughtFollowupContract.relations.contains(decision.relation) else {
                return .contractViolation(reason: "relation_enum")
            }
            guard let otherThoughtID = noteIDByRef[otherRef] else {
                return .contractViolation(reason: "other_ref_not_mapped")
            }
            let isEstablished = ThoughtFollowupContract.establishedRelations.contains(decision.relation)
            if !isEstablished {
                // none/insufficient：reason 与两侧证据必须全 null（§6 C2）
                guard decision.reason == nil, decision.anchorEvidence == nil, decision.otherEvidence == nil else {
                    return .contractViolation(reason: "negative_decision_fields_not_null")
                }
                relationByRef[otherRef] = decision.relation
                verifiedDecisions.append(.init(otherThoughtID: otherThoughtID, relation: decision.relation,
                                                reason: nil, anchorEvidence: nil, otherEvidence: nil))
                continue
            }
            guard let reason = decision.reason,
                  isBoundedText(reason, maxLength: ThoughtFollowupContract.reasonMaxUTF16) else {
                return .contractViolation(reason: "reason_shape")
            }
            guard let anchorNoteID = noteIDByRef[request.anchorRef],
                  let anchorEvidence = verifiedEvidence(decision.anchorEvidence, note: anchorNote,
                                                        thoughtID: anchorNoteID,
                                                        windowOffsets: windowOffsetByNoteRef[request.anchorRef] ?? [:]),
                  let otherNote = otherNotes.first(where: { $0.ref == otherRef }),
                  let otherEvidence = verifiedEvidence(decision.otherEvidence, note: otherNote,
                                                        thoughtID: otherThoughtID,
                                                        windowOffsets: windowOffsetByNoteRef[otherRef] ?? [:]) else {
                return .contractViolation(reason: "evidence_invalid")
            }
            relationByRef[otherRef] = decision.relation
            verifiedDecisions.append(.init(otherThoughtID: otherThoughtID, relation: decision.relation,
                                            reason: reason, anchorEvidence: anchorEvidence,
                                            otherEvidence: otherEvidence))
        }
        var verifiedThread: ThoughtFollowupVerifiedThread?
        if let thread = response.thread {
            guard (ThoughtFollowupContract.threadTitleMinUTF16...ThoughtFollowupContract.threadTitleMaxUTF16)
                    .contains(thread.title.utf16.count),
                  isBoundedText(thread.title, maxLength: ThoughtFollowupContract.threadTitleMaxUTF16),
                  (ThoughtFollowupContract.threadQuestionMinUTF16...ThoughtFollowupContract.threadQuestionMaxUTF16)
                    .contains(thread.question.utf16.count),
                  isBoundedText(thread.question, maxLength: ThoughtFollowupContract.threadQuestionMaxUTF16),
                  (ThoughtFollowupContract.threadMembersMin...ThoughtFollowupContract.threadMembersMax)
                    .contains(thread.memberRefs.count) else {
                return .contractViolation(reason: "thread_shape")
            }
            let inputRefs = Set(request.notes.map(\.ref))
            var members: [String] = []
            for ref in thread.memberRefs {
                guard inputRefs.contains(ref), !members.contains(ref) else {
                    return .contractViolation(reason: "thread_member_ref_not_allowed")
                }
                members.append(ref)
            }
            guard members.contains(request.anchorRef) else {
                return .contractViolation(reason: "thread_missing_anchor")
            }
            // 其余成员必须逐条有成立关系（§6 C2）
            guard members.filter({ $0 != request.anchorRef }).allSatisfy({
                guard let relation = relationByRef[$0] else { return false }
                return ThoughtFollowupContract.establishedRelations.contains(relation)
            }) else {
                return .contractViolation(reason: "thread_member_relation_invalid")
            }
            guard let memberIDs = members.map({ noteIDByRef[$0] }) as? [UUID], memberIDs.count == members.count else {
                return .contractViolation(reason: "thread_member_not_mapped")
            }
            verifiedThread = .init(title: thread.title, question: thread.question, memberThoughtIDs: memberIDs)
        }
        let hasEstablished = verifiedDecisions.contains {
            ThoughtFollowupContract.establishedRelations.contains($0.relation)
        }
        // 没有任何可信关系时 200 全部非命中且 thread 必为 null（§6 C2）
        if !hasEstablished {
            guard response.thread == nil else { return .contractViolation(reason: "thread_without_relation") }
            return .noResult
        }
        return .verified(.init(decisions: verifiedDecisions, thread: verifiedThread,
                               hasEstablishedRelation: hasEstablished))
    }

    /// 单条证据：windowRef 回到该 note 已定义窗口，quote 1–120 UTF-16，
    /// rangeUTF16 为窗口内半开区间，且 Swift 按同一窗口逐字核对（§6 C2）。
    private static func verifiedEvidence(_ raw: ThoughtFollowupResponseDTO.Evidence?,
                                         note: ThoughtFollowupRequestDTO.Note,
                                         thoughtID: UUID,
                                         windowOffsets: [String: Int]) -> ThoughtFollowupVerifiedEvidence? {
        guard let raw else { return nil }
        guard let window = note.windows.first(where: { $0.ref == raw.windowRef }) else { return nil }
        guard (1...ThoughtFollowupContract.quoteMaxUTF16).contains(raw.quote.utf16.count),
              let offset = windowOffsets[raw.windowRef] else { return nil }
        guard raw.rangeUTF16.count == 2 else { return nil }
        let startValue = raw.rangeUTF16[0]
        let endValue = raw.rangeUTF16[1]
        guard startValue >= 0, endValue <= window.text.utf16.count, startValue < endValue,
              let start = String.Index(utf16Offset: startValue, in: window.text).samePosition(in: window.text),
              let end = String.Index(utf16Offset: endValue, in: window.text).samePosition(in: window.text),
              String(window.text[start..<end]) == raw.quote else { return nil }
        return ThoughtFollowupVerifiedEvidence(thoughtID: thoughtID, windowRef: raw.windowRef,
                                               windowOffsetUTF16: offset, quote: raw.quote,
                                               rangeUTF16: raw.rangeUTF16)
    }

    /// 短标识串：非空、≤上限、无控制字符（对齐后端 isCleanShortString）。
    static func isCleanShortString(_ value: String, maxLength: Int) -> Bool {
        guard !value.isEmpty, value.utf16.count <= maxLength else { return false }
        return !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    /// 正文类字符串：允许换行、拒绝其他控制字符（对齐后端 isBoundedText）。
    static func isBoundedText(_ value: String, maxLength: Int) -> Bool {
        guard !value.isEmpty, value.utf16.count <= maxLength else { return false }
        return !value.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (v < 0x09) || (v > 0x0d && v < 0x20) || v == 0x7f
        }
    }
}

// MARK: - 能力封套缓存（§6 C2：内存、当前主体、最多 5 分钟）

/// 能力口结果的进程内缓存：仅内存、单主体单条目；到期自然失效。
/// 授权撤回、试点关闭、收到功能禁用响应由持有方调 invalidate() 立即清；
/// 切换身份后按新主体读取自然不命中旧条目（等价清除）。
actor ThoughtFollowupCapabilityCache {
    static let shared = ThoughtFollowupCapabilityCache()
    static let ttl: TimeInterval = 300

    private struct Entry {
        let subject: String
        let capabilities: ThoughtOrganizationCapabilitiesDTO
        let fetchedAt: Date
    }

    private var entry: Entry?

    /// 命中且未过期才返回（到期 = 视为无缓存，调用方重新拉取）。
    func capabilities(for subject: String, now: Date = Date()) -> ThoughtOrganizationCapabilitiesDTO? {
        guard let entry, entry.subject == subject,
              now.timeIntervalSince(entry.fetchedAt) < Self.ttl else { return nil }
        return entry.capabilities
    }

    func store(_ capabilities: ThoughtOrganizationCapabilitiesDTO, subject: String, now: Date = Date()) {
        entry = Entry(subject: subject, capabilities: capabilities, fetchedAt: now)
    }

    /// 立即清（撤权/切身份后的主动失效/功能禁用响应）。
    func invalidate() {
        entry = nil
    }
}

// MARK: - 网络客户端（standalone 直编时只保留纯 DTO/校验）

#if !HOLO_FOLLOWUP_STANDALONE

nonisolated enum ThoughtFollowupClientError: Error, Equatable {
    /// 能力口 404：旧后端不支持新端点——禁止探测正文请求（§6 C2）
    case unsupportedByServer
    /// 请求体超 32 KiB（本地编码或服务端 413）
    case inputTooLarge
    /// THOUGHT_FOLLOWUP_DISABLED（503）：功能关闭或主体不在试点白名单
    case disabled
}

nonisolated enum ThoughtFollowupClient {

    /// GET /v1/thoughts/organization-capabilities：只传状态不传正文（§2 A13）。
    /// 404 → unsupportedByServer；走现有 APIClient（设备鉴权、会话注入统一口径）。
    static func fetchCapabilities(baseURL: String = HoloBackendEnvironment.baseURL,
                                  apiClient: APIClient = .shared,
                                  deviceIdProvider: () -> String = { HoloBackendDeviceIdentity.shared.deviceId }) async throws -> ThoughtOrganizationCapabilitiesDTO {
        let request = APIRequest(
            baseURL: baseURL,
            path: "/v1/thoughts/organization-capabilities",
            method: .get,
            headers: ["X-Holo-Device-Id": deviceIdProvider()])
        do {
            return try await apiClient.send(request)
        } catch let error as APIError {
            if case .httpError(404, _) = error { throw ThoughtFollowupClientError.unsupportedByServer }
            throw error
        }
    }

    /// POST /v1/thoughts/verify-followup：锚点 × ≤4 候选的一次性无状态核对。
    /// 请求超时与运行时限对齐（后端 deadline 内完成；中断可能已计费，由 taskKey 幂等兜底）。
    static func verifyFollowup(_ body: ThoughtFollowupRequestDTO,
                                baseURL: String = HoloBackendEnvironment.baseURL,
                                apiClient: APIClient = .shared,
                                deviceIdProvider: () -> String = { HoloBackendDeviceIdentity.shared.deviceId }) async throws -> ThoughtFollowupResponseDTO {
        let request = APIRequest(
            baseURL: baseURL,
            path: "/v1/thoughts/verify-followup",
            method: .post,
            headers: [
                "Content-Type": "application/json",
                "X-Holo-Device-Id": deviceIdProvider(),
            ],
            body: body,
            timeoutInterval: 180)
        do {
            return try await apiClient.send(request)
        } catch let error as APIError {
            switch error {
            case .httpError(404, _), .backendError(_, "THOUGHT_FOLLOWUP_DISABLED", _, _):
                throw ThoughtFollowupClientError.disabled
            case .httpError(413, _), .backendError(413, "INPUT_TOO_LARGE", _, _):
                throw ThoughtFollowupClientError.inputTooLarge
            default:
                throw error
            }
        }
    }
}

#endif
